import AppKit
import ImageIO
import SwiftUI
import Metal
import simd
import UniformTypeIdentifiers

/// Automated checks that run without UI or permissions (`--selftest`).
enum SelfTest {
    private static var passed = 0
    private static var failed = 0

    private static func check(_ condition: Bool, _ name: String) {
        if condition {
            passed += 1
            print("  ✓ \(name)")
        } else {
            failed += 1
            print("  ✗ \(name)")
        }
    }

    static func run(outputDirectory: String?) -> Bool {
        AppLog.shared.echoToStderr = true
        passed = 0
        failed = 0
        testGeometry()
        testTimeline()
        testScene()
        testDockAndSettings()
        testLocalization()
        MainActor.assumeIsolated { testDiagnostics() }
        testTools()
        MainActor.assumeIsolated { testLauncherModel() }
        MainActor.assumeIsolated { testShelf() }
        testRendering(outputDirectory: outputDirectory)
        MainActor.assumeIsolated { testOwnWindowSnapshot(outputDirectory: outputDirectory) }
        print("\n\(passed) geslaagd, \(failed) mislukt")
        return failed == 0
    }

    // MARK: Geometry

    private static func testGeometry() {
        print("== Coördinaten ==")
        let h: CGFloat = 982
        let rect = CGRect(x: 100, y: 50, width: 300, height: 200)
        check(ScreenGeometry.quartzRect(fromCocoa: ScreenGeometry.cocoaRect(fromQuartz: rect, primaryHeight: h),
                                        primaryHeight: h) == rect, "Quartz ↔ Cocoa heen en terug")
        check(ScreenGeometry.cocoaRect(fromQuartz: rect, primaryHeight: h) == CGRect(x: 100, y: 732, width: 300, height: 200),
              "Quartz → Cocoa spiegelt de y-as")

        let primary = CGRect(x: 0, y: 0, width: 1512, height: 982)
        check(ScreenGeometry.localRect(fromQuartz: rect, screenFrame: primary, primaryHeight: h) == rect,
              "lokaal kader op hoofdscherm = Quartz")
        // A second display above-right of the primary one.
        let secondary = CGRect(x: 1512, y: 982, width: 1920, height: 1080)
        let onSecondary = CGRect(x: 1600, y: -1000, width: 400, height: 300)
        check(ScreenGeometry.localRect(fromQuartz: onSecondary, screenFrame: secondary, primaryHeight: h)
                == CGRect(x: 88, y: 80, width: 400, height: 300), "lokaal kader op tweede scherm")
        check(ScreenGeometry.localPoint(fromQuartz: CGPoint(x: 1512, y: -1080), screenFrame: secondary, primaryHeight: h) == .zero,
              "linksboven van tweede scherm is (0,0)")

        if let best = ScreenGeometry.bestFrame(for: CGRect(x: 10, y: 10, width: 100, height: 100), in: [primary, secondary]) {
            check(best.index == 0 && !best.spansMultiple && abs(best.fraction - 1) < 1e-9, "venster op één scherm")
        } else { check(false, "venster op één scherm") }
        if let best = ScreenGeometry.bestFrame(for: CGRect(x: 1400, y: 900, width: 300, height: 200), in: [primary, secondary]) {
            check(best.spansMultiple, "venster over twee schermen wordt herkend")
        } else { check(false, "venster over twee schermen wordt herkend") }
        if let best = ScreenGeometry.bestFrame(for: CGRect(x: -200, y: 100, width: 400, height: 300), in: [primary]) {
            check(!best.spansMultiple && abs(best.fraction - 0.5) < 1e-9, "half buiten beeld is geen 'meerdere schermen'")
        } else { check(false, "half buiten beeld") }
        check(ScreenGeometry.bestFrame(for: CGRect(x: 5000, y: 5000, width: 10, height: 10), in: [primary]) == nil,
              "venster buiten alle schermen → nil")
        check(ScreenGeometry.bestFrame(for: CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10), in: [primary]) == nil,
              "NaN-kader wordt geweigerd")
        check(ScreenGeometry.bestFrame(for: .zero, in: [primary]) == nil, "leeg kader wordt geweigerd")

        let box = CGRect(x: 0, y: 0, width: 100, height: 100)
        check(ScreenGeometry.clamp(CGPoint(x: -50, y: 5000), into: box, inset: 6) == CGPoint(x: 6, y: 94), "punt wordt binnen scherm gehouden")
        let clampedNaN = ScreenGeometry.clamp(CGPoint(x: CGFloat.nan, y: CGFloat.infinity), into: box, inset: 6)
        check(clampedNaN.x.isFinite && clampedNaN.y.isFinite, "NaN/oneindig punt wordt eindig")
    }

    // MARK: Timeline

    private static func testTimeline() {
        print("== Tijdlijn ==")
        let timeline = LiquidTimeline()
        var minRelease = Float.greatestFiniteMagnitude
        var maxRelease: Float = 0
        for i in 0...200 {
            for j in 0...200 {
                let r = timeline.releaseTime(lx: Float(i) / 200, ly: Float(j) / 200)
                minRelease = min(minRelease, r)
                maxRelease = max(maxRelease, r)
            }
        }
        check(minRelease >= timeline.earliestRelease - 1e-5 && minRelease > timeline.fadeWindow + 0.02,
              String(format: "eerste frame toont het hele venster (eerste release %.3f s)", minRelease))
        check(maxRelease <= timeline.latestRelease + 1e-5, String(format: "laatste release binnen grens (%.3f s)", maxRelease))
        check(timeline.releaseTime(lx: 0.3, ly: 1) < timeline.releaseTime(lx: 0.3, ly: 0), "onderkant smelt eerst")
        check(timeline.sag(at: 0) == 0 && timeline.sag(at: timeline.meltStart) == 0 && timeline.sag(at: 0.5) > 0,
              "doorzakken begint pas bij het smelten")
        var steamMin: Float = 1, steamMax: Float = 0
        for i in 0...50 { for j in 0...50 {
            let o = LiquidTimeline.steamOrder(Float(i) / 50, Float(j) / 50)
            steamMin = min(steamMin, o); steamMax = max(steamMax, o)
        } }
        check(steamMin >= 0 && steamMax <= 1, "stoomvolgorde binnen [0,1]")
        let steamTimeline = LiquidTimeline.steam()
        check(steamTimeline.releaseTime(lx: 0.02, ly: 0.5) < steamTimeline.releaseTime(lx: 0.5, ly: 0.5),
              "verdampen begint aan de rand")
        check(steamTimeline.sag(at: 1) == 0, "stoom zakt niet door")
        var a = SplitMix64(seed: 42), b = SplitMix64(seed: 42)
        check((0..<5).allSatisfy { _ in a.next() == b.next() }, "random generator is deterministisch")
        var c = SplitMix64(seed: 7)
        check((0..<10_000).allSatisfy { _ in let f = c.nextFloat(); return f >= 0 && f < 1 }, "random floats in [0,1)")
    }

    // MARK: Scene

    private static func sceneInput(window: CGRect, view: CGSize = CGSize(width: 1512, height: 982),
                                   target: CGPoint = CGPoint(x: 900, y: 950), edge: DockEdge = .bottom,
                                   alpha: @escaping (Float, Float) -> Float = { _, _ in 1 }) -> LiquidSceneInput {
        LiquidSceneInput(viewSize: view, windowRect: window, target: target,
                         rippleOrigin: CGPoint(x: window.minX + 40, y: window.minY + 14), edge: edge,
                         drainRadius: 12, floorY: target.y - 26, opaqueBackground: true,
                         waterColor: SIMD3(0.62, 0.84, 0.98), colorStrength: 0.45, cornerRadius: 12, alphaAt: alpha)
    }

    private static func allFinite(_ p: LiquidParticle) -> Bool {
        for v in [p.a, p.b, p.c, p.d] where !(v.x.isFinite && v.y.isFinite && v.z.isFinite && v.w.isFinite) {
            return false
        }
        return true
    }

    private static func testScene() {
        print("== Animatiemodel ==")
        do {
            let input = sceneInput(window: CGRect(x: 300, y: 150, width: 800, height: 500))
            let scene = try LiquidScene.build(input)
            check(scene.particles.count > 5_000 && scene.particles.count <= input.maxParticles + input.maxParticles / 10,
                  "aantal druppels redelijk (\(scene.particles.count))")
            check(scene.totalDuration > 0.7 && scene.totalDuration < 2.0,
                  String(format: "totale duur %.2f s", scene.totalDuration))
            check(scene.particles.allSatisfy(allFinite), "alle druppelwaarden zijn eindig")
            check(scene.particles.allSatisfy { $0.c.z >= scene.timeline.earliestRelease - 1e-4 && $0.c.w >= 0.3 },
                  "release en reistijd geldig")
            check(scene.particles.allSatisfy { $0.c.z + $0.c.w <= scene.totalDuration }, "alle druppels zijn vóór het einde binnen")
            let target = SIMD2<Float>(900, 950)
            check(scene.particles.allSatisfy { simd_distance(SIMD2($0.a.z, $0.a.w), target) <= 12.5 },
                  "alle druppels eindigen in het Dock-icoon")
            check(scene.firstArrival <= scene.lastArrival, "eerste aankomst vóór laatste")
            let again = try LiquidScene.build(input)
            check(again.particles.count == scene.particles.count && again.particles.first?.a == scene.particles.first?.a,
                  "scène is reproduceerbaar")
            let u = scene.uniforms(time: 0.5, scaleX: 2, scaleY: 2, fluidTexel: SIMD2(1, 1))
            check(u.time.x == 0.5 && u.misc.y == 1 && u.win.z == 800 && u.water.w == 0.45, "uniforms correct gevuld")

            // Physics (Dock at the bottom): free fall onto the Dock, then a film into the icon.
            check(scene.particles.allSatisfy { $0.d.w == 1 }, "Dock onder: alle druppels vallen met zwaartekracht")
            check(scene.gravity >= 6500, "zwaartekracht realistisch snel (\(Int(scene.gravity)) pt/s²)")
            let landings = scene.particles.map { p -> Float in (2 * max(p.b.z - p.a.y, 0) / p.b.y).squareRoot() }
            check(landings.allSatisfy { $0.isFinite && $0 <= LiquidScene.maxFallTime + 0.01 },
                  String(format: "langste val %.2f s (≤ %.2f s)", landings.max() ?? 0, LiquidScene.maxFallTime))
            check(scene.particles.allSatisfy { $0.b.z <= 950 && $0.b.z >= $0.a.y - 0.001 },
                  "druppels landen op het Dock, boven het icoon")
            check(scene.particles.allSatisfy { $0.b.w >= 0.2 && $0.b.w <= 0.62 }, "stroomtijd over het Dock begrensd")
            let splashing = scene.particles.filter { $0.d.z > 0 }.count
            check(splashing > scene.particles.count / 5 && splashing < scene.particles.count / 2,
                  "ongeveer 30% van de druppels spat op (\(splashing))")
            // Two drops at the same height but different columns must not fall identically (strands).
            let strands = Set(scene.particles.prefix(400).map { Int($0.b.y / 20) })
            check(strands.count > 3, "vallend gordijn breekt op in stralen (\(strands.count) valsnelheden)")
        } catch {
            check(false, "scène bouwen: \(error.liquidDescription)")
        }

        do {
            let huge = try LiquidScene.build(sceneInput(window: CGRect(x: 0, y: 0, width: 6000, height: 4000),
                                                        view: CGSize(width: 6016, height: 3384)))
            check(huge.particles.count <= 48_000, "6K-venster blijft binnen het druppelbudget (\(huge.particles.count))")
            let tiny = try LiquidScene.build(sceneInput(window: CGRect(x: 10, y: 10, width: 3, height: 3)))
            check(!tiny.particles.isEmpty && tiny.totalDuration.isFinite, "piepklein venster werkt")
            let clear = try LiquidScene.build(sceneInput(window: CGRect(x: 100, y: 100, width: 300, height: 200), alpha: { _, _ in 0 }))
            check(clear.particles.isEmpty && clear.totalDuration > 0 && clear.totalDuration < 1,
                  "doorzichtig venster: geen druppels, wel geldige duur")
            let nanAlpha = try LiquidScene.build(sceneInput(window: CGRect(x: 100, y: 100, width: 300, height: 200), alpha: { _, _ in .nan }))
            check(nanAlpha.particles.isEmpty, "NaN-alpha levert geen druppels op")
            for edge in [DockEdge.left, .right] {
                let side = try LiquidScene.build(sceneInput(window: CGRect(x: 400, y: 200, width: 500, height: 400),
                                                            target: CGPoint(x: edge == .left ? 30 : 1480, y: 500), edge: edge))
                check(side.particles.allSatisfy(allFinite) && side.totalDuration < 2.0
                      && side.particles.allSatisfy { $0.d.w == 0 }, "Dock \(edge): geldige scène (boogbaan)")
            }
            var weird = sceneInput(window: CGRect(x: 300, y: 200, width: 400, height: 300))
            weird.floorY = .nan
            weird.waterColor = SIMD3(.nan, 5, -1)
            weird.colorStrength = .infinity
            let repaired = try LiquidScene.build(weird)
            check(repaired.particles.allSatisfy(allFinite) && repaired.input.waterColor == SIMD3(0.62, 1, 0)
                  && repaired.input.colorStrength == 0.45, "ongeldige vloer/kleur/diepte worden hersteld")
            let tall = try LiquidScene.build(sceneInput(window: CGRect(x: 100, y: 0, width: 300, height: 900),
                                                        view: CGSize(width: 1512, height: 3000), target: CGPoint(x: 700, y: 2950)))
            let tallLandings = tall.particles.map { p -> Float in (2 * max(p.b.z - p.a.y, 0) / p.b.y).squareRoot() }
            check((tallLandings.max() ?? 0) <= LiquidScene.maxFallTime + 0.01 && tall.totalDuration < 2.2,
                  String(format: "hoog scherm: val blijft vlot (%.2f s, totaal %.2f s)", tallLandings.max() ?? 0, tall.totalDuration))
            let below = try LiquidScene.build(sceneInput(window: CGRect(x: 400, y: 900, width: 300, height: 80)))
            check(below.particles.allSatisfy(allFinite), "venster onder het Dock-niveau werkt")
        } catch {
            check(false, "randgevallen scène: \(error.liquidDescription)")
        }

        func throwsError(_ input: LiquidSceneInput) -> Bool {
            (try? LiquidScene.build(input)) == nil
        }
        check(throwsError(sceneInput(window: .zero)), "leeg venster wordt geweigerd")
        check(throwsError(sceneInput(window: CGRect(x: 0, y: 0, width: CGFloat.nan, height: 10))), "NaN-venster wordt geweigerd")
        check(throwsError(sceneInput(window: CGRect(x: 0, y: 0, width: 100, height: 100), view: .zero)), "lege overlay wordt geweigerd")
        check(throwsError(sceneInput(window: CGRect(x: 0, y: 0, width: 100, height: 100), target: CGPoint(x: CGFloat.infinity, y: 0))),
              "oneindig doelpunt wordt geweigerd")
        var zeroBudget = sceneInput(window: CGRect(x: 0, y: 0, width: 100, height: 100))
        zeroBudget.maxParticles = 0
        check(throwsError(zeroBudget), "druppelbudget 0 wordt geweigerd")
    }

    // MARK: Languages

    private static func placeholders(_ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "%(\\d+\\$)?[-+ 0#]*\\d*(\\.\\d+)?[@dDiuUxXoOfeEgGcCsSpaAF%]") else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }.sorted()
    }

    private static func testLocalization() {
        print("== Talen ==")
        check(AppLanguage.allCases.count == 10, "10 talen")
        for language in AppLanguage.allCases {
            let table = language.table
            let missing = L.allCases.filter { (table[$0] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
            let badFormat = L.allCases.filter { key in
                guard let text = table[key], let english = Strings.en[key] else { return false }
                return placeholders(text) != placeholders(english)
            }
            check(missing.isEmpty, "\(language.nativeName): alle \(L.allCases.count) teksten aanwezig\(missing.isEmpty ? "" : " (mist: \(missing.map(\.rawValue).joined(separator: ", ")))")")
            check(badFormat.isEmpty, "\(language.nativeName): plaatshouders kloppen\(badFormat.isEmpty ? "" : " (fout: \(badFormat.map(\.rawValue).joined(separator: ", ")))")")
            // Formatting with arguments must work in every language.
            let sample = Localizer.shared.format(.testWindowTitle, [3], in: language)
                + Localizer.shared.format(.presetLabel, ["X"], in: language)
            check(sample.contains("3") && sample.contains("X"), "\(language.nativeName): opmaak met waarden werkt")
        }
        check(AppLanguage.best(for: ["nl-NL", "en-US"]) == .dutch, "nl-NL → Nederlands")
        check(AppLanguage.best(for: ["de-AT"]) == .german, "de-AT → Deutsch")
        check(AppLanguage.best(for: ["pt-PT"]) == .portuguese && AppLanguage.best(for: ["pt_BR"]) == .portuguese, "Portugees → pt-BR")
        check(AppLanguage.best(for: ["zh-Hans-CN"]) == .chinese, "zh-Hans-CN → 简体中文")
        check(AppLanguage.best(for: ["zh-Hant-TW", "ja-JP"]) == .japanese, "Traditioneel Chinees valt door naar de volgende taal")
        check(AppLanguage.best(for: ["sv-SE"]) == .english && AppLanguage.best(for: []) == .english, "onbekende taal → English")

        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("nl.liquidvenster.selftest.lang.\(getpid())")
        if let defaults = UserDefaults(suiteName: path) {
            let localizer = Localizer(defaults: defaults, systemPreferred: { ["fr-FR"] })
            check(localizer.language == .french && localizer.override == nil, "volgt de systeemtaal (fr)")
            localizer.setOverride(.japanese)
            check(localizer.language == .japanese && defaults.string(forKey: "appLanguage") == "ja"
                  && defaults.stringArray(forKey: "AppleLanguages") == ["ja"], "taal kiezen in de app wordt bewaard")
            check(Localizer(defaults: defaults, systemPreferred: { ["fr-FR"] }).language == .japanese, "gekozen taal blijft na herstart")
            localizer.setOverride(nil)
            // Only our own domain is checked; the global AppleLanguages list stays the user's.
            check(localizer.language == .french && defaults.persistentDomain(forName: path)?["AppleLanguages"] == nil,
                  "terug naar de systeemtaal")
            defaults.set("klingon", forKey: "appLanguage")
            check(Localizer(defaults: defaults, systemPreferred: { ["it"] }).language == .italian, "ongeldige taal in voorkeuren → systeemtaal")
            defaults.removePersistentDomain(forName: path)
            try? FileManager.default.removeItem(atPath: path + ".plist")
        } else {
            check(false, "tijdelijke voorkeuren voor talen")
        }

        // Installer pages: generated for every language, escaped and complete.
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tlg-installer-\(getpid())")
        do {
            try InstallerPages.write(to: folder)
            var ok = true
            for language in AppLanguage.allCases {
                for page in ["welcome", "conclusion"] {
                    let url = folder.appendingPathComponent("\(language.rawValue).lproj/\(page).html")
                    let html = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                    if !(html.contains("<html lang=\"\(language.rawValue)\">") && html.contains("</html>") && html.count > 500) { ok = false }
                    if page == "welcome" && !html.contains(AppInfo.author) { ok = false }
                }
            }
            check(ok, "installatiepagina's in alle 10 talen, met credits")
            check(InstallerPages.escape("a<b & \"c\"") == "a&lt;b &amp; &quot;c&quot;", "HTML-tekens worden ontsnapt")
        } catch {
            check(false, "installatiepagina's: \(error.liquidDescription)")
        }
        try? FileManager.default.removeItem(at: folder)
    }

    @MainActor
    private static func testDiagnostics() {
        print("== Probleemoplossing ==")
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("nl.liquidvenster.selftest.diag.\(getpid())")
        guard let defaults = UserDefaults(suiteName: path) else { check(false, "tijdelijke voorkeuren"); return }
        defer {
            defaults.removePersistentDomain(forName: path)
            try? FileManager.default.removeItem(atPath: path + ".plist")
        }
        let settings = AppSettings(defaults: defaults)
        let status = AppStatus()
        status.accessibility = false
        status.screenCapture = false
        let items = Diagnostics.run(settings: settings, status: status, copies: ["/Applications/A.app", "/Applications/B.app"])
        check(items.contains { $0.id == "ax" && $0.state == .error && $0.fixes.contains(.resetPermissions) },
              "ontbrekende Toegankelijkheid → fout met herstelknop")
        check(items.contains { $0.id == "sc" && $0.state == .error }, "ontbrekende Schermopname → fout")
        check(items.contains { $0.id == "copies" && $0.state == .warning }, "meerdere kopieën → waarschuwing")
        status.accessibility = true
        status.screenCapture = true
        status.interceptorRunning = true
        let good = Diagnostics.run(settings: settings, status: status, copies: ["/Applications/A.app"])
        check(good.first { $0.id == "ax" }?.state == .ok && good.first { $0.id == "tap" }?.state == .ok,
              "alles in orde → groene vinkjes")
        settings.systemWideEnabled = false
        check(Diagnostics.run(settings: settings, status: status, copies: []).contains { $0.id == "tap" && $0.fixes == [.enableSystemWide] },
              "effect uit → knop ‘Zet aan’")
        let report = Diagnostics.report(settings: settings, status: status, copies: ["/Applications/A.app"])
        check(report.contains("diagnostic report") && report.contains("[OK]") && report.contains("Settings:"),
              "diagnoserapport is volledig (Engels)")
        for language in AppLanguage.allCases {
            let localized = Diagnostics.run(settings: settings, status: status, copies: [], language: language)
            if localized.contains(where: { $0.title.isEmpty }) { check(false, "\(language.nativeName): lege diagnosetekst") }
        }
        check(true, "diagnose werkt in alle talen")
        let summary = status.summary(settings: settings, language: .english).text
        check(summary.hasPrefix("Off for other apps"), "status-samenvatting in het logboek is Engels")
    }

    // MARK: Tools (arranging windows, launcher, file shelf)

    private static func testTools() {
        print("== Gereedschap ==")
        let v = CGRect(x: 0, y: 40, width: 1512, height: 900)   // visible frame (Dock below)
        let current = CGRect(x: 100, y: 100, width: 800, height: 600)
        check(SnapLayout.frame(for: .leftHalf, visible: v, current: current) == CGRect(x: 0, y: 40, width: 756, height: 900), "linkerhelft")
        check(SnapLayout.frame(for: .rightHalf, visible: v, current: current) == CGRect(x: 756, y: 40, width: 756, height: 900), "rechterhelft")
        check(SnapLayout.frame(for: .maximize, visible: v, current: current) == v, "maximaliseren = zichtbaar scherm")
        check(SnapLayout.frame(for: .topLeft, visible: v, current: current) == CGRect(x: 0, y: 490, width: 756, height: 450), "kwart linksboven")
        check(SnapLayout.frame(for: .rightTwoThirds, visible: v, current: current) == CGRect(x: 504, y: 40, width: 1008, height: 900), "rechter twee derde")
        let centered = SnapLayout.frame(for: .center, visible: v, current: current)
        check(centered.size == current.size && abs(centered.midX - v.midX) <= 1 && abs(centered.midY - v.midY) <= 1, "centreren houdt de grootte")
        let huge = SnapLayout.frame(for: .center, visible: v, current: CGRect(x: 0, y: 0, width: 5000, height: 5000))
        check(v.contains(huge), "te groot venster wordt binnen het scherm gecentreerd")
        let half = SnapLayout.frame(for: .leftHalf, visible: v, current: current)
        check(SnapLayout.cycled(.leftHalf, visible: v, current: half) == .leftTwoThirds, "← nogmaals: ½ → ⅔")
        let twoThirds = SnapLayout.frame(for: .leftTwoThirds, visible: v, current: current)
        check(SnapLayout.cycled(.leftHalf, visible: v, current: twoThirds) == .leftThird, "← nogmaals: ⅔ → ⅓")
        let third = SnapLayout.frame(for: .leftThird, visible: v, current: current)
        check(SnapLayout.cycled(.leftHalf, visible: v, current: third) == .leftHalf, "← nogmaals: ⅓ → ½")
        check(SnapLayout.cycled(.leftHalf, visible: v, current: current) == .leftHalf, "eerste keer ← = ½")
        let full = CGRect(x: 0, y: 0, width: 1512, height: 982)
        check(SnapLayout.dragZone(cursor: CGPoint(x: 1, y: 500), screenFrame: full, visible: v) == .leftHalf, "slepen naar linkerrand → linkerhelft")
        check(SnapLayout.dragZone(cursor: CGPoint(x: 1511, y: 930), screenFrame: full, visible: v) == .topRight, "rechterbovenhoek → kwart rechtsboven")
        check(SnapLayout.dragZone(cursor: CGPoint(x: 700, y: 945), screenFrame: full, visible: v) == .maximize, "bovenrand → maximaliseren")
        check(SnapLayout.dragZone(cursor: CGPoint(x: 700, y: 500), screenFrame: full, visible: v) == nil, "midden van het scherm → niets")

        // Shortcuts.
        let snapCombos = SnapKeys.ordered.compactMap { SnapKeys.combo($0, modifiers: [.control, .option]) }
        check(snapCombos.count == SnapKeys.ordered.count && Set(snapCombos).count == snapCombos.count, "schik-sneltoetsen zijn uniek")
        check(SnapKeys.combo(.leftHalf, modifiers: [.control, .option])?.display == "⌃⌥←", "weergave ⌃⌥←")
        check(KeyCombo(49, [.option]).carbonModifiers == 2048 && KeyCombo(49, [.command, .shift]).carbonModifiers == 768,
              "Carbon-modifiers kloppen")
        check(Set(HotkeyPreset.allCases.map(\.combo)).count == HotkeyPreset.allCases.count, "sneltoetskeuzes zijn uniek")
        let defaults = AppSettings(defaults: UserDefaults(suiteName: (NSTemporaryDirectory() as NSString).appendingPathComponent("tlg.tools.\(getpid())")) ?? .standard)
        let reserved = SystemShortcuts.current()
        check(reserved[defaults.launcherHotkey.combo] == nil && reserved[defaults.shelfHotkey.combo] == nil
              && defaults.launcherHotkey != defaults.shelfHotkey,
              "standaard: sneltoetsen die macOS niet gebruikt (snelstarter \(defaults.launcherHotkey.combo.display), plank \(defaults.shelfHotkey.combo.display))")
        check(HotkeyPreset.commandSpace.combo.display == "⌘Space" && HotkeyPreset.commandSpace.combo.carbonModifiers == 256,
              "⌘Space is een keuze")
        let cmdSpace = KeyCombo(49, [.command])
        check(HotkeyPreset.firstFree(HotkeyPreset.launcherOrder, taken: []) == .commandSpace
              && HotkeyPreset.firstFree(HotkeyPreset.launcherOrder, taken: [cmdSpace]) == .optionSpace
              && HotkeyPreset.firstFree(HotkeyPreset.shelfOrder, taken: [KeyCombo(49, [.control, .option])]) == .optionShiftSpace,
              "standaard ⌘Space als Spotlight die niet gebruikt, anders ⌥Space")
        // macOS shortcuts (com.apple.symbolichotkeys).
        func entry(_ enabled: Int, _ key: Int, _ flags: Int) -> [String: Any] {
            ["enabled": NSNumber(value: enabled), "value": ["parameters": [NSNumber(value: 65535), NSNumber(value: key), NSNumber(value: flags)],
                                                         "type": "standard"] as [String: Any]]
        }
        let spotlightOff = SystemShortcuts.reserved(from: ["64": entry(0, 49, 1_048_576), "65": entry(1, 49, 1_572_864),
                                                           "60": entry(1, 49, 262_144), "61": entry(1, 49, 786_432)],
                                                    keyboardInputSources: 1)
        check(spotlightOff[cmdSpace] == nil && spotlightOff[KeyCombo(49, [.option, .command])] == .finderSearch
              && spotlightOff[KeyCombo(49, [.control, .option])] == nil, "Spotlight uit: ⌘Space vrij; invoerbron telt pas bij 2 bronnen")
        let fresh = SystemShortcuts.reserved(from: nil, keyboardInputSources: 2)
        check(fresh[cmdSpace] == .spotlight && fresh[KeyCombo(49, [.control])] == .previousInputSource
              && fresh[KeyCombo(49, [.control, .option])] == .nextInputSource, "nieuwe Mac: macOS-standaarden worden herkend")
        let moved = SystemShortcuts.reserved(from: ["64": entry(1, 49, 524_288), "65": entry(1, 65535, 0)], keyboardInputSources: 1)
        check(moved[KeyCombo(49, [.option])] == .spotlight && moved[cmdSpace] == nil && moved.count == 1,
              "Spotlight op een andere toets en lege toets worden goed gelezen")
        check(!Set(snapCombos).contains(defaults.launcherHotkey.combo) && !Set(snapCombos).contains(defaults.shelfHotkey.combo),
              "geen botsing tussen schikken, snelstarter en plank")

        // Launcher search.
        let safari = FuzzyMatcher.score(query: "saf", candidate: "Safari") ?? -1
        let other = FuzzyMatcher.score(query: "saf", candidate: "Desktop Safety Monitor") ?? -1
        check(safari > other && other > 0, "‘saf’: Safari boven een woord-match")
        check((FuzzyMatcher.score(query: "vsc", candidate: "Visual Studio Code") ?? 0) > 0, "initialen ‘vsc’ vinden Visual Studio Code")
        check((FuzzyMatcher.score(query: "sfr", candidate: "Safari") ?? 0) > 0, "letters op volgorde ‘sfr’ vinden Safari")
        check(FuzzyMatcher.score(query: "xyz", candidate: "Safari") == nil, "geen match → niets")
        check((FuzzyMatcher.score(query: "musik", candidate: "Musik") ?? 0) >= 1000
              && (FuzzyMatcher.score(query: "facetime", candidate: "FaceTime") ?? 0) >= 1000, "hoofdletters/accenten maken niet uit")

        // Calculator.
        func calc(_ text: String) -> Double? { Calculator.evaluate(text) }
        check(calc("2+3*4") == 14 && calc("(2+3)*4") == 20 && calc("10/4") == 2.5, "rekenen: + * / en haakjes")
        check(calc("2^3^2") == 512 && calc("-3+5") == 2 && calc("3,5*2") == 7, "rekenen: macht, min-teken, komma")
        check(calc("50%") == 0.5 && calc("7%3") == 1 && calc("12×3") == 36 && calc("9÷3") == 3, "rekenen: %, ×, ÷")
        check(calc("1/0") == nil && calc("2+") == nil && calc("abc") == nil && calc("42") == nil && calc("((2)") == nil,
              "ongeldige sommen geven niets (geen crash)")
        check(calc(String(repeating: "(", count: 100) + "1" + String(repeating: ")", count: 100)) == nil
              && calc(String(repeating: "1+", count: 150) + "1") == nil, "diepe/lange invoer wordt veilig geweigerd")
        check(Calculator.format(1234.5, locale: Locale(identifier: "nl")) == "1234,5"
              && Calculator.format(12345.5, locale: Locale(identifier: "en")) == "12,345.5", "uitkomst in de taal van de gebruiker")

        check(FileSearch.isNoise("/Users/x/Projects/site/node_modules/next/dist/x.json")
              && FileSearch.isNoise("/Users/x/Pictures/Lightroom Library.lrlibrary/abc/previews/d4/x1yvgckbjt8251xcr1gxhpwwbcn51enu8.jpg")
              && FileSearch.isNoise("/Users/x/Library/Caches/a.txt") && !FileSearch.isNoise("/Users/x/Documents/Safari tips.pdf"),
              "snelstarter filtert ontwikkelmappen, caches en previews")
        let apps = AppIndex.scan()
        check(apps.count > 10 && apps.contains { $0.name == "Safari" || $0.name == "Finder" || $0.name.contains("Settings") },
              "app-index vindt geïnstalleerde apps (\(apps.count))")
        check(Set(apps.map { $0.name.lowercased() }).count == apps.count, "geen dubbele apps in de index")
    }

    @MainActor
    private static func testLauncherModel() {
        print("== Snelstarter en Google ==")
        check(WebSearch.googleURL(for: "c++ & co")?.absoluteString == "https://www.google.com/search?q=c%2B%2B%20%26%20co",
              "Google-link: + & en spaties goed gecodeerd")
        check(WebSearch.googleURL(for: "weer Zürich #1?")?.absoluteString == "https://www.google.com/search?q=weer%20Z%C3%BCrich%20%231%3F",
              "Google-link: accenten, # en ? goed gecodeerd")
        check(WebSearch.googleURL(for: "   ") == nil && WebSearch.googleURL(for: String(repeating: "a", count: 3000)) == nil,
              "lege of veel te lange zoekopdracht → geen link")
        check(WebSearch.prefixedQuery("g weer amsterdam") == "weer amsterdam" && WebSearch.prefixedQuery("Google  maps") == "maps"
              && WebSearch.prefixedQuery("gmail") == nil && WebSearch.prefixedQuery("g ") == nil, "voorvoegsel ‘g ’ zoekt meteen op Google")
        let model = LauncherModel()
        var opened: [URL] = []
        model.openURL = { opened.append($0) }
        model.query = "g weer amsterdam"
        check(model.results.count == 1 && model.results[0].isWeb, "‘g …’ toont alleen de Google-regel")
        model.activate()
        check(opened.last?.absoluteString == "https://www.google.com/search?q=weer%20amsterdam", "↩ op de Google-regel opent google.com")
        model.query = "2+3*4"
        check(model.results.first?.title == "= 14" && model.results.last?.isWeb == true, "berekening bovenaan, Google-regel onderaan")
        model.searchGoogle()
        check(opened.last?.absoluteString == "https://www.google.com/search?q=2%2B3%2A4", "⌥↩ zoekt op Google wat er getypt is")
        model.query = ""
        check(model.results.isEmpty, "leeg zoekveld → geen resultaten")
    }

    @MainActor
    private static func testShelf() {
        print("== Bestandsplank ==")
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tlg-shelf-\(getpid())", isDirectory: true)
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("tlg.shelf.\(getpid())")
        defer {
            try? fm.removeItem(at: root)
            try? fm.removeItem(atPath: path + ".plist")
        }
        do {
            let source = root.appendingPathComponent("bron", isDirectory: true)
            let target = root.appendingPathComponent("doel", isDirectory: true)
            try fm.createDirectory(at: source, withIntermediateDirectories: true)
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            let a = source.appendingPathComponent("foto.jpg"), b = source.appendingPathComponent("notities.txt")
            try Data("a".utf8).write(to: a)
            try Data("b".utf8).write(to: b)
            guard let defaults = UserDefaults(suiteName: path) else { check(false, "tijdelijke voorkeuren"); return }

            let store = ShelfStore(defaults: defaults)
            check(store.destinations.count >= 1, "standaardmappen (Bureaublad, Downloads, Documenten)")
            store.add([a, b, a, URL(fileURLWithPath: "/bestaat/niet.txt"), URL(string: "https://example.com")!])
            check(store.items.count == 2, "plank neemt alleen bestaande bestanden op, zonder dubbele")
            check(ShelfStore(defaults: defaults).items.count == 2, "plank blijft bewaard na herstart")

            check(store.transfer([a], to: target, move: false) && fm.fileExists(atPath: target.appendingPathComponent("foto.jpg").path)
                  && fm.fileExists(atPath: a.path), "kopiëren naar map")
            store.transfer([a], to: target, move: false)
            check(fm.fileExists(atPath: target.appendingPathComponent("foto 2.jpg").path), "nooit overschrijven: ‘foto 2.jpg’")
            check(ShelfStore.uniqueDestination(for: "map", in: target).lastPathComponent == "map", "naam zonder extensie")

            check(store.transfer([b], to: target, move: true) && !fm.fileExists(atPath: b.path)
                  && fm.fileExists(atPath: target.appendingPathComponent("notities.txt").path)
                  && store.items.count == 1, "verplaatsen haalt het bestand ook van de plank")
            check(!store.transfer([source.appendingPathComponent("weg.txt")], to: target, move: false)
                  && (store.status ?? "").isEmpty == false, "mislukte kopie geeft een melding (geen crash)")

            try fm.removeItem(at: a)
            check(ShelfStore(defaults: defaults).items.isEmpty, "verdwenen bestanden verdwijnen ook van de plank")
            store.addDestination(target)
            store.addDestination(target)
            check(store.destinations.filter { $0 == target }.count == 1, "map niet dubbel toevoegen")
            store.removeDestination(target)
            check(!store.destinations.contains(target), "map verwijderen")
            store.clear()
            check(store.items.isEmpty, "plank leegmaken")
            defaults.removePersistentDomain(forName: path)
        } catch {
            check(false, "bestandsplank: \(error.liquidDescription)")
        }
    }

    // MARK: Dock & settings

    private static func testDockAndSettings() {
        print("== Dock & instellingen ==")
        check(DockEdge.fromOrientation("left") == .left && DockEdge.fromOrientation("right") == .right
              && DockEdge.fromOrientation(nil) == .bottom && DockEdge.fromOrientation("bogus") == .bottom,
              "Dock-positie uit voorkeuren")
        check(DockLocator.normalized(URL(fileURLWithPath: "/Applications/Safari.app/"))
              == DockLocator.normalized(URL(fileURLWithPath: "/Applications/Safari.app")), "app-URL's vergelijken zonder slash")
        let prefs = DockLocator.preferences()
        print("    (Dock: \(prefs.edge), minimaliseer naar app: \(prefs.minimizeToApplication), automatisch verbergen: \(prefs.autohide))")
        let estimate = DockLocator.estimate(edge: prefs.edge)
        check(estimate.pointQuartz.x.isFinite && estimate.pointQuartz.y.isFinite, "Dock-schatting is eindig (\(estimate.pointQuartz))")

        check(AppSettings.presets.count >= 5 && Set(AppSettings.presets.map(\.name)).count == AppSettings.presets.count,
              "voorinstellingen hebben unieke namen")
        check(AppSettings.presets.allSatisfy { AppSettings.strengthRange.contains($0.strength) }, "voorinstellingen geldig")
        let p3 = MainActor.assumeIsolated { MinimizeCoordinator.shaderColor(WaterColor(red: 1, green: 0, blue: 0)) }
        check(p3.x > 0.85 && p3.y < 0.3 && p3.z < 0.3 && [p3.x, p3.y, p3.z].allSatisfy { $0 >= 0 && $0 <= 1 },
              "sRGB-rood wordt correct omgezet naar Display P3 (\(p3))")
        check(AppSettings.clamp(.nan, to: AppSettings.speedRange, fallback: 1) == 1, "NaN-snelheid → standaard")
        check(AppSettings.clamp(99, to: AppSettings.speedRange, fallback: 1) == 2, "te hoge snelheid wordt begrensd")
        if let (defaults, cleanup) = temporaryDefaults("instellingen") {
            defer { cleanup() }
            defaults.set("onzin", forKey: "animationSpeed")
            defaults.set(-5.0, forKey: "waterColorStrength")
            defaults.set(["rood", "groen"], forKey: "waterColorRGB")
            let settings = AppSettings(defaults: defaults)
            check(settings.speed == 1.0, "corrupte snelheid in voorkeuren → 1.0 (\(settings.speed))")
            check(settings.colorStrength == 0.0, "negatieve kleurdiepte wordt 0")
            check(settings.waterColor == .default, "corrupte kleur in voorkeuren → standaardkleur")
            settings.speed = 5
            check(settings.speed == 2 && defaults.double(forKey: "animationSpeed") == 2, "snelheid wordt bij opslaan begrensd")
            settings.colorStrength = 7
            check(settings.colorStrength == 1, "kleurdiepte wordt bij opslaan begrensd")

            defaults.set([2.0, -1.0, 0.5], forKey: "waterColorRGB")
            let clampedColor = AppSettings(defaults: defaults).waterColor
            check(clampedColor == WaterColor(red: 1, green: 0, blue: 0.5), "kleur buiten bereik wordt begrensd")
            defaults.set([Double.nan, 0.2, 0.3], forKey: "waterColorRGB")
            check(AppSettings(defaults: defaults).waterColor == .default, "NaN in kleur → standaardkleur")

            let sea = AppSettings.presets[1]
            settings.apply(sea)
            check(settings.waterColor == sea.color && settings.colorStrength == sea.strength
                  && settings.activePreset?.name == sea.name, "voorinstelling ‘\(sea.name)’ toepassen")
            let reloaded = AppSettings(defaults: defaults)
            check(reloaded.waterColor == sea.color && reloaded.colorStrength == sea.strength, "kleur blijft bewaard na herstart")
            settings.waterColor = WaterColor(red: 0.5, green: 0.1, blue: 0.9)
            check(settings.activePreset == nil, "eigen kleur heeft geen voorinstelling")
        } else {
            check(false, "tijdelijke voorkeuren aanmaken")
        }
    }

    /// Preferences for the tests live in the temporary folder (an absolute suite path),
    /// never in ~/Library/Preferences, and are removed afterwards.
    private static func temporaryDefaults(_ name: String) -> (UserDefaults, () -> Void)? {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("nl.liquidvenster.selftest.\(name).\(getpid())")
        guard let defaults = UserDefaults(suiteName: path) else { return nil }
        return (defaults, {
            defaults.removePersistentDomain(forName: path)
            try? FileManager.default.removeItem(atPath: path + ".plist")
        })
    }

    // MARK: GPU rendering

    static func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: WindowCapture.colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    /// A fake window: gradient content, title bar, traffic lights, rounded corners.
    private static func syntheticWindow(width: Int, height: Int, scale: CGFloat) -> CGImage? {
        guard let ctx = makeContext(width: width, height: height) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 12 * scale, cornerHeight: 12 * scale, transform: nil))
        ctx.clip()
        let colors = [CGColor(srgbRed: 0.98, green: 0.62, blue: 0.27, alpha: 1),
                      CGColor(srgbRed: 0.85, green: 0.25, blue: 0.48, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: WindowCapture.colorSpace, colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: .zero, options: [])
        }
        ctx.setFillColor(CGColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1))
        ctx.fill(CGRect(x: 0, y: CGFloat(height) - 28 * scale, width: CGFloat(width), height: 28 * scale))
        let lights = [CGColor(srgbRed: 1, green: 0.37, blue: 0.34, alpha: 1),
                      CGColor(srgbRed: 1, green: 0.74, blue: 0.18, alpha: 1),
                      CGColor(srgbRed: 0.16, green: 0.79, blue: 0.25, alpha: 1)]
        for (i, color) in lights.enumerated() {
            ctx.setFillColor(color)
            ctx.fillEllipse(in: CGRect(x: (14 + CGFloat(i) * 20) * scale, y: CGFloat(height) - 20 * scale,
                                       width: 12 * scale, height: 12 * scale))
        }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.75))
        for i in 0..<8 {
            ctx.fill(CGRect(x: 30 * scale, y: CGFloat(height) - (64 + CGFloat(i) * 26) * scale,
                            width: (180 + CGFloat(i * 17 % 90)) * scale, height: 10 * scale))
        }
        return ctx.makeImage()
    }

    /// A fake desktop: sky gradient, grid and a Dock with icons.
    static let syntheticDockIcons = 9

    /// Centre (overlay points, top-left origin) of an icon of the synthetic Dock.
    static func syntheticDockIcon(_ index: Int, viewSize: CGSize) -> CGPoint {
        let slot = viewSize.width * 0.5 / CGFloat(syntheticDockIcons)
        return CGPoint(x: viewSize.width * 0.25 + slot * (CGFloat(index) + 0.5), y: viewSize.height - 4 - 32)
    }

    static func syntheticDesktop(width: Int, height: Int, scale: CGFloat, dockIcon: CGPoint) -> CGImage? {
        guard let ctx = makeContext(width: width, height: height) else { return nil }
        let colors = [CGColor(srgbRed: 0.20, green: 0.32, blue: 0.62, alpha: 1),
                      CGColor(srgbRed: 0.55, green: 0.75, blue: 0.92, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: WindowCapture.colorSpace, colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: .zero, options: [])
        }
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.12))
        ctx.setLineWidth(scale)
        var x: CGFloat = 0
        while x < CGFloat(width) { ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: CGFloat(height))); x += 60 * scale }
        var y: CGFloat = 0
        while y < CGFloat(height) { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: CGFloat(width), y: y)); y += 60 * scale }
        ctx.strokePath()
        // Dock (CG origin is bottom-left). Icons are spread evenly over the Dock's width.
        let dock = CGRect(x: CGFloat(width) * 0.25, y: 4 * scale, width: CGFloat(width) * 0.5, height: 64 * scale)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.35))
        ctx.addPath(CGPath(roundedRect: dock, cornerWidth: 18 * scale, cornerHeight: 18 * scale, transform: nil))
        ctx.fillPath()
        let slot = dock.width / CGFloat(syntheticDockIcons)
        let icon = min(48 * scale, slot * 0.78)
        for i in 0..<syntheticDockIcons {
            let cx = dock.minX + slot * (CGFloat(i) + 0.5)
            let hue = CGFloat(i) / CGFloat(syntheticDockIcons)
            ctx.setFillColor(NSColor(hue: hue, saturation: 0.6, brightness: 0.95, alpha: 1).cgColor)
            ctx.addPath(CGPath(roundedRect: CGRect(x: cx - icon / 2, y: dock.midY - icon / 2, width: icon, height: icon),
                               cornerWidth: icon * 0.23, cornerHeight: icon * 0.23, transform: nil))
            ctx.fillPath()
        }
        return ctx.makeImage()
    }

    private struct Diff {
        var maxDiff = 0
        var count = 0
        var total = 0
    }

    private static func pixel(_ p: PixelData, _ x: Int, _ y: Int) -> (Int, Int, Int, Int) {
        let i = y * p.bytesPerRow + x * 4
        return (Int(p.bytes[i + 2]), Int(p.bytes[i + 1]), Int(p.bytes[i]), Int(p.bytes[i + 3]))
    }

    private static func compare(_ a: PixelData, _ b: PixelData, region: (x: Range<Int>, y: Range<Int>)? = nil, threshold: Int = 3) -> Diff {
        var diff = Diff()
        let xs = region?.x ?? 0..<min(a.width, b.width)
        let ys = region?.y ?? 0..<min(a.height, b.height)
        for y in ys where y >= 0 && y < a.height && y < b.height {
            for x in xs where x >= 0 && x < a.width && x < b.width {
                let pa = pixel(a, x, y), pb = pixel(b, x, y)
                let d = max(abs(pa.0 - pb.0), abs(pa.1 - pb.1), abs(pa.2 - pb.2))
                diff.maxDiff = max(diff.maxDiff, d)
                if d > threshold { diff.count += 1 }
                diff.total += 1
            }
        }
        return diff
    }

    static func image(from p: PixelData) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(p.bytes) as CFData) else { return nil }
        return CGImage(width: p.width, height: p.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: p.bytesPerRow,
                       space: WindowCapture.colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private static func writePNG(_ p: PixelData, to url: URL) {
        guard let cg = image(from: p),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            print("    kon \(url.lastPathComponent) niet schrijven")
            return
        }
        CGImageDestinationAddImage(destination, cg, nil)
        if !CGImageDestinationFinalize(destination) { print("    kon \(url.lastPathComponent) niet schrijven") }
    }

    private static func testRendering(outputDirectory: String?) {
        print("== GPU-rendering ==")
        let renderer: LiquidRenderer
        switch LiquidRenderer.shared() {
        case .success(let r):
            renderer = r
            check(true, "shaders compileren (\(r.device.name))")
        case .failure(let error):
            check(false, "shaders compileren: \(error.liquidDescription)")
            return
        }

        let scale: CGFloat = 2
        let view = CGSize(width: 1200, height: 800)
        let windowRect = CGRect(x: 300, y: 150, width: 400, height: 300)
        let target = syntheticDockIcon(4, viewSize: view)   // fifth Dock icon
        guard let windowImage = syntheticWindow(width: Int(windowRect.width * scale), height: Int(windowRect.height * scale), scale: scale),
              let desktop = syntheticDesktop(width: Int(view.width * scale), height: Int(view.height * scale), scale: scale, dockIcon: target) else {
            check(false, "testbeelden maken")
            return
        }

        var outputURL: URL?
        if let outputDirectory {
            let url = URL(fileURLWithPath: outputDirectory, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                outputURL = url
            } catch {
                print("    uitvoermap niet beschikbaar: \(error.liquidDescription)")
            }
        }

        for opaque in [true, false] {
            let mode = opaque ? "met achtergrond" : "transparant"
            do {
                let (windowTexture, windowPixels) = try renderer.makeTexture(from: windowImage, colorSpace: WindowCapture.colorSpace, keepPixels: true)
                let (backgroundTexture, backgroundPixels) = try renderer.makeTexture(from: desktop, colorSpace: WindowCapture.colorSpace, keepPixels: true)
                guard let windowPixels, let backgroundPixels else { check(false, "pixeldata"); return }
                check(windowPixels.coverage() > 0.9 && windowPixels.alpha(u: 0, v: 0) < 0.05 && windowPixels.alpha(u: 0.5, v: 0.5) > 0.99,
                      "vensterbeeld heeft ronde hoeken en een dichte inhoud")

                var input = LiquidSceneInput(viewSize: view, windowRect: windowRect, target: target,
                                             rippleOrigin: CGPoint(x: windowRect.minX + 40, y: windowRect.minY + 14),
                                             edge: .bottom, drainRadius: 10, floorY: target.y - 26, opaqueBackground: opaque,
                                             waterColor: SIMD3(0.62, 0.84, 0.98), colorStrength: 0.45, cornerRadius: 12,
                                             alphaAt: { u, v in windowPixels.alpha(u: u, v: v) })
                input.seed = 1234
                let scene = try LiquidScene.build(input)
                let session = try LiquidRenderSession(renderer: renderer, scene: scene, windowTexture: windowTexture,
                                                      backgroundTexture: opaque ? backgroundTexture : nil)
                let pw = Int(view.width * scale), ph = Int(view.height * scale)

                // First frame: must look exactly like the screen before the click.
                let first = try session.renderOffscreen(time: 0, pixelWidth: pw, pixelHeight: ph)
                let wx = Int(windowRect.minX * scale), wy = Int(windowRect.minY * scale)
                var maxWindowDiff = 0
                var maxAlphaDiff = 0
                for (u, v) in [(0.5, 0.5), (0.1, 0.5), (0.9, 0.9), (0.5, 0.05), (0.2, 0.3), (0.95, 0.5)] {
                    let x = Int(Double(windowPixels.width) * u), y = Int(Double(windowPixels.height) * v)
                    let out = pixel(first, wx + x, wy + y)
                    let win = pixel(windowPixels, x, y)
                    maxWindowDiff = max(maxWindowDiff, abs(out.0 - win.0), abs(out.1 - win.1), abs(out.2 - win.2))
                    maxAlphaDiff = max(maxAlphaDiff, abs(out.3 - 255))
                }
                check(maxWindowDiff <= 2 && maxAlphaDiff == 0, "\(mode): eerste frame = origineel venster (max verschil \(maxWindowDiff))")
                let far = [(20, 20), (pw - 30, 40), (40, ph / 2), (pw - 60, ph / 2)]
                if opaque {
                    let farDiff = far.map { (x, y) -> Int in
                        let a = pixel(first, x, y), b = pixel(backgroundPixels, x, y)
                        return max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2))
                    }.max() ?? 0
                    check(farDiff <= 2, "\(mode): eerste frame = achtergrond buiten het venster (max \(farDiff))")
                } else {
                    check(far.allSatisfy { pixel(first, $0.0, $0.1).3 == 0 }, "\(mode): buiten het venster volledig doorzichtig")
                }

                // Last frame: nothing may be left behind.
                let last = try session.renderOffscreen(time: scene.totalDuration, pixelWidth: pw, pixelHeight: ph)
                if opaque {
                    let diff = compare(last, backgroundPixels, threshold: 2)
                    check(diff.maxDiff <= 2, "\(mode): laatste frame = schone achtergrond (max verschil \(diff.maxDiff), \(diff.count) px)")
                } else {
                    var maxAlpha = 0
                    for y in stride(from: 0, to: ph, by: 3) { for x in stride(from: 0, to: pw, by: 3) { maxAlpha = max(maxAlpha, pixel(last, x, y).3) } }
                    check(maxAlpha == 0, "\(mode): laatste frame volledig doorzichtig (max alpha \(maxAlpha))")
                }

                // Middle: water must reach the Dock icon.
                let middle = try session.renderOffscreen(time: (scene.firstArrival + scene.lastArrival) / 2, pixelWidth: pw, pixelHeight: ph)
                let tx = Int(target.x * scale), ty = Int(target.y * scale)
                let around = (x: (tx - 60)..<(tx + 60), y: (ty - 120)..<(ty + 10))
                if opaque {
                    let diff = compare(middle, backgroundPixels, region: around, threshold: 12)
                    check(diff.count > diff.total / 20, "\(mode): water stroomt het Dock-icoon in (\(diff.count)/\(diff.total) px)")
                } else {
                    var visible = 0, total = 0
                    for y in around.y { for x in around.x { total += 1; if pixel(middle, x, y).3 > 40 { visible += 1 } } }
                    check(visible > total / 20, "\(mode): water stroomt het Dock-icoon in (\(visible)/\(total) px)")
                }

                // Near the end the window area should be (almost) empty again.
                let late = try session.renderOffscreen(time: scene.totalDuration * 0.88, pixelWidth: pw, pixelHeight: ph)
                let windowRegion = (x: wx..<(wx + windowPixels.width), y: wy..<(wy + windowPixels.height))
                if opaque {
                    let diff = compare(late, backgroundPixels, region: windowRegion, threshold: 8)
                    check(diff.count < diff.total / 10, "\(mode): vensterplek is bijna leeg aan het eind (\(diff.count)/\(diff.total) px)")
                } else {
                    var visible = 0, total = 0
                    for y in stride(from: windowRegion.y.lowerBound, to: windowRegion.y.upperBound, by: 2) {
                        for x in stride(from: windowRegion.x.lowerBound, to: windowRegion.x.upperBound, by: 2) {
                            total += 1
                            if pixel(late, x, y).3 > 20 { visible += 1 }
                        }
                    }
                    check(visible < total / 10, "\(mode): vensterplek is bijna leeg aan het eind (\(visible)/\(total) px)")
                }

                // Out-of-range times must be clamped, not crash or draw garbage.
                let negative = try session.renderOffscreen(time: -5, pixelWidth: 64, pixelHeight: 64)
                let nan = try session.renderOffscreen(time: .nan, pixelWidth: 64, pixelHeight: 64)
                check(negative.width == 64 && nan.width == 64, "\(mode): negatieve en NaN-tijd veilig afgehandeld")

                // Performance at retina size.
                let commandQueue = renderer.queue
                if let target = makeTarget(renderer: renderer, width: pw, height: ph) {
                    let frames = 40
                    let start = CACurrentMediaTime()
                    for i in 0..<frames {
                        guard let cb = commandQueue.makeCommandBuffer() else { break }
                        try session.encode(into: cb, target: target, time: scene.totalDuration * Float(i) / Float(frames))
                        cb.commit()
                        if i == frames - 1 { cb.waitUntilCompleted() }
                    }
                    let ms = (CACurrentMediaTime() - start) * 1000 / Double(frames)
                    print(String(format: "    %@: %.2f ms per frame (%d druppels, %dx%d px)", mode, ms, scene.particles.count, pw, ph))
                    check(ms < 16, String(format: "\(mode): snel genoeg voor 60 fps (%.2f ms)", ms))
                }

                if let outputURL {
                    let times: [Float] = [0, 0.12, 0.25, 0.35, 0.45, 0.55, 0.7, 0.85, 1.0, 1.15]
                    for t in times where t <= scene.totalDuration {
                        let frame = try session.renderOffscreen(time: t, pixelWidth: pw / 2, pixelHeight: ph / 2)
                        writePNG(frame, to: outputURL.appendingPathComponent(String(format: "%@-%04d.png", opaque ? "opaak" : "transparant", Int(t * 1000))))
                    }
                }
            } catch {
                check(false, "\(mode): renderen: \(error.liquidDescription)")
            }
        }
        testWaterColors(renderer: renderer, windowImage: windowImage, desktop: desktop, view: view,
                        windowRect: windowRect, target: target, scale: scale, outputURL: outputURL)
        testSteam(renderer: renderer, windowImage: windowImage, desktop: desktop, view: view,
                  windowRect: windowRect, scale: scale, outputURL: outputURL)
        if let outputURL { print("    frames opgeslagen in \(outputURL.path)") }
    }

    // MARK: Own window snapshot (the path without Screen Recording permission)

    @MainActor
    private static func testOwnWindowSnapshot(outputDirectory: String?) {
        print("== Momentopname eigen venster ==")
        _ = NSApplication.shared
        let window = LiquidWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.title = "Zelftest"
        window.contentView = DemoContentView(palette: 1)
        defer { window.close() }
        do {
            let image = try WindowCapture.snapshotOwnWindow(window)
            let scale = window.backingScaleFactor
            check(image.width == Int(420 * scale) && image.height == Int(300 * scale),
                  "momentopname heeft de juiste grootte (\(image.width)x\(image.height))")
            guard case .success(let renderer) = LiquidRenderer.shared() else { check(false, "renderer"); return }
            let (_, pixels) = try renderer.makeTexture(from: image, colorSpace: WindowCapture.colorSpace, keepPixels: true,
                                                      cornerRadiusPixels: MinimizeCoordinator.windowCornerRadius * scale)
            guard let pixels else { check(false, "pixeldata"); return }
            check(pixels.coverage() > 0.95, "momentopname is gevuld (dekking \(String(format: "%.0f", pixels.coverage() * 100))%)")
            check(pixels.alpha(u: 0.001, v: 0.001) < 0.1 && pixels.alpha(u: 0.5, v: 0.5) > 0.99, "hoeken afgerond, midden dicht")
            // The content must really be drawn (not a blank/black bitmap).
            let mid = pixel(pixels, pixels.width / 2, pixels.height - 4)
            check(mid.0 + mid.1 + mid.2 > 120, "inhoud van het venster is getekend (rgb \(mid.0),\(mid.1),\(mid.2))")
            if let outputDirectory {
                writePNG(pixels, to: URL(fileURLWithPath: outputDirectory).appendingPathComponent("eigen-venster.png"))
            }
        } catch {
            check(false, "momentopname: \(error.liquidDescription)")
        }

        // The settings window must lay out and draw (incl. colour picker and presets).
        let actions = SettingsActions(openDemo: {}, testEffect: {}, requestAccessibility: {}, requestScreenCapture: {},
                                      openAccessibilitySettings: {}, openScreenCaptureSettings: {}, resetPermissions: {},
                                      relaunch: {}, showInFinder: {}, refresh: {})
        guard let (uiDefaults, cleanupDefaults) = temporaryDefaults("ui") else {
            check(false, "tijdelijke voorkeuren voor het instellingenscherm")
            return
        }
        defer { cleanupDefaults() }
        let settings = AppSettings(defaults: uiDefaults)
        let host = NSHostingView(rootView: SettingsView(settings: settings, status: AppStatus(), log: AppLog.shared,
                                                localizer: Localizer.shared, actions: actions)
            .frame(width: 540, height: 900))
        host.frame = NSRect(x: 0, y: 0, width: 540, height: 900)
        let settingsWindow = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.contentView = host
        host.layoutSubtreeIfNeeded()
        defer { settingsWindow.close() }
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            check(rep.pixelsWide > 0 && rep.pixelsHigh > 0, "instellingenscherm wordt getekend (\(rep.pixelsWide)x\(rep.pixelsHigh))")
            if let outputDirectory, let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: outputDirectory).appendingPathComponent("instellingen.png"))
            }
        } else {
            check(false, "instellingenscherm tekenen")
        }
    }

    /// Red button: the window evaporates into rising steam and nothing is left afterwards.
    private static func testSteam(renderer: LiquidRenderer, windowImage: CGImage, desktop: CGImage, view: CGSize,
                                  windowRect: CGRect, scale: CGFloat, outputURL: URL?) {
        print("== Verdampen (rode knop) ==")
        for opaque in [true, false] {
            let mode = opaque ? "stoom met achtergrond" : "stoom transparant"
            do {
                let (windowTexture, windowPixels) = try renderer.makeTexture(from: windowImage, colorSpace: WindowCapture.colorSpace, keepPixels: true)
                let (backgroundTexture, backgroundPixels) = try renderer.makeTexture(from: desktop, colorSpace: WindowCapture.colorSpace, keepPixels: true)
                guard let windowPixels, let backgroundPixels else { check(false, "pixeldata"); return }
                var input = LiquidSceneInput(viewSize: view, windowRect: windowRect, target: CGPoint(x: 600, y: 770),
                                             rippleOrigin: CGPoint(x: windowRect.minX + 20, y: windowRect.minY + 14),
                                             edge: .bottom, drainRadius: 10, floorY: 744, opaqueBackground: opaque,
                                             waterColor: SIMD3(0.62, 0.84, 0.98), colorStrength: 0.45, cornerRadius: 12,
                                             effect: .steam, alphaAt: { u, v in windowPixels.alpha(u: u, v: v) })
                input.seed = 77
                let scene = try LiquidScene.build(input)
                check(scene.particles.count <= LiquidScene.maxSteamParticles + LiquidScene.maxSteamParticles / 10
                      && scene.particles.allSatisfy { $0.d.w == 2 }, "\(mode): stoomdeeltjes (\(scene.particles.count))")
                check(scene.totalDuration > 0.8 && scene.totalDuration < 1.9, String(format: "\(mode): duur %.2f s", scene.totalDuration))
                check(scene.fluidScale == 0.5 && scene.gravity == 0, "\(mode): halve resolutie, geen zwaartekracht")
                let session = try LiquidRenderSession(renderer: renderer, scene: scene, windowTexture: windowTexture,
                                                      backgroundTexture: opaque ? backgroundTexture : nil)
                let pw = Int(view.width * scale), ph = Int(view.height * scale)

                let first = try session.renderOffscreen(time: 0, pixelWidth: pw, pixelHeight: ph)
                let wx = Int(windowRect.minX * scale), wy = Int(windowRect.minY * scale)
                var maxDiff = 0
                for (u, v) in [(0.5, 0.5), (0.1, 0.5), (0.9, 0.9), (0.5, 0.05)] {
                    let x = Int(Double(windowPixels.width) * u), y = Int(Double(windowPixels.height) * v)
                    let a = pixel(first, wx + x, wy + y), b = pixel(windowPixels, x, y)
                    maxDiff = max(maxDiff, abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2))
                }
                check(maxDiff <= 2, "\(mode): eerste frame = origineel venster (max verschil \(maxDiff))")

                let last = try session.renderOffscreen(time: scene.totalDuration, pixelWidth: pw, pixelHeight: ph)
                if opaque {
                    let diff = compare(last, backgroundPixels, threshold: 2)
                    check(diff.maxDiff <= 2, "\(mode): laatste frame = schone achtergrond (max \(diff.maxDiff))")
                } else {
                    var maxAlpha = 0
                    for y in stride(from: 0, to: ph, by: 3) { for x in stride(from: 0, to: pw, by: 3) { maxAlpha = max(maxAlpha, pixel(last, x, y).3) } }
                    check(maxAlpha == 0, "\(mode): laatste frame volledig doorzichtig (max alpha \(maxAlpha))")
                }

                // Halfway the steam must have risen above the window.
                let middle = try session.renderOffscreen(time: 0.75, pixelWidth: pw, pixelHeight: ph)
                let above = (x: wx..<(wx + windowPixels.width), y: max(0, wy - 240)..<wy)
                var steamPixels = 0, total = 0
                for y in stride(from: above.y.lowerBound, to: above.y.upperBound, by: 2) {
                    for x in stride(from: above.x.lowerBound, to: above.x.upperBound, by: 2) {
                        total += 1
                        let a = pixel(middle, x, y)
                        if opaque {
                            let b = pixel(backgroundPixels, x, y)
                            if max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2)) > 10 { steamPixels += 1 }
                        } else if a.3 > 25 {
                            steamPixels += 1
                        }
                    }
                }
                check(steamPixels > total / 15, "\(mode): stoom stijgt boven het venster uit (\(steamPixels)/\(total) px)")

                if let outputURL {
                    for t: Float in [0, 0.2, 0.35, 0.5, 0.7, 0.9, 1.2] where t <= scene.totalDuration {
                        let frame = try session.renderOffscreen(time: t, pixelWidth: pw / 2, pixelHeight: ph / 2)
                        writePNG(frame, to: outputURL.appendingPathComponent(String(format: "%@-%04d.png",
                                 opaque ? "stoom" : "stoom-transparant", Int(t * 1000))))
                    }
                }
            } catch {
                check(false, "\(mode): \(error.liquidDescription)")
            }
        }
    }

    /// The chosen colour must really end up in the water, and a deeper colour must absorb more light.
    private static func testWaterColors(renderer: LiquidRenderer, windowImage: CGImage, desktop: CGImage, view: CGSize,
                                        windowRect: CGRect, target: CGPoint, scale: CGFloat, outputURL: URL?) {
        print("== Waterkleur ==")
        do {
            let (windowTexture, windowPixels) = try renderer.makeTexture(from: windowImage, colorSpace: WindowCapture.colorSpace, keepPixels: true)
            let (backgroundTexture, backgroundPixels) = try renderer.makeTexture(from: desktop, colorSpace: WindowCapture.colorSpace, keepPixels: true)
            guard let windowPixels, let backgroundPixels else { check(false, "pixeldata"); return }
            let pw = Int(view.width * scale), ph = Int(view.height * scale)

            func render(_ color: SIMD3<Float>, _ strength: Float, name: String? = nil) throws -> (r: Double, g: Double, b: Double, count: Int) {
                var input = LiquidSceneInput(viewSize: view, windowRect: windowRect, target: target,
                                             rippleOrigin: CGPoint(x: windowRect.minX + 40, y: windowRect.minY + 14),
                                             edge: .bottom, drainRadius: 10, floorY: target.y - 26, opaqueBackground: true,
                                             waterColor: color, colorStrength: strength, cornerRadius: 12,
                                             alphaAt: { u, v in windowPixels.alpha(u: u, v: v) })
                input.seed = 99
                let scene = try LiquidScene.build(input)
                let session = try LiquidRenderSession(renderer: renderer, scene: scene, windowTexture: windowTexture,
                                                      backgroundTexture: backgroundTexture)
                let frame = try session.renderOffscreen(time: (scene.firstArrival + scene.lastArrival) / 2, pixelWidth: pw, pixelHeight: ph)
                if let outputURL, let name {
                    let small = try session.renderOffscreen(time: (scene.firstArrival + scene.lastArrival) / 2,
                                                            pixelWidth: pw / 2, pixelHeight: ph / 2)
                    writePNG(small, to: outputURL.appendingPathComponent("kleur-\(name).png"))
                }
                var sum = (0.0, 0.0, 0.0)
                var count = 0
                for y in stride(from: 0, to: ph, by: 2) {
                    for x in stride(from: 0, to: pw, by: 2) {
                        let a = pixel(frame, x, y), b = pixel(backgroundPixels, x, y)
                        if max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2)) > 12 {
                            sum.0 += Double(a.0); sum.1 += Double(a.1); sum.2 += Double(a.2)
                            count += 1
                        }
                    }
                }
                let n = Double(max(count, 1))
                return (sum.0 / n, sum.1 / n, sum.2 / n, count)
            }

            let red = try render(SIMD3(0.95, 0.15, 0.10), 0.8, name: "rood")
            let blue = try render(SIMD3(0.10, 0.30, 0.95), 0.8, name: "blauw")
            let clear = try render(SIMD3(0.10, 0.30, 0.95), 0.0, name: "blauw-helder")
            check(red.count > 1000 && blue.count > 1000, "water zichtbaar in beide kleuren (\(red.count) / \(blue.count) px)")
            let redRatio = red.r / max(red.b, 1), blueRatio = blue.r / max(blue.b, 1)
            check(redRatio > blueRatio * 1.3, String(format: "rood water is roder dan blauw water (R/B %.2f vs %.2f)", redRatio, blueRatio))
            let deepLight = blue.r + blue.g + blue.b, clearLight = clear.r + clear.g + clear.b
            check(deepLight < clearLight, String(format: "meer kleurdiepte laat minder licht door (%.0f < %.0f)", deepLight, clearLight))
            for preset in AppSettings.presets where ["Zee", "Limonade", "Cola"].contains(preset.name) {
                let c = MainActor.assumeIsolated { MinimizeCoordinator.shaderColor(preset.color) }
                _ = try render(c, Float(preset.strength), name: preset.name.lowercased())
            }
        } catch {
            check(false, "kleurtest: \(error.liquidDescription)")
        }
    }

    private static func makeTarget(renderer: LiquidRenderer, width: Int, height: Int) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: LiquidRenderer.outputFormat, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget]
        desc.storageMode = .private
        return renderer.device.makeTexture(descriptor: desc)
    }
}
