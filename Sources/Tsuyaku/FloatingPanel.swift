import AppKit
import SwiftUI

/// The always-on-top subtitle window.
///
/// `.nonactivatingPanel` keeps clicks from stealing focus from the meeting app.
/// `.fullScreenAuxiliary` is the flag that actually matters: without it the
/// panel disappears the moment someone full-screens Zoom, which is most of the
/// time.
///
/// `.titled` is load-bearing despite the titlebar being invisible: a borderless
/// window gets no edge-drag resize from `.resizable`, so dropping it would cost
/// the panel its resize handles. `.fullSizeContentView` reclaims the titlebar's
/// height for the content instead, and the standard window buttons are hidden
/// because they would float over the header text.
final class FloatingPanel: NSPanel {

    private static let autosaveName = "TsuyakuPanel"
    private static let defaultSize = NSSize(width: 620, height: 260)

    init(store: SubtitleStore) {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.nonactivatingPanel, .titled, .closable, .resizable,
                        .utilityWindow, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        title = "Tsuyaku"
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // The delegate holds the only reference; ⌘W must hide the panel, not
        // deallocate it out from under a running pipeline.
        isReleasedWhenClosed = false

        for button: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }

        // Below this the header truncates to nothing and a single wrapped row no
        // longer fits. The floor has to live on the window: the hosting view
        // will happily let the frame shrink past its content and just clip it.
        contentMinSize = NSSize(width: 380, height: 220)

        let host = NSHostingView(rootView: SubtitleView(store: store))
        // Publish no Auto Layout constraints from the SwiftUI ideal size, so
        // `contentMinSize` is the only authority on how small this can get.
        host.sizingOptions = []
        contentView = host

        restoreFrame()
    }

    /// `setFrameAutosaveName` only arranges for the frame to be *saved*. For a
    /// window built in code nothing ever reads it back, which is why the panel
    /// reset to its default size, bottom centre, on every launch however the
    /// user had left it.
    ///
    /// Order matters twice over: the restore has to follow the autosave
    /// registration, and the default placement has to follow the restore
    /// *failing*. Doing the placement unconditionally, as this used to, would
    /// overwrite a perfectly good restored frame.
    private func restoreFrame() {
        setFrameAutosaveName(Self.autosaveName)
        if !setFrameUsingName(Self.autosaveName) || !isUsablyOnScreen {
            setContentSize(Self.defaultSize)
            positionAtBottomCentre()
        }
    }

    /// A frame saved on an external display that has since been unplugged would
    /// otherwise put the panel somewhere the user cannot reach. AppKit's own
    /// `constrainFrameRect(_:to:)` only promises the titlebar stays grabbable,
    /// and this panel's titlebar is invisible.
    private var isUsablyOnScreen: Bool {
        NSScreen.screens.contains { screen in
            let overlap = screen.visibleFrame.intersection(frame)
            return overlap.width >= 160 && overlap.height >= 80
        }
    }

    /// Displays come and go mid-meeting; the panel should not go with them.
    func recoverIfOffScreen() {
        guard !isUsablyOnScreen else { return }
        positionAtBottomCentre()
    }

    /// A subtitle bar belongs where subtitles go: bottom centre, clear of the
    /// meeting app's own controls.
    private func positionAtBottomCentre() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = frame.size
        setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + 120
        ))
    }

    // A borderless-style panel must opt in to receiving key events at all.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
