import Foundation
import FoundationModels
import OSLog

/// Translation through Apple's on-device LLM (`FoundationModels`, macOS 26).
///
/// Distinct from `AppleTranslator`, which drives the `Translation` framework's
/// task-specific NMT model: that one takes a string and returns a string, with
/// nowhere to put a system prompt, a glossary, or prior turns. This is a
/// general instruction-following model, so it gets the same interpreter brief
/// the cloud backends get -- and, unlike NMT, it can use the rolling context
/// that resolves omitted subjects and keigo register.
///
/// The model is resident in the OS and shared, so unlike a local Ollama model
/// it costs the app no additional memory beyond its own KV cache.
struct FoundationModelTranslator: Translator {

    private static let log = Logger(subsystem: "com.loind.tsuyaku", category: "fm-translate")

    /// Translation is a content transformation, which is exactly what the
    /// permissive guardrails exist for. The default set is tuned for
    /// open-ended generation and will refuse source text it would not itself
    /// have written -- a refusal that would surface mid-meeting as a failed
    /// subtitle for a line the speaker actually said.
    private static let model = SystemLanguageModel(useCase: .general,
                                                   guardrails: .permissiveContentTransformations)

    static var availability: SystemLanguageModel.Availability { model.availability }
    static var isAvailable: Bool { model.isAvailable }

    let glossary: Glossary
    let sourceName: String
    let targetName: String

    init(glossary: Glossary = .empty,
         sourceName: String = "Japanese",
         targetName: String = "English") {
        self.glossary = glossary
        self.sourceName = sourceName
        self.targetName = targetName
    }

    /// Loads the model weights so the first real utterance of a meeting does
    /// not pay for it. Cheap to call and safe to ignore the result.
    static func prewarm() {
        guard isAvailable else { return }
        LanguageModelSession(model: model).prewarm()
    }

    /// Shared with every other LLM backend so `--compare` measures the model
    /// and not the prompt.
    private var instructions: String {
        InterpreterPrompt.system(sourceName: sourceName,
                                 targetName: targetName,
                                 glossary: glossary,
                                 finalLineRule: InterpreterPrompt.labelledRule)
    }

    /// The cloud backends carry context as alternating user/assistant messages.
    /// A `Transcript` could reproduce that shape, but a single labelled prompt
    /// is both simpler and steadier on a ~3B model, and it keeps the session
    /// stateless -- the pipeline already decides how many turns to carry, so
    /// the session must not accumulate a meeting's worth of its own.
    private func prompt(_ text: String, context: [(source: String, target: String)]) -> String {
        guard !context.isEmpty else { return "Translate:\n\(text)" }
        let prior = context
            .map { "\($0.source)\n\($0.target)" }
            .joined(separator: "\n\n")
        return "Context:\n\(prior)\n\nTranslate:\n\(text)"
    }

    func translate(_ text: String, context: [(source: String, target: String)]) -> AsyncStream<TranslationDelta> {
        AsyncStream { continuation in
            let task = Task {
                guard Self.isAvailable else {
                    continuation.yield(.failed(Self.describe(Self.availability)))
                    continuation.yield(.done)
                    continuation.finish()
                    return
                }

                // A fresh session per request: `instructions` is re-sent, but the
                // transcript stays exactly the context the pipeline chose.
                let session = LanguageModelSession(model: Self.model,
                                                   instructions: instructions)
                let options = GenerationOptions(sampling: .greedy,
                                                maximumResponseTokens: 512)

                // `ResponseStream` yields cumulative snapshots, not deltas --
                // each element is the whole response so far -- while
                // `TranslationDelta.text` appends. Emitting snapshots directly
                // renders "Understood.Understood, I'll handle it." Diff instead.
                var emitted = ""
                do {
                    for try await snapshot in session.streamResponse(to: prompt(text, context: context),
                                                                     options: options) {
                        let full = snapshot.content
                        guard full.hasPrefix(emitted) else {
                            // String generation is append-only in practice; a
                            // revision would be unrepresentable as a delta.
                            Self.log.warning("non-monotonic snapshot, ignoring")
                            continue
                        }
                        let delta = String(full.dropFirst(emitted.count))
                        guard !delta.isEmpty else { continue }
                        emitted = full
                        continuation.yield(.text(delta))
                    }
                    // Matches the cloud backends: a clean stream with no text is
                    // a real failure, not a blank subtitle.
                    if emitted.isEmpty {
                        continuation.yield(.failed("Apple on-device LLM returned no text"))
                    }
                    continuation.yield(.done)
                } catch is CancellationError {
                    // no-op: caller went away
                } catch {
                    Self.log.error("translate failed: \(error.localizedDescription)")
                    continuation.yield(.failed(error.localizedDescription))
                    continuation.yield(.done)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func describe(_ a: SystemLanguageModel.Availability) -> String {
        switch a {
        case .available: "available"
        case .unavailable(.deviceNotEligible): "device not eligible for Apple Intelligence"
        case .unavailable(.appleIntelligenceNotEnabled): "Apple Intelligence is off in System Settings"
        case .unavailable(.modelNotReady): "model still downloading"
        case .unavailable(let other): "unavailable (\(other))"
        }
    }
}
