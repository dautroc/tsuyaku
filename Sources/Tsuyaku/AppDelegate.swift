import AppKit
import SwiftUI
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let log = Logger(subsystem: "com.loind.tsuyaku", category: "app")
    private let store = SubtitleStore()
    private var statusItem: NSStatusItem?
    private var panel: FloatingPanel?
    private var controller: PipelineController?
    private var downloadHost: TranslationDownloadHost?
    /// Defaults until `loadSettings()` replaces them. Deliberately *not*
    /// `Settings.load()`: see `applicationDidFinishLaunching`.
    private var settings = Settings()
    /// Which providers have a key, read once off the main thread. `hasKey` is a
    /// `SecItemCopyMatching` behind a computed property, and `buildMenu()` asks
    /// it of every provider, so leaving it uncached puts keychain I/O on the
    /// main thread every time the menu is rebuilt.
    private var providersWithKeys: Set<TranslationProvider> = []

    /// The panel goes up before anything reads the keychain.
    ///
    /// `Settings.load()` used to be a property initializer on this class, so it
    /// ran while `main.swift` was still constructing the delegate -- before
    /// `NSApplication.run()`. It reaches the keychain twice over (choosing a
    /// first-run provider, then checking the chosen one still has its key), and
    /// a `SecItemCopyMatching` can take *seconds* the first time a rebuilt
    /// binary asks for an item the user granted to an earlier signature. For
    /// that entire window there was a live process with a menu bar icon and no
    /// subtitle window, which reads exactly like a failed launch.
    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = FloatingPanel(store: store)
        panel?.orderFrontRegardless()
        setUpStatusItem()
        // A display unplugged mid-meeting can strand a restored frame off any
        // screen. Same class of problem as a vanishing audio device: recover
        // rather than leave the user with nothing and no explanation.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel?.recoverIfOffScreen() }
        }
        Task { await loadSettings() }
    }

    /// Everything that touches the keychain, off the main thread, then the
    /// pieces that depend on it.
    private func loadSettings() async {
        let loaded = await Task.detached(priority: .userInitiated) {
            (settings: Settings.load(),
             withKeys: Set(TranslationProvider.allCases.filter(\.isUsable)))
        }.value

        settings = loaded.settings
        providersWithKeys = loaded.withKeys
        controller = PipelineController(store: store, settings: settings)
        statusItem?.menu = buildMenu()
        refreshMenuTitle()
        await checkTranslationModel()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Bundled vector mark, falling back to the SF Symbol it was drawn from
        // so a `swift run` outside the .app still shows something. The
        // `Template` suffix is what makes AppKit tint it for the menu bar's
        // appearance; setting `isTemplate` explicitly costs nothing and
        // survives anyone renaming the file.
        let icon = NSImage(named: "MenuBarIconTemplate")
            ?? NSImage(systemSymbolName: "captions.bubble", accessibilityDescription: nil)
        icon?.isTemplate = true
        icon?.accessibilityDescription = "Tsuyaku"
        item.button?.image = icon
        item.menu = startingMenu()
        statusItem = item
    }

    /// The menu before settings have loaded. Bare on purpose: every item it
    /// leaves out needs to know which providers have keys, and finding that out
    /// means the keychain read we are keeping off this thread. The two items
    /// that need nothing are here, so the app is never unquittable.
    private func startingMenu() -> NSMenu {
        let menu = NSMenu()
        let starting = menu.addItem(withTitle: "Starting…", action: nil, keyEquivalent: "")
        starting.isEnabled = false
        menu.addItem(.separator())
        let panelItem = menu.addItem(withTitle: "Hide Panel", action: #selector(togglePanel), keyEquivalent: "p")
        panelItem.target = self
        panelItem.tag = Tag.panel
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Tsuyaku", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    /// Menu items are addressed by tag rather than by index: two of them
    /// retitle themselves, and index arithmetic breaks the moment the menu
    /// gains a row.
    private enum Tag {
        static let run = 1
        static let panel = 2
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let run = menu.addItem(withTitle: "Start Subtitles", action: #selector(toggle), keyEquivalent: "s")
        run.target = self
        run.tag = Tag.run
        // The panel has no close button any more -- the standard window buttons
        // would float over the header -- so this item is the only way to put it
        // away, and it has to say which way it goes.
        let panelItem = menu.addItem(withTitle: "Hide Panel", action: #selector(togglePanel), keyEquivalent: "p")
        panelItem.target = self
        panelItem.tag = Tag.panel
        menu.addItem(.separator())
        menu.addItem(withTitle: "Copy Transcript", action: #selector(copyTranscript), keyEquivalent: "c").target = self
        menu.addItem(withTitle: "Clear", action: #selector(clear), keyEquivalent: "").target = self
        menu.addItem(.separator())

        let detect = menu.addItem(withTitle: "Detect English Automatically",
                                  action: #selector(toggleAutoDetect), keyEquivalent: "")
        detect.target = self
        detect.state = settings.autoDetectLanguage ? .on : .off
        detect.toolTip = "Run a second English recognizer and show English turns verbatim, untranslated."
        menu.addItem(.separator())

        let translation = NSMenuItem(title: "Translation", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for provider in TranslationProvider.allCases {
            let item = NSMenuItem(title: provider.displayName,
                                  action: #selector(selectProvider(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = provider.rawValue
            item.state = (provider == settings.provider) ? .on : .off
            // A backend that cannot run would silently fall back to on-device,
            // so show it as unavailable instead. Only the coarse reason is
            // shown: the precise one comes from `unusableReason`, which probes
            // the Ollama server and so must not be called while building a menu
            // on the main thread. The CLI paths print the full reason.
            let usable = providersWithKeys.contains(provider)
            item.isEnabled = usable
            if !usable {
                item.title += provider.needsKey ? " — no key" : " — unavailable"
            }
            submenu.addItem(item)
        }
        translation.submenu = submenu
        menu.addItem(translation)

        menu.addItem(withTitle: "Install Japanese Translation…", action: #selector(installModel), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Tsuyaku", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private func refreshMenuTitle() {
        let menu = statusItem?.menu
        menu?.item(withTag: Tag.run)?.title = store.isRunning ? "Stop Subtitles" : "Start Subtitles"
        menu?.item(withTag: Tag.panel)?.title = (panel?.isVisible ?? false) ? "Hide Panel" : "Show Panel"
    }

    // MARK: - Actions

    @objc private func toggle() {
        guard let controller else { return }
        if store.isRunning { controller.stop() } else { Task { await controller.start() } }
        refreshMenuTitle()
    }

    @objc private func togglePanel() {
        guard let panel else { return }
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
        refreshMenuTitle()
    }

    @objc private func selectProvider(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let provider = TranslationProvider(rawValue: raw) else { return }
        settings.provider = provider
        settings.save()
        rebuildController()
    }

    @objc private func toggleAutoDetect() {
        settings.autoDetectLanguage.toggle()
        settings.save()
        rebuildController()
    }

    /// `Settings` is a value copied into the controller at init, so any change
    /// to it means cycling the pipeline. One implementation, because there are
    /// now two settings that need it and a third is easy to get subtly wrong.
    private func rebuildController() {
        let wasRunning = store.isRunning
        if wasRunning { controller?.stop() }
        controller = PipelineController(store: store, settings: settings)
        statusItem?.menu = buildMenu()
        refreshMenuTitle()
        if wasRunning { Task { await controller?.start() } }
    }

    @objc private func clear() { store.clear() }

    @objc private func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(store.transcriptMarkdown, forType: .string)
    }

    /// Apple's Translation framework will not download a language pair from a
    /// programmatic session (`canRequestDownloads` is false there). The only
    /// sanctioned way to offer the download is a SwiftUI `.translationTask`,
    /// so we host one in an offscreen window purely to present the system sheet.
    @objc private func installModel() {
        let host = downloadHost ?? TranslationDownloadHost()
        downloadHost = host
        host.present()
    }

    private func checkTranslationModel() async {
        guard settings.provider == .apple else {
            store.status = "Idle"
            return
        }
        let report = await AppleTranslator.preflight()
        log.info("translation preflight: \(report)")
        if report.contains("notInstalled") {
            store.status = "Japanese model not installed"
            let alert = NSAlert()
            alert.messageText = "Install the Japanese translation model"
            alert.informativeText = """
                Tsuyaku translates on device using Apple's Translation framework, \
                but the Japanese → English model isn't downloaded yet.

                Choose Install to open the system download prompt.
                """
            alert.addButton(withTitle: "Install")
            alert.addButton(withTitle: "Later")
            // An .accessory app is never frontmost on its own, so a modal alert
            // can open behind the meeting window and look like a hang.
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { installModel() }
        } else {
            store.status = "Idle"
        }
    }
}
