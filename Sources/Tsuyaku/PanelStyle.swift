import Foundation
import SwiftUI

/// How the subtitle panel looks and behaves: text size, whether Japanese is
/// shown, and whether clicks pass through it.
///
/// Not part of `Settings`. That is a value copied into `PipelineController`,
/// so changing it means cycling the pipeline, and the views cannot observe it.
/// These are view-only and apply the moment they change, mid-sentence, with
/// capture untouched. Each one is saved to `UserDefaults` as it changes.
///
/// `ObservableObject` rather than `@Observable` for the same reason as
/// `SubtitleStore`: the macro needs a compiler plugin SwiftPM under Command
/// Line Tools has trouble resolving.
@MainActor
final class PanelStyle: ObservableObject {

    enum TextSize: String, CaseIterable, Sendable {
        case small, medium, large, extraLarge

        var title: String {
            switch self {
            case .small:      "Small"
            case .medium:     "Medium"
            case .large:      "Large"
            case .extraLarge: "Extra Large"
            }
        }

        /// Relative to the sizes the panel was designed at.
        var scale: CGFloat {
            switch self {
            case .small:      0.85
            case .medium:     1.0
            case .large:      1.25
            case .extraLarge: 1.5
            }
        }
    }

    private enum Key {
        static let textSize = "panelTextSize"
        static let showJapanese = "panelShowJapanese"
        static let clickThrough = "panelClickThrough"
    }

    private let defaults: UserDefaults

    @Published var textSize: TextSize {
        didSet { defaults.set(textSize.rawValue, forKey: Key.textSize) }
    }
    /// Off, a translated row is its English alone -- half the height, for
    /// someone who only reads the English. The transcripts keep both.
    @Published var showJapanese: Bool {
        didSet { defaults.set(showJapanese, forKey: Key.showJapanese) }
    }
    /// The panel ignores the mouse, so it can sit over the meeting app's
    /// controls without blocking them. It also cannot be moved, resized or
    /// scrolled while this is on.
    @Published var clickThrough: Bool {
        didSet { defaults.set(clickThrough, forKey: Key.clickThrough) }
    }

    /// - Parameter defaults: injectable so the self-test can use a scratch
    ///   suite instead of the user's own preferences.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        textSize = defaults.string(forKey: Key.textSize).flatMap(TextSize.init) ?? .medium
        showJapanese = defaults.object(forKey: Key.showJapanese) as? Bool ?? true
        clickThrough = defaults.bool(forKey: Key.clickThrough)
    }

    /// Whether a row's Japanese line is drawn above its translation.
    ///
    /// A failed row keeps it whatever the setting: there is no English to
    /// read in its place. An English row has no such line -- its source *is*
    /// the subtitle -- and a Qwen row has no source text at all.
    func showsSource(of line: SubtitleLine) -> Bool {
        line.language == .ja && !line.source.isEmpty && (showJapanese || line.failed)
    }
}
