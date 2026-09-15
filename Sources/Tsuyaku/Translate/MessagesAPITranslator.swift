import Foundation
import OSLog

/// Streaming translation over the Anthropic Messages API wire format.
///
/// Raw HTTPS rather than an SDK: neither provider ships an official Swift SDK.
/// Two backends speak this exact protocol, so one client covers both:
///
///   - Anthropic proper, `claude-haiku-4-5`.
///   - DeepSeek, whose `/anthropic` endpoint accepts the same request shape,
///     the same `x-api-key` header and the same SSE events, mapping
///     `claude-haiku-*` / `claude-sonnet-*` onto `deepseek-flash` and
///     `claude-opus-*` onto `deepseek-v4-pro`.
///
/// Thinking is deliberately never requested: it is pure latency for translation.
struct MessagesAPITranslator: Translator {

    private static let log = Logger(subsystem: "com.loind.tsuyaku", category: "translate")

    let apiKey: String
    let endpoint: URL
    let model: String
    let providerName: String
    /// Send `thinking: {"type":"disabled"}`. Required for DeepSeek, whose
    /// reasoning tier thinks by default and will burn the entire `max_tokens`
    /// budget deliberating over a one-line translation before emitting any text.
    /// Not sent to Anthropic, where Haiku simply doesn't think unless asked.
    let disableThinking: Bool
    let glossary: Glossary
    let sourceName: String
    let targetName: String

    init(apiKey: String,
         endpoint: URL,
         model: String,
         providerName: String,
         disableThinking: Bool = false,
         glossary: Glossary = .empty,
         sourceName: String = "Japanese",
         targetName: String = "English") {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.model = model
        self.providerName = providerName
        self.disableThinking = disableThinking
        self.glossary = glossary
        self.sourceName = sourceName
        self.targetName = targetName
    }

    static func anthropic(apiKey: String, glossary: Glossary = .empty) -> MessagesAPITranslator {
        MessagesAPITranslator(apiKey: apiKey,
                              endpoint: URL(string: "https://api.anthropic.com/v1/messages")!,
                              model: "claude-haiku-4-5",
                              providerName: "Claude (claude-haiku-4-5)",
                              glossary: glossary)
    }

    /// DeepSeek routes `claude-haiku-*` to `deepseek-flash`, its fast tier.
    static func deepSeek(apiKey: String, glossary: Glossary = .empty) -> MessagesAPITranslator {
        MessagesAPITranslator(apiKey: apiKey,
                              endpoint: URL(string: "https://api.deepseek.com/anthropic/v1/messages")!,
                              model: "claude-haiku-4-5",
                              providerName: "DeepSeek (deepseek-flash)",
                              disableThinking: true,
                              glossary: glossary)
    }

    private var systemPrompt: String {
        InterpreterPrompt.system(sourceName: sourceName,
                                 targetName: targetName,
                                 glossary: glossary,
                                 finalLineRule: InterpreterPrompt.finalTurnRule)
    }

    func translate(_ text: String, context: [(source: String, target: String)]) -> AsyncStream<TranslationDelta> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    let produced = try await stream(text, context: context) {
                        continuation.yield($0)
                    }
                    // A clean stream that produced no text is a real failure --
                    // typically the model spent its whole budget on reasoning.
                    // Say so rather than rendering a blank subtitle.
                    if !produced {
                        continuation.yield(.failed("\(providerName) returned no text"))
                    }
                    continuation.yield(.done)
                } catch is CancellationError {
                    // no-op: caller went away
                } catch {
                    Self.log.error("translate failed: \(error.localizedDescription)")
                    continuation.yield(.failed(error.localizedDescription))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// - Returns: whether any text was actually emitted.
    @discardableResult
    private func stream(_ text: String,
                        context: [(source: String, target: String)],
                        emit: @Sendable (TranslationDelta) -> Void) async throws -> Bool {

        var messages: [[String: Any]] = []
        for turn in context {
            messages.append(["role": "user",      "content": turn.source])
            messages.append(["role": "assistant", "content": turn.target])
        }
        messages.append(["role": "user", "content": text])

        var body: [String: Any] = [
            "model":      model,
            "max_tokens": 1024,
            "stream":     true,
            "system":     systemPrompt,
            "messages":   messages,
        ]
        if disableThinking { body["thinking"] = ["type": "disabled"] }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey,             forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01",       forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranslateError.transport("no HTTP response")
        }
        guard http.statusCode == 200 else {
            var detail = ""
            for try await line in bytes.lines { detail += line; if detail.count > 500 { break } }
            throw TranslateError.http(http.statusCode, detail)
        }

        var parser = SSEParser()
        var producedText = false
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let frame = parser.consume(line) else { continue }
            guard let data = frame.data.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            switch obj["type"] as? String {
            case "content_block_delta":
                if let delta = obj["delta"] as? [String: Any],
                   delta["type"] as? String == "text_delta",
                   let t = delta["text"] as? String, !t.isEmpty {
                    producedText = true
                    emit(.text(t))
                }
            case "error":
                let msg = (obj["error"] as? [String: Any])?["message"] as? String ?? "unknown"
                throw TranslateError.api(msg)
            default:
                continue
            }
        }
        return producedText
    }

    enum TranslateError: Error, LocalizedError {
        case http(Int, String)
        case api(String)
        case transport(String)
        var errorDescription: String? {
            switch self {
            case .http(let code, let body):
                // 429 and 5xx are retryable; the caller keeps the source line visible.
                "HTTP \(code): \(body.prefix(200))"
            case .api(let m):       "API error: \(m)"
            case .transport(let m): "transport: \(m)"
            }
        }
    }
}
