import AppKit
import Carbon.HIToolbox

/// Checks the panel preferences against a scratch defaults suite -- never the
/// user's own -- plus which rows keep their Japanese line and the hot key's
/// modifier bits.
///
/// Run with `Tsuyaku --store-selftest` (via `make test`).
@MainActor
enum PanelStyleSelfTest {

    private static var failures = 0

    /// One fixed name rather than one per run: clearing a suite still leaves
    /// an empty plist behind in ~/Library/Preferences, and a fresh name each
    /// run would pile them up.
    private static let suite = "com.loind.tsuyaku.selftest"

    /// The suite, emptied.
    private static func scratch() -> UserDefaults {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite)!
    }

    static func run() -> Int {
        failures = 0
        print("\n=== panel style self-test ===")
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = scratch()

        defaultsOnFirstLaunch(defaults)
        choicesSurviveARelaunch(defaults)
        unknownTextSizeFallsBack(defaults)
        textSizesGrow()
        whichRowsShowJapanese()
        hotKeyModifiers()
        return failures
    }

    private static func defaultsOnFirstLaunch(_ defaults: UserDefaults) {
        let style = PanelStyle(defaults: defaults)
        expect("first launch: medium text, Japanese shown, clicks caught",
               style.textSize == .medium && style.showJapanese && !style.clickThrough)
    }

    private static func choicesSurviveARelaunch(_ defaults: UserDefaults) {
        let style = PanelStyle(defaults: defaults)
        style.textSize = .extraLarge
        style.showJapanese = false
        style.clickThrough = true
        let relaunched = PanelStyle(defaults: defaults)
        expect("all three choices survive a relaunch",
               relaunched.textSize == .extraLarge && !relaunched.showJapanese && relaunched.clickThrough)
    }

    private static func unknownTextSizeFallsBack(_ defaults: UserDefaults) {
        defaults.set("gigantic", forKey: "panelTextSize")
        expect("an unknown saved size falls back to medium", PanelStyle(defaults: defaults).textSize == .medium)
    }

    private static func textSizesGrow() {
        let scales = PanelStyle.TextSize.allCases.map(\.scale)
        expect("each size is larger than the last, and medium is as designed",
               zip(scales, scales.dropFirst()).allSatisfy { $0 < $1 }
               && PanelStyle.TextSize.medium.scale == 1)
    }

    private static func whichRowsShowJapanese() {
        let style = PanelStyle(defaults: scratch())
        let row = line("お疲れ様です。", "Thanks for your hard work.")
        let failed = line("納期については", "translation failed: HTTP 401", failed: true)
        let qwen = line("", "Let's begin.")
        let english = line("Let's get started.", "", language: .en)

        expect("a translated row shows its Japanese by default", style.showsSource(of: row))
        expect("an English row has no Japanese line", !style.showsSource(of: english))
        expect("a Qwen row has no source to show", !style.showsSource(of: qwen))
        style.showJapanese = false
        expect("Show Japanese off hides it", !style.showsSource(of: row))
        expect("but a failed row keeps it, having no English", style.showsSource(of: failed))
    }

    private static func hotKeyModifiers() {
        expect("⌃⌥⌘ maps to Carbon's bits",
               GlobalHotKey.carbonModifiers([.control, .option, .command])
               == UInt32(controlKey | optionKey | cmdKey))
        expect("and so does ⇧", GlobalHotKey.carbonModifiers(.shift) == UInt32(shiftKey))
    }

    // MARK: -

    private static func line(_ source: String, _ target: String,
                             failed: Bool = false, language: SpokenLanguage = .ja) -> SubtitleLine {
        SubtitleLine(utterance: UUID(), source: source, target: target, language: language,
                     provisional: false, translationDone: true, failed: failed, at: .now)
    }

    private static func expect(_ what: String, _ ok: Bool) {
        print("  \(ok ? "ok  " : "FAIL") \(what)")
        if !ok { failures += 1 }
    }
}
