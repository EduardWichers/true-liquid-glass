#!/bin/bash
# Creates (once) a self-signed code-signing identity in a private keychain, so that every
# build of Liquid Venster gets the same signature. macOS then keeps the Accessibility and
# Screen Recording permissions after a rebuild (with an ad-hoc signature it would not).
#
# - The identity lives in its own keychain; the login keychain and the keychain search
#   list are left untouched.
# - Prints the path of the keychain on success. Exit code != 0 on failure.
set -euo pipefail

IDENTITY="Liquid Venster Ontwikkelaar"
DIR="$HOME/Library/Application Support/Liquid Venster"
KEYCHAIN="$DIR/signing.keychain-db"
PASSFILE="$DIR/signing.pass"
OPENSSL=/usr/bin/openssl   # LibreSSL: its PKCS#12 format is understood by `security import`

fail() { echo "❌ Ondertekening: $*" >&2; exit 1; }

has_identity() {
    security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$IDENTITY\""
}

# Already set up?
if [[ -f "$KEYCHAIN" && -f "$PASSFILE" ]]; then
    if security unlock-keychain -p "$(cat "$PASSFILE")" "$KEYCHAIN" 2>/dev/null && has_identity; then
        echo "$KEYCHAIN"
        exit 0
    fi
    echo "⚠︎ Bestaande ondertekeningssleutelhanger is onbruikbaar; maak een nieuwe" >&2
fi

[[ -x "$OPENSSL" ]] || fail "$OPENSSL ontbreekt"
mkdir -p "$DIR"
chmod 700 "$DIR"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
random() { "$OPENSSL" rand -hex 16; }
PASS="$(random)"
P12PASS="$(random)"
[[ ${#PASS} -eq 32 && ${#P12PASS} -eq 32 ]] || fail "kon geen wachtwoord genereren"

cat > "$TMP/cert.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $IDENTITY
[ ext ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" >/dev/null 2>&1 || fail "certificaat maken mislukt"
"$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$IDENTITY" \
    -out "$TMP/identity.p12" -passout "pass:$P12PASS" >/dev/null 2>&1 || fail "PKCS#12 maken mislukt"

# `create-keychain` may add the new keychain to the search list; put the old list back.
SEARCH_LIST=()
while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"; line="${line#\"}"; line="${line%\"}"
    [[ -n "$line" ]] && SEARCH_LIST+=("$line")
done < <(security list-keychains -d user)

rm -f "$KEYCHAIN"
security create-keychain -p "$PASS" "$KEYCHAIN" || fail "sleutelhanger maken mislukt"
if [[ ${#SEARCH_LIST[@]} -gt 0 ]]; then
    security list-keychains -d user -s "${SEARCH_LIST[@]}" || echo "⚠︎ kon zoeklijst sleutelhangers niet herstellen" >&2
fi
security set-keychain-settings "$KEYCHAIN"                 # never auto-lock
security unlock-keychain -p "$PASS" "$KEYCHAIN"
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$P12PASS" -T /usr/bin/codesign >/dev/null \
    || fail "certificaat importeren mislukt"
# Lets codesign use the key without a keychain dialog.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KEYCHAIN" >/dev/null \
    || fail "toegang voor codesign instellen mislukt"

umask 077
printf '%s' "$PASS" > "$PASSFILE"
chmod 600 "$PASSFILE"

has_identity || fail "identiteit niet gevonden na importeren"
echo "✅ Ondertekeningscertificaat ‘$IDENTITY’ aangemaakt" >&2
echo "$KEYCHAIN"
