import AppKit
import SwiftUI
import Translation

/// Offscreen SwiftUI host whose only job is to present Apple's language-download
/// sheet.
///
/// A programmatic `TranslationSession(installedSource:...)` reports
/// `canRequestDownloads == false` and throws `.notInstalled` when the model is
/// missing -- it cannot trigger a download itself. The `.translationTask`
/// modifier can, but it must be attached to a live view in a real window, so we
/// keep a tiny one.
@MainActor
final class TranslationDownloadHost {

    private var window: NSWindow?

    func present() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 150),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "Japanese Translation"
        w.center()
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: DownloadView())
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private struct DownloadView: View {
        @State private var configuration: TranslationSession.Configuration?
        @State private var message = "Preparing…"

        /// - Parameter session: consumed, not shared.
        static func prepare(_ session: sending TranslationSession) async -> String {
            do {
                try await session.prepareTranslation()
                return "Installed. You can close this window."
            } catch {
                return "Download failed: \(error.localizedDescription)"
            }
        }

        var body: some View {
            VStack(spacing: 12) {
                Text("Japanese → English")
                    .font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Download model") {
                    configuration = TranslationSession.Configuration(
                        source: .init(identifier: "ja"),
                        target: .init(identifier: "en"))
                }
            }
            .padding(20)
            .frame(width: 380, height: 150)
            .translationTask(configuration) { session in
                // On this path the framework is allowed to present the system
                // download sheet. The session is handed off with `sending` so
                // the non-Sendable class never straddles an isolation boundary.
                message = await Self.prepare(session)
            }
        }
    }
}
