import SwiftUI

/// Captions of the user's own speech, for colleagues reading the shared
/// screen.
///
/// Built for an audience, not for the user: no history pane and nothing to
/// scroll, since nobody watching a screen share can scroll it. Just the last
/// two sentences, the Japanese large and the English small above it -- many
/// colleagues read English more easily than they follow it spoken, so the
/// original is worth showing too.
struct CaptionView: View {
    @ObservedObject var store: SubtitleStore

    private var rows: [SubtitleLine] {
        CaptionRows.visible(history: store.history, live: store.live, limit: 2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Spacer(minLength: 0)
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.source)
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(2)
                    // A failed row keeps its English and nothing else: an
                    // error message means nothing to the people reading this.
                    if !row.failed {
                        Text(row.target.isEmpty ? "…" : row.target)
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(.white.opacity(row.target.isEmpty ? 0.4 : 1))
                            .lineLimit(3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
            }
            if !store.hearing.isEmpty {
                Text(store.hearing)
                    .font(.system(size: 14))
                    .italic()
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        // The newest line sits at the bottom edge, and when two long ones do
        // not fit, it is the older one that is cut off.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .clipped()
        .overlay(alignment: .topTrailing) {
            Text("EN → JA")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
                .padding(8)
        }
        .animation(.easeOut(duration: 0.2), value: rows.map(\.id))
        .background(.black.opacity(0.82))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// Which rows the caption panel shows. Split out so the rule is testable
/// without a window.
enum CaptionRows {

    /// The newest `limit` rows, oldest first. History comes before live, so a
    /// sentence still being translated is always the last one shown.
    static func visible(history: [SubtitleLine], live: [SubtitleLine], limit: Int) -> [SubtitleLine] {
        // Only the tail of history can be shown, and it holds up to 500 rows.
        Array((history.suffix(limit) + live).suffix(limit))
    }
}
