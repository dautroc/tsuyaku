import AppKit
import Combine
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
///
/// With `PanelStyle.clickThrough` on, the panel ignores the mouse entirely and
/// clicks land on whatever is underneath -- typically the meeting app's own
/// controls, which a subtitle bar tends to sit on top of.
final class FloatingPanel: NSPanel {

    private static let autosaveName = "TsuyakuPanel"
    private static let defaultSize = NSSize(width: 620, height: 260)
    // Below this the header truncates to nothing and a single wrapped row no
    // longer fits.
    private static let minimumSize = NSSize(width: 380, height: 220)

    private var clickThroughObserver: AnyCancellable?

    init(store: SubtitleStore, style: PanelStyle) {
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

        let host = NSHostingView(rootView: SubtitleView(store: store, style: style))
        // `NSHostingView` owns `contentMinSize` as part of `sizingOptions`, and
        // `[]` makes it *clear* the value asynchronously once the view is in a
        // window rather than leave it alone. The floor therefore cannot live in
        // `contentMinSize`; `minSize` is overridden below instead.
        host.sizingOptions = []
        contentView = host

        // `@Published` emits the current value on subscribe, so this also
        // applies the saved setting at launch.
        clickThroughObserver = style.$clickThrough
            .receive(on: DispatchQueue.main)
            .sink { [weak self] on in
                MainActor.assumeIsolated { self?.ignoresMouseEvents = on }
            }

        restoreFrame()
    }

    /// `setFrameAutosaveName` only arranges for the frame to be *saved*. For a
    /// window built in code nothing ever reads it back, which is why the panel
    /// reset to its default size on every launch however the user had left it.
    ///
    /// Only the *size* survives a relaunch. A subtitle bar has one right place
    /// and the user's last drag is rarely it -- a panel nudged aside to read a
    /// slide should not still be sitting there next meeting -- so the origin is
    /// recomputed every launch and the restored one discarded.
    private func restoreFrame() {
        setFrameAutosaveName(Self.autosaveName)
        if !setFrameUsingName(Self.autosaveName) {
            setContentSize(Self.defaultSize)
        }
        positionAtBottomCentre()
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
        guard let screen = Self.activeScreen else { return }
        let visible = screen.visibleFrame
        let size = frame.size
        setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + 120
        ))
    }

    /// `NSScreen.main` is the screen owning the key window, and this app is an
    /// accessory with no key window at launch -- it resolves to the menu bar
    /// display, which on a two-monitor desk is routinely not the one the
    /// meeting is on. The pointer is the better guess at where the user is
    /// looking.
    private static var activeScreen: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    // MARK: - Dragging

    /// Every pixel of the panel moves it, not just the header.
    ///
    /// `isMovableByWindowBackground` is a *request*: AppKit asks whichever view
    /// is under the pointer whether it is willing to give up the drag, and the
    /// history `ScrollView` says no. That left the panel immovable across the
    /// one region that covers most of its surface, which reads as a stuck
    /// window rather than a deliberate handle. Claiming the drag here, before
    /// the content view ever sees it, sidesteps the question.
    ///
    /// The drag has to be claimed on the *first* motion rather than on mouse
    /// down, or a plain click would never reach the "jump to latest" pill.
    private var dragCandidate = false

    /// The outer edge belongs to the resize border, which gets first refusal --
    /// otherwise the panel becomes draggable and never resizable again. Wider
    /// than the ~5pt AppKit tracks so the corner grip stays comfortably inside
    /// it.
    private static let resizeMargin: CGFloat = 8

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            dragCandidate = contentLayoutRect
                .insetBy(dx: Self.resizeMargin, dy: Self.resizeMargin)
                .contains(event.locationInWindow)
        case .leftMouseDragged where dragCandidate:
            // `performDrag` runs its own tracking loop to mouse up, so the
            // event must not also go on to the content view.
            dragCandidate = false
            performDrag(with: event)
            return
        case .leftMouseUp:
            dragCandidate = false
        default:
            break
        }
        super.sendEvent(event)
    }

    override var minSize: NSSize {
        get { Self.minimumSize }
        set { }
    }

    // A borderless-style panel must opt in to receiving key events at all.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
