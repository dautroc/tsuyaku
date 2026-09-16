import SwiftUI

/// Two panes, stacked.
///
///   history  scrollable, settled rows only -- the user owns this scroll
///   live     what is being heard and translated right now -- pinned, no scroll
///
/// Keeping them apart is what makes reading back workable: the live text can
/// update ten times a second without ever moving the history pane, and
/// scrolling up in the history pane never hides the current speaker.
struct SubtitleView: View {
    @ObservedObject var store: SubtitleStore

    /// Follow-the-speaker mode for the history pane. True while it is parked
    /// at the bottom; scrolling up to read back turns it off so newly settled
    /// rows stop yanking the viewport away.
    @State private var pinnedToBottom = true
    /// `store.settledCount` at the moment the user scrolled away, so the
    /// "jump to latest" pill can say how much they have missed. Settled rows
    /// rather than `history.count`, which stops moving once the cap trims.
    @State private var settledWhenUnpinned = 0

    /// Whether the scroll view is moving under the user's hand rather than
    /// under AppKit's. This, not the shape of the offset, is what separates
    /// reading back from the pane settling itself.
    @State private var userIsScrolling = false
    /// Nothing in flight: no drag, no momentum, no programmatic animation. The
    /// only moment it is safe to re-assert a pin that has drifted.
    @State private var scrollIsIdle = true

    /// Scrolling to the last *row* stops at that row's bottom edge, short of
    /// the stack's own bottom padding. A 1pt marker outside that padding is the
    /// true end of the content, so the pin does not depend on the slack
    /// happening to exceed it.
    private static let tailID = "history.tail"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            // `livePane` is intrinsically sized and the history ScrollView is
            // fully flexible, and a VStack satisfies the inflexible child
            // first -- so without a floor, a short panel collapses history to
            // nothing and the live pane eats the whole window.
            historyPane.frame(minHeight: 72)
            if store.hasLiveContent {
                Divider().opacity(0.45)
                livePane
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: store.hasLiveContent)
        .background(.black.opacity(0.82))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .bottomTrailing) { resizeGrip }
    }

    /// Purely a sign that says "grab here". The window's own resize tracking
    /// owns the outer few points of the frame; a grip that accepted clicks
    /// would compete with it for the same drag and win nothing.
    private var resizeGrip: some View {
        Path { p in
            for inset in stride(from: CGFloat(0), through: 6, by: 3) {
                p.move(to: CGPoint(x: 9, y: inset + 1))
                p.addLine(to: CGPoint(x: inset + 1, y: 9))
            }
        }
        .stroke(.white.opacity(0.28), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        .frame(width: 10, height: 10)
        .padding(4)
        .allowsHitTesting(false)
    }

    /// A notice outranks both: a device change or a dead capture is the one
    /// thing in this header worth interrupting for.
    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(store.notice != nil ? .orange : (store.isRunning ? .red : .secondary))
                .frame(width: 8, height: 8)
            Text(store.headerLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(store.notice != nil ? 1 : 0.85))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .animation(.easeOut(duration: 0.2), value: store.notice)
    }

    // MARK: - History

    private var historyPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(store.history) { line in
                            VStack(alignment: .leading, spacing: 3) {
                                if line.language == .en {
                                    // One line, at translation weight: this text
                                    // is the subtitle, not a gloss above one.
                                    Text(line.source)
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(line.failed ? .orange : .white)
                                        .textSelection(.enabled)
                                } else {
                                    Text(line.source)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.white.opacity(0.55))
                                    Text(line.target.isEmpty ? " " : line.target)
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(line.failed ? .orange : .white)
                                        .textSelection(.enabled)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)

                    Color.clear.frame(height: 1).id(Self.tailID)
                }
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            // Three things move this pane and only one of them is the user.
            //
            //   the container changed   the live pane appeared or vanished, or
            //       the window was resized. The bottom moved out from under us
            //       while the content and the offset both held still, so the old
            //       two-branch rule saw nothing at all: follow mode stayed "on"
            //       with the newest row below the fold and the pill hidden, and
            //       only a hand scroll could get back. Re-find the bottom.
            //   we are at the bottom    however we arrived -- scrolled down, hit
            //       the pill, or bounced off the end of an overscroll -- re-arm.
            //       Tested before the offset rule on purpose: a rubber-band
            //       bounce *is* a decreasing offset.
            //   the offset fell         a deliberate scroll back.
            //
            // Content-size changes need no branch: every one of them comes out
            // of `graduate()`, and the `settledCount` watcher below owns those.
            // Only the user's own hand unpins. Inferring that from the geometry
            // alone does not work: when the live pane slides away the container
            // grows in one event and the scroll view settles the offset in the
            // *next* one, so a falling offset with both sizes apparently steady
            // is far more often AppKit tidying up than anyone reading back.
            .onScrollPhaseChange { _, phase in
                userIsScrolling = phase == .tracking
                    || phase == .interacting
                    || phase == .decelerating
                scrollIsIdle = phase == .idle
            }
            .onScrollGeometryChange(for: HistoryGeometry.self) { geo in
                HistoryGeometry(
                    offset: geo.contentOffset.y,
                    containerHeight: geo.containerSize.height,
                    contentHeight: geo.contentSize.height
                        + geo.contentInsets.top + geo.contentInsets.bottom
                )
            } action: { old, new in
                switch HistoryScrollRule.action(from: old, to: new,
                                                pinned: pinnedToBottom,
                                                userIsScrolling: userIsScrolling,
                                                scrollIsIdle: scrollIsIdle) {
                case .none:
                    break
                case .pin:
                    pinnedToBottom = true
                case .unpin:
                    settledWhenUnpinned = store.settledCount
                    pinnedToBottom = false
                case .snapToBottom:
                    snapToBottom(proxy)
                }
            }
            // Not `history.count`: once the cap engages, append-and-trim leaves
            // it at 500 and this would never fire again -- which is exactly the
            // point in a long meeting where following the speaker matters most.
            .onChange(of: store.settledCount) { _, new in
                if new == 0 {                       // Clear
                    pinnedToBottom = true
                    settledWhenUnpinned = 0
                }
                scroll(proxy)
            }
            .overlay(alignment: .bottom) { jumpToLatest(proxy) }
            .overlay { if store.history.isEmpty { placeholder } }
        }
    }

    private var placeholder: some View {
        Text(store.isRunning ? "Listening…" : "Start subtitles from the menu bar")
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.3))
    }

    @ViewBuilder
    private func jumpToLatest(_ proxy: ScrollViewProxy) -> some View {
        if !pinnedToBottom {
            Button {
                pinnedToBottom = true
                scroll(proxy)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 9, weight: .bold))
                    Text(missedLabel)
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.blue.opacity(0.9), in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 8)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private var missedLabel: String {
        let missed = max(0, store.settledCount - settledWhenUnpinned)
        return missed == 0 ? "Latest" : "\(missed) new"
    }

    /// A new row arriving is an event: something the user should see move.
    private func scroll(_ proxy: ScrollViewProxy) {
        guard pinnedToBottom, !store.history.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(Self.tailID, anchor: .bottom)
        }
    }

    /// A correction, not an event: the pane changed shape and we are putting the
    /// viewport back where it already was. Animating it reads as the list moving
    /// on its own -- and without an explicit opt-out the live pane's own 0.18s
    /// transition leaks its animation into this scroll.
    private func snapToBottom(_ proxy: ScrollViewProxy) {
        guard !store.history.isEmpty else { return }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { proxy.scrollTo(Self.tailID, anchor: .bottom) }
    }

    // MARK: - Live

    /// Bounded by line limits rather than a height cap: clipping would hide the
    /// newest text, which is the whole point of this pane. Anything long enough
    /// to truncate here lands in full in the history pane a second later.
    private var livePane: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(store.live) { line in
                VStack(alignment: .leading, spacing: 3) {
                    if line.language == .en {
                        // Never reaches the "translating…" placeholder: there
                        // is no translation step to wait for.
                        Text(line.source)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(line.failed ? .orange : .white)
                            .lineLimit(4)
                    } else {
                        Text(line.source)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(2)
                        if line.target.isEmpty && !line.failed {
                            Text("translating…")
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.3))
                        } else {
                            Text(line.target)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(line.failed ? .orange : .white)
                                .lineLimit(4)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !store.hearing.isEmpty {
                Text(store.hearing)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.4))
                    .italic()
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06))
    }
}

/// The numbers the sticky-scroll rule needs, bundled so
/// `onScrollGeometryChange` can hand us both the old and new values.
///
/// Named clear of SwiftUI's own public `ScrollPosition`, which this used to
/// shadow: file-private scope won that collision, but only by luck.
struct HistoryGeometry: Equatable {
    var offset: CGFloat
    var containerHeight: CGFloat
    var contentHeight: CGFloat

    var distanceFromBottom: CGFloat { contentHeight - containerHeight - offset }
}

enum HistoryScrollAction: Equatable {
    case none
    /// Park at the newest row and follow the speaker again.
    case pin
    /// The user is reading back; stop moving under them.
    case unpin
    /// Still following, but the bottom moved. Re-find it, without animating.
    case snapToBottom
}

/// Where the history pane decides whether it is still following the speaker.
///
/// Split out of the view because it is the part that was wrong, is easy to get
/// wrong again, and cannot be exercised by looking at a running panel: the
/// sequences that break it are a handful of geometry callbacks a fifth of a
/// second apart. `Tsuyaku --store-selftest` replays them.
enum HistoryScrollRule {

    /// How close to the bottom counts as "at the bottom". Slack is not merely
    /// politeness towards a stray trackpad nudge: a fling past the end
    /// rubber-bands the offset *back down*, which is shaped exactly like a
    /// deliberate scroll up. Without the slack the pane would unpin itself the
    /// instant the user reached the newest row.
    static let bottomSlack: CGFloat = 24

    static func action(from old: HistoryGeometry,
                       to new: HistoryGeometry,
                       pinned: Bool,
                       userIsScrolling: Bool,
                       scrollIsIdle: Bool) -> HistoryScrollAction {

        // The pane changed shape -- the live pane appeared or vanished, or the
        // window was resized. The bottom moved out from under the viewport
        // while nobody touched it. Note this does *not* fall through to the
        // "at the bottom" test: a container that grows while the user is
        // reading back must not quietly re-pin them.
        if new.containerHeight != old.containerHeight {
            return pinned ? .snapToBottom : .none
        }

        // At the bottom, however we got here -- scrolled down, hit the pill, or
        // bounced off the end of an overscroll.
        if new.distanceFromBottom <= bottomSlack { return .pin }

        // A deliberate scroll back. Gated on the user actually driving: the
        // same falling offset arrives when the scroll view settles itself a
        // frame after the container resized, and that is not someone reading.
        if userIsScrolling && new.offset < old.offset - 0.5 {
            return pinned ? .unpin : .none
        }

        // Nominally following, but adrift -- the residue of a container change
        // that the scroll view settled a frame late. Only with nothing in
        // flight: mid-animation this would cut short the ease that carries a
        // newly settled row into view. Content growth is not our business here
        // either; `settledCount` owns that, and animates it.
        if pinned && scrollIsIdle && new.contentHeight == old.contentHeight {
            return .snapToBottom
        }

        return .none
    }
}
