import Foundation
import OSLog

/// A backend that renders captured speech straight into the target language,
/// with no transcription step in between.
///
/// Deliberately not `Translator`: that protocol takes a finalized source
/// *string*, which is exactly what this path does not have. The two cannot be
/// unified without giving one of them a parameter it must ignore.
protocol AudioTranslator: Sendable {
    /// - Parameters:
    ///   - audio: one utterance as a self-contained audio file.
    ///   - context: recent target-language lines, oldest first. Only the target
    ///     side exists here -- there is no source transcript to pair them with.
    func translate(audio: Data, context: [String]) -> AsyncStream<TranslationDelta>
}

/// Speech-to-translated-text through Qwen-Omni on Alibaba Cloud Model Studio.
///
/// Wire format is the OpenAI-compatible Chat Completions endpoint, not the
/// Anthropic one `MessagesAPITranslator` speaks: Model Studio does expose an
/// Anthropic-compatible Messages API, but it carries the text-only Qwen tiers,
/// and the Anthropic message schema has no audio content block to put an
/// utterance in. So this is a second client rather than another factory method.
///
/// Two Qwen-specific deviations from stock OpenAI, both load-bearing:
///
///   - `input_audio.data` must carry a `data:;base64,` prefix. Plain base64,
///     which is what the OpenAI schema specifies and what OpenAI's own SDKs
///     send, is rejected -- see pydantic/pydantic-ai#3530.
///   - `stream` must be true. The omni tier refuses unary requests outright.
///     No hardship: subtitles want the deltas anyway.
///
/// `modalities: ["text"]` is not cosmetic either. Left at the default the model
/// also synthesises speech, which is billed at roughly five times the text
/// output rate for output nobody here will ever play.
struct QwenOmniTranslator: AudioTranslator {

    private static let log = Logger(subsystem: "com.loind.tsuyaku", category: "omni")

    /// Singapore. The Beijing region is `dashscope.aliyuncs.com`; the two have
    /// separate account namespaces, so a key issued for one 401s against the
    /// other. This is the likelier one for a key created outside mainland China.
    static let defaultEndpoint = URL(string: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions")!

    /// Model IDs churn faster here than at the other providers -- `qwen3-omni-flash`
    /// and `qwen3.5-omni-flash` have both been current within a year -- so this
    /// is a default, not a constant. `--omni-model` overrides it, and
    /// `--omni-test` prints the server's error verbatim when the ID is wrong,
    /// which is the fastest way to find the one your account actually serves.
    static let defaultModel = "qwen3-omni-flash"

    let apiKey: String
    let endpoint: URL
    let model: String
    let glossary: Glossary
    let sourceName: String
    let targetName: String

    init(apiKey: String,
         endpoint: URL = defaultEndpoint,
         model: String = defaultModel,
         glossary: Glossary = .empty,
         sourceName: String = "Japanese",
         targetName: String = "English") {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.model = model
        self.glossary = glossary
        self.sourceName = sourceName
        self.targetName = targetName
    }

    /// The shared interpreter brief, with the one rule that has to differ:
    /// the line to translate arrives as audio, not as text.
    private var systemPrompt: String {
        InterpreterPrompt.system(sourceName: sourceName,
                                 targetName: targetName,
                                 glossary: glossary,
                                 finalLineRule: InterpreterPrompt.audioRule)
    }

    func translate(audio: Data, context: [String]) -> AsyncStream<TranslationDelta> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    let produced = try await stream(audio, context: context) {
                        continuation.yield($0)
                    }
                    if !produced {
                        // Reached when the utterance held no speech -- the
                        // segmenter's VAD is energy-based and a door slam can
                        // clear it. Silent rather than an error line: a failure
                        // banner for every cough would make the pane useless.
                        Self.log.debug("omni returned no text for \(audio.count) bytes")
                    }
                    continuation.yield(.done)
                } catch is CancellationError {
                    // no-op: caller went away
                } catch {
                    Self.log.error("translate failed: \(error.localizedDescription)")
                    continuation.yield(.failed(error.localizedDescription,
                                               transient: OmniError.isTransient(error)))
                    continuation.yield(.done)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// - Returns: whether any text was actually emitted.
    private func stream(_ audio: Data,
                        context: [String],
                        emit: @Sendable (TranslationDelta) -> Void) async throws -> Bool {

        var messages: [[String: Any]] = [
            ["role": "system", "content": [["type": "text", "text": systemPrompt]]],
        ]
        // Context is one-sided here, so it cannot be replayed as user/assistant
        // turns the way the text backends do it -- there is no user half. It
        // goes in as prior assistant lines, which is what they were.
        for line in context {
            messages.append(["role": "assistant", "content": [["type": "text", "text": line]]])
        }
        messages.append([
            "role": "user",
            "content": [
                ["type": "input_audio",
                 "input_audio": ["data": "data:;base64," + audio.base64EncodedString(),
                                 "format": "wav"]],
            ],
        ])

        let body: [String: Any] = [
            "model":      model,
            "messages":   messages,
            "stream":     true,
            "modalities": ["text"],
            "temperature": 0.2,
            "max_tokens":  512,
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        // Generous: the whole utterance uploads before the first token can come
        // back, so this covers upload plus inference, not inference alone.
        request.timeoutInterval = 90

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OmniError.transport("no HTTP response")
        }
        guard http.statusCode == 200 else {
            var detail = ""
            for try await line in bytes.lines { detail += line; if detail.count > 500 { break } }
            throw OmniError.http(http.statusCode, detail)
        }

        var parser = SSEParser()
        var producedText = false
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let frame = parser.consume(line),
                  let data = frame.data.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if let err = obj["error"] as? [String: Any] {
                throw OmniError.api(err["message"] as? String ?? "\(err)")
            }
            guard let choices = obj["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any] else { continue }

            // Text arrives as a plain string on the text-only path. The omni
            // tier can also return an `audio` object carrying a `transcript`
            // when speech output slips through; that transcript is the same
            // words, so it is accepted as a fallback rather than dropped.
            if let chunk = delta["content"] as? String, !chunk.isEmpty {
                producedText = true
                emit(.text(chunk))
            } else if let audioOut = delta["audio"] as? [String: Any],
                      let chunk = audioOut["transcript"] as? String, !chunk.isEmpty {
                producedText = true
                emit(.text(chunk))
            }
        }
        return producedText
    }

    enum OmniError: Error, LocalizedError {
        case http(Int, String)
        case api(String)
        case transport(String)
        var errorDescription: String? {
            switch self {
            case .http(let code, let body): "HTTP \(code): \(body.prefix(300))"
            case .api(let m):               "Model Studio error: \(m)"
            case .transport(let m):         "transport: \(m)"
            }
        }

        /// Whether `RetryingAudioTranslator` should send the utterance again.
        static func isTransient(_ error: Error) -> Bool {
            switch error as? OmniError {
            case .http(let code, _)?: TransientFailure.isTransient(status: code)
            case .api?:               false
            case .transport?:         true
            case nil:                 TransientFailure.isTransient(error)
            }
        }
    }
}
