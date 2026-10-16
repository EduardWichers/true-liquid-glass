#!/bin/bash
# Builds "build/True Liquid Glass.app" (universal: Apple silicon + Intel).
#   ./build.sh             release build + self-test
#   ./build.sh --no-test   skip the self-test
#   ./build.sh --install   also install into /Applications (an older version goes to the Trash)
#   ./build.sh --package   also make "build/True Liquid Glass Installer.pkg"
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="True Liquid Glass"
OLD_APP_NAME="Liquid Venster"
PRODUCT="LiquidVenster"          # SwiftPM product
EXECUTABLE="TrueLiquidGlass"     # executable inside the app bundle (see Info.plist)
BUNDLE_ID="nl.liquidvenster.app"
LANGUAGES=(en nl de fr es pt-BR it ru zh-Hans ja)
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
RUN_TESTS=1
INSTALL=0
PACKAGE=0
for arg in "$@"; do
    case "$arg" in
        --no-test) RUN_TESTS=0 ;;
        --install) INSTALL=1 ;;
        --package) PACKAGE=1 ;;
        *) echo "Onbekende optie: $arg (gebruik --no-test, --install en/of --package)" >&2; exit 64 ;;
    esac
done

fail() { echo "❌ $*" >&2; exit 1; }

command -v swift >/dev/null || fail "Swift ontbreekt. Installeer de Xcode Command Line Tools: xcode-select --install"
[[ "$(uname)" == "Darwin" ]] || fail "Dit project bouwt alleen op macOS"

echo "▸ Compileren (release, Apple silicon)…"
swift build -c release --arch arm64
ARM_BIN="$(swift build -c release --arch arm64 --show-bin-path)/$PRODUCT"
[[ -x "$ARM_BIN" ]] || fail "Binary niet gevonden: $ARM_BIN"

UNIVERSAL="$BUILD_DIR/$EXECUTABLE"
mkdir -p "$BUILD_DIR"
echo "▸ Compileren (release, Intel)…"
if swift build -c release --arch x86_64 >/dev/null 2>&1; then
    X86_BIN="$(swift build -c release --arch x86_64 --show-bin-path)/$PRODUCT"
    lipo -create "$ARM_BIN" "$X86_BIN" -output "$UNIVERSAL" || fail "lipo mislukt"
else
    echo "⚠︎ Intel-build mislukt; de app werkt alleen op Apple silicon" >&2
    cp "$ARM_BIN" "$UNIVERSAL"
fi
ARCHS="$(lipo -archs "$UNIVERSAL")"
echo "   architecturen: $ARCHS"

if [[ $RUN_TESTS -eq 1 ]]; then
    echo "▸ Zelftest…"
    "$ARM_BIN" --selftest || fail "Zelftest mislukt (zie hierboven)"
fi

echo "▸ App-bundel samenstellen…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$UNIVERSAL" "$APP/Contents/MacOS/$EXECUTABLE"
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null || fail "Info.plist is ongeldig"
[[ "$(plutil -extract CFBundleExecutable raw "$APP/Contents/Info.plist")" == "$EXECUTABLE" ]] \
    || fail "CFBundleExecutable in Info.plist moet $EXECUTABLE zijn"
# One .lproj folder per language, so macOS knows which languages the app speaks.
for lang in "${LANGUAGES[@]}"; do
    mkdir -p "$APP/Contents/Resources/$lang.lproj"
    printf '"CFBundleDisplayName" = "%s";\n"CFBundleName" = "%s";\n' "$APP_NAME" "$APP_NAME" \
        > "$APP/Contents/Resources/$lang.lproj/InfoPlist.strings"
done

ICONSET="$BUILD_DIR/AppIcon.iconset"
ICNS="$BUILD_DIR/AppIcon.icns"
if [[ ! -f "$ICNS" || Scripts/make_icon.swift -nt "$ICNS" ]]; then
    echo "▸ Icoon maken…"
    rm -rf "$ICONSET"
    if swift Scripts/make_icon.swift "$ICONSET" && iconutil -c icns "$ICONSET" -o "$ICNS"; then
        rm -rf "$ICONSET"
    else
        echo "⚠︎ Icoon maken mislukt; de app krijgt het standaardicoon" >&2
        rm -f "$ICNS"
    fi
fi
[[ -f "$ICNS" ]] && cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

# Sign with a fixed, self-signed identity (created once by Scripts/setup_signing.sh) so that
# macOS keeps the Accessibility / Screen Recording permissions after an update.
# LIQUID_ADHOC=1 forces an ad-hoc signature.
IDENTITY="Liquid Venster Ontwikkelaar"
SIGNED=0
if [[ "${LIQUID_ADHOC:-0}" != "1" ]]; then
    echo "▸ Ondertekenen met ‘$IDENTITY’…"
    if KEYCHAIN="$(Scripts/setup_signing.sh)" \
        && security unlock-keychain -p "$(cat "$(dirname "$KEYCHAIN")/signing.pass")" "$KEYCHAIN" \
        && codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" --identifier "$BUNDLE_ID" "$APP"; then
        SIGNED=1
    else
        echo "⚠︎ Vaste ondertekening mislukt; val terug op ad-hoc (toestemmingen gelden dan alleen voor deze build)" >&2
    fi
fi
if [[ $SIGNED -eq 0 ]]; then
    echo "▸ Ondertekenen (ad-hoc)…"
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
fi
codesign --verify --strict "$APP" || fail "Handtekening ongeldig"
echo "   $(codesign -dr - "$APP" 2>/dev/null | grep designated)"
echo "✅ Klaar: $APP"

if [[ $PACKAGE -eq 1 ]]; then
    Scripts/make_installer.sh "$APP" "$ARCHS" || fail "Installatiepakket maken mislukt"
fi

if [[ $INSTALL -eq 1 ]]; then
    DEST="/Applications/$APP_NAME.app"
    echo "▸ Installeren in /Applications…"
    [[ -w /Applications ]] || fail "Geen schrijfrechten op /Applications"
    for name in "$EXECUTABLE" "$PRODUCT"; do
        if pgrep -x "$name" >/dev/null; then
            fail "$APP_NAME draait nog; stop de app eerst (druppel in de menubalk ▸ Stop)"
        fi
    done
    STAGING="/Applications/.$APP_NAME.app.nieuw"
    rm -rf "$STAGING"
    ditto "$APP" "$STAGING" || fail "Kopiëren naar /Applications mislukt"
    codesign --verify --strict "$STAGING" || fail "Handtekening van de geïnstalleerde kopie is ongeldig"
    for old in "$DEST" "/Applications/$OLD_APP_NAME.app"; do
        if [[ -e "$old" ]]; then
            [[ -x /usr/bin/trash ]] || fail "Kan $old niet naar de Prullenmand verplaatsen; verwijder hem zelf"
            /usr/bin/trash "$old" || fail "$old naar de Prullenmand verplaatsen mislukt"
        fi
    done
    mv "$STAGING" "$DEST" || fail "Installeren mislukt"
    echo "✅ Geïnstalleerd: $DEST"
    echo "   Start met: open \"$DEST\""
elif [[ $PACKAGE -eq 0 ]]; then
    echo "   Start met: open \"$APP\"   (of: ./build.sh --install / --package)"
fi
