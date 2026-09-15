import Foundation
import AppKit

// Entry point. With arguments we run a diagnostic subcommand and exit; with
// none we launch the menu bar app.
if CommandLine.arguments.count > 1 {
    try await CLI.run()
    exit(0)
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
NSApplication.shared.run()
