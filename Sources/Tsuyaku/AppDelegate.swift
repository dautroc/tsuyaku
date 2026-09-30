import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let log = Logger(subsystem: "com.loind.tsuyaku", category: "app")
    private let store = SubtitleStore()
    private let style = PanelStyle()
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
    private var runningObserver: AnyCancellable?
    private let transcripts = TranscriptWriter(directory: AppPaths.transcriptsDirectory)
    /// Refilled every time it opens (`menuNeedsUpdate`): which apps are playing
    /// audio is only true for the moment someone looks.
    private var captureMenu: NSMenu?
    /// ⌃⌥⌘S from any app. Nil if another app already holds the combination;
    /// the menu then shows the plain ⌘S it always had.
    private var hotKey: GlobalHotKey?

    /// The menu bar item goes up before anything reads the keychain.
    ///
    /// `Settings.load()` used to be a property initializer on this class, so it
    /// ran while `main.swift` was still constructing the delegate -- before
    /// `NSApplication.run()`. It reaches the keychain twice over (choosing a
    /// first-run provider, then checking the chosen one still has its key), and
    /// a `SecItemCopyMatching` can take *seconds* the first time a rebuilt
    /// binary asks for an item the user granted to an earlier signature. For
    /// that entire window there was a live process and nothing to show for it,
    /// which reads exactly like a failed launch. The status item and its
    /// "Starting…" menu are that feedback now.
    ///
    /// The panel is built here but stays hidden: it belongs to a running
    /// session, so "Start Subtitles" shows it and "Stop Subtitles" puts it away.
    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = FloatingPanel(store: store, style: style)
        store.onSettled = { [weak self] rows in self?.saveSettled(rows) }
        // Before settings load `toggle()` does nothing, so this is safe to
        // arm this early.
        hotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_S),
                              modifiers: [.control, .option, .command]) { [weak self] in
            self?.toggle()
        }
        setUpStatusItem()
        // `start()` flips `isRunning` after its awaits, and the pipeline can
        // stop itself on failure, so the menu title follows the store rather
        // than the click that asked for the change.
        runningObserver = store.$isRunning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshMenuTitle() }
            }
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
        endTranscript()
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
    /// means the keychain read we are keeping off this thread. Quit needs
    /// nothing, so the app is never unquittable.
    private func startingMenu() -> NSMenu {
        let menu = NSMenu()
        let starting = menu.addItem(withTitle: "Starting…", action: nil, keyEquivalent: "")
        starting.isEnabled = false
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Tsuyaku", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    /// Menu items are addressed by tag rather than by index: the run item
    /// retitles itself, and index arithmetic breaks the moment the menu gains
    /// a row.
    private enum Tag {
        static let run = 1
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        // The panel has no close button -- the standard window buttons would
        // float over the header -- so this item both runs the pipeline and
        // shows or hides the panel with it, and it has to say which way it goes.
        let run = menu.addItem(withTitle: "Start Subtitles", action: #selector(toggle), keyEquivalent: "s")
        run.target = self
        run.tag = Tag.run
        // Shown against the item so the shortcut can be found at all. It also
        // works here, while the menu is open.
        if hotKey != nil { run.keyEquivalentModifierMask = [.control, .option, .command] }
        menu.addItem(.separator())

        // Panel appearance. None of these touch the pipeline: they apply
        // mid-sentence, with capture running.
        let textSize = NSMenuItem(title: "Text Size", action: nil, keyEquivalent: "")
        let sizes = NSMenu()
        for size in PanelStyle.TextSize.allCases {
            let item = sizes.addItem(withTitle: size.title, action: #selector(selectTextSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = size.rawValue
            item.state = size == style.textSize ? .on : .off
        }
        textSize.submenu = sizes
        menu.addItem(textSize)
        let japanese = menu.addItem(withTitle: "Show Japanese",
                                    action: #selector(toggleShowJapanese(_:)), keyEquivalent: "")
        japanese.target = self
        japanese.state = style.showJapanese ? .on : .off
        japanese.toolTip = "Show the Japanese above each translation. Saved transcripts always keep it."
        let clickThrough = menu.addItem(withTitle: "Click-Through",
                                        action: #selector(toggleClickThrough(_:)), keyEquivalent: "")
        clickThrough.target = self
        clickThrough.state = style.clickThrough ? .on : .off
        clickThrough.toolTip = "Clicks go to the window underneath. Turn off to move, resize or scroll the panel."
        menu.addItem(.separator())
        menu.addItem(withTitle: "Copy Transcript", action: #selector(copyTranscript), keyEquivalent: "c").target = self
        menu.addItem(withTitle: "Clear", action: #selector(clear), keyEquivalent: "").target = self
        let save = menu.addItem(withTitle: "Save Transcripts",
                                action: #selector(toggleSaveTranscripts(_:)), keyEquivalent: "")
        save.target = self
        save.state = settings.saveTranscripts ? .on : .off
        save.toolTip = "Write each session's subtitles to a Markdown file as they settle."
        menu.addItem(withTitle: "Open Transcripts Folder", action: #selector(openTranscriptsFolder), keyEquivalent: "").target = self
        menu.addItem(.separator())

        let detect = menu.addItem(withTitle: "Detect English Automatically",
                                  action: #selector(toggleAutoDetect), keyEquivalent: "")
        detect.target = self
        detect.state = settings.autoDetectLanguage ? .on : .off
        detect.toolTip = "Run a second English recognizer and show English turns verbatim, untranslated."

        let capture = NSMenuItem(title: "Capture From", action: nil, keyEquivalent: "")
        let captureMenu = NSMenu()
        captureMenu.delegate = self
        capture.submenu = captureMenu
        menu.addItem(capture)
        self.captureMenu = captureMenu
        // Filled now as well as on open: AppKit is not consistent about
        // offering to open a submenu that has no items yet.
        menuNeedsUpdate(captureMenu)
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

        let glossary = menu.addItem(withTitle: "Edit Glossary…", action: #selector(editGlossary), keyEquivalent: "")
        glossary.target = self
        glossary.toolTip = "Names and terms to always translate the same way. Changes apply at the next Start."
        menu.addItem(withTitle: "Install Japanese Translation…", action: #selector(installModel), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Tsuyaku", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private func refreshMenuTitle() {
        let menu = statusItem?.menu
        menu?.item(withTag: Tag.run)?.title = store.isRunning ? "Stop Subtitles" : "Start Subtitles"
    }

    // MARK: - Actions

    /// Only this user-facing toggle hides the panel. A failed `start()` stops
    /// the pipeline itself, so the panel stays up with the "Failed: …" status
    /// visible, and `rebuildController()` cycles the pipeline without it.
    @objc private func toggle() {
        guard let controller else { return }
        if store.isRunning {
            controller.stop()
            endTranscript()
            panel?.orderOut(nil)
        } else {
            transcripts.begin()
            // Shown before the awaits so "Starting…" is on screen at once.
            panel?.orderFrontRegardless()
            Task { await controller.start() }
        }
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

    /// "All Apps" carries no bundle ID. Mid-meeting, this recaptures at once:
    /// `rebuildController` cycles a running pipeline onto the new tap.
    @objc private func selectCaptureSource(_ sender: NSMenuItem) {
        let ids = (sender.representedObject as? String).map { [$0] } ?? []
        guard ids != settings.targetBundleIDs else { return }
        settings.targetBundleIDs = ids
        settings.save()
        rebuildController()
    }

    @objc private func selectTextSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let size = PanelStyle.TextSize(rawValue: raw) else { return }
        style.textSize = size
        for item in sender.menu?.items ?? [] {
            item.state = item.representedObject as? String == raw ? .on : .off
        }
    }

    @objc private func toggleShowJapanese(_ sender: NSMenuItem) {
        style.showJapanese.toggle()
        sender.state = style.showJapanese ? .on : .off
    }

    @objc private func toggleClickThrough(_ sender: NSMenuItem) {
        style.clickThrough.toggle()
        sender.state = style.clickThrough ? .on : .off
    }

    /// Takes effect from the next row; the pipeline itself never reads it.
    @objc private func toggleSaveTranscripts(_ sender: NSMenuItem) {
        settings.saveTranscripts.toggle()
        settings.save()
        sender.state = settings.saveTranscripts ? .on : .off
    }

    @objc private func openTranscriptsFolder() {
        let dir = AppPaths.transcriptsDirectory
        do {
            try AppPaths.ensureDirectory(dir)
        } catch {
            log.error("could not create transcripts folder: \(error.localizedDescription, privacy: .public)")
            return
        }
        NSWorkspace.shared.open(dir)
    }

    /// Creates the file with an explanatory starter on first use, then hands it
    /// to the default text editor. There is nothing to reload: the pipeline
    /// reads the file at every Start.
    @objc private func editGlossary() {
        let url = AppPaths.glossaryFile
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try AppPaths.ensureDirectory(AppPaths.directory)
                try Glossary.starterText.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                log.error("could not create glossary: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        NSWorkspace.shared.open(url)
        if store.isRunning {
            store.flashNotice("Glossary changes apply the next time subtitles start")
        }
    }

    /// `Settings` is a value copied into the controller at init, so any change
    /// to it means cycling the pipeline. One implementation, because three
    /// settings need it now and a fourth is easy to get subtly wrong.
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

    // MARK: - Saved transcript

    private func saveSettled(_ rows: [SubtitleLine]) {
        guard settings.saveTranscripts else { return }
        transcripts.append(rows)
    }

    /// Ends the session's file with whatever the live pane still holds: a
    /// translation cut off by Stop, or a provisional row the gate never got to
    /// settle. Those rows never graduate, so without this the last thing said
    /// in a meeting would be missing from its transcript. After
    /// `controller.stop()`, which settles an open Gemini row first.
    private func endTranscript() {
        if settings.saveTranscripts {
            transcripts.append(store.live.filter { !$0.source.isEmpty || !$0.target.isEmpty })
        }
        transcripts.finish()
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

// MARK: - Capture From

extension AppDelegate: NSMenuDelegate {

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === captureMenu else { return }
        menu.removeAllItems()
        let selected = settings.targetBundleIDs.first

        let all = menu.addItem(withTitle: "All Apps", action: #selector(selectCaptureSource(_:)), keyEquivalent: "")
        all.target = self
        all.state = selected == nil ? .on : .off
        all.toolTip = "Everything this Mac plays, except Tsuyaku itself."
        menu.addItem(.separator())

        // The HAL lists a process once per audio client, and lists us too.
        var seen: Set<String> = []
        var ids = ((try? CA.runningOutputBundleIDs()) ?? []).filter {
            $0 != Bundle.main.bundleIdentifier && seen.insert($0).inserted
        }
        // The chosen app stays listed while it is quiet or not running: the
        // tap reattaches when it relaunches, and the user needs to see what
        // capture is limited to.
        if let selected, !seen.contains(selected) { ids.append(selected) }

        if ids.isEmpty {
            menu.addItem(withTitle: "No apps are playing audio", action: nil, keyEquivalent: "").isEnabled = false
            return
        }
        let apps = ids.map { (id: $0, app: Self.application($0)) }
            .sorted { $0.app.name.localizedStandardCompare($1.app.name) == .orderedAscending }
        for (id, app) in apps {
            let item = menu.addItem(withTitle: app.name, action: #selector(selectCaptureSource(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = id == selected ? .on : .off
            item.image = app.icon
            item.toolTip = id
        }
    }

    /// Display name and icon for a bundle ID, or the ID itself when Launch
    /// Services does not know it -- helper processes, mostly.
    private static func application(_ bundleID: String) -> (name: String, icon: NSImage?) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return (bundleID, nil)
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        return (FileManager.default.displayName(atPath: url.path), icon)
    }
}
