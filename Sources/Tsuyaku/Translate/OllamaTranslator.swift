import Foundation
import OSLog

/// Streaming translation through a local Ollama server.
///
/// Wire format is Ollama's native `/api/chat` rather than its OpenAI-compatible
/// endpoint, because the three knobs that matter for live subtitles --
/// `keep_alive`, `think` and `options` -- only exist on the native one.
///
/// Unlike the Anthropic protocol this is NDJSON, not SSE: one complete JSON
/// object per line, no `data:` prefix, so `SSEParser` does not apply. And
/// unlike `FoundationModels`, `message.content` is a genuine delta rather than
/// a cumulative snapshot, so it is appended, not diffed.
struct OllamaTranslator: Translator {

    private static let log = Logger(subsystem: "com.loind.tsuyaku", category: "ollama")

    /// 127.0.0.1, not `localhost`: the latter can cost a DNS round trip and an
    /// IPv6-first attempt before falling back, which is pure added TTFB on a
    /// server that is on this machine.
    static let defaultHost = URL(string: "http://127.0.0.1:11434")!
    static let defaultModel = "qwen3:4b-instruct"

    let host: URL
    let model: String
    let glossary: Glossary
    let direction: TranslationDirection

    init(host: URL = defaultHost,
         model: String = defaultModel,
         glossary: Glossary = .empty,
         direction: TranslationDirection = .japaneseToEnglish) {
        self.host = host
        self.model = model
        self.glossary = glossary
        self.direction = direction
    }

    private var systemPrompt: String {
        InterpreterPrompt.system(direction: direction,
                                 glossary: glossary,
                                 finalLineRule: InterpreterPrompt.finalTurnRule)
    }

    // MARK: - Availability

    /// Whether the server is up and the model is pulled.
    ///
    /// Blocking on purpose, to match `hasKey`: every caller already runs this
    /// off the main thread and caches it, and making it async would push that
    /// requirement into `TranslationProvider.isUsable` and every one of its
    /// call sites. The timeout is short because "Ollama is not running" has to
    /// be a fast answer, not a hang at launch.
    /// - Returns: nil when ready, else why not.
    static func probe(host: URL = defaultHost, model: String = defaultModel) -> String? {
        var request = URLRequest(url: host.appendingPathComponent("api/tags"))
        request.timeoutInterval = 1.5

        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var payload: Data?
        nonisolated(unsafe) var failure: Error?
        let task = URLSession.shared.dataTask(with: request) { data, _, error in
            payload = data; failure = error; semaphore.signal()
        }
        task.resume()
        guard semaphore.wait(timeout: .now() + 2) == .success else {
            // Cancel, or the completion handler writes to these locals after
            // this function has already returned and read them.
            task.cancel()
            return "Ollama did not respond at \(host.absoluteString)"
        }
        if let failure {
            return "Ollama not reachable at \(host.absoluteString) (\(failure.localizedDescription))"
        }
        guard let payload,
              let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let models = obj["models"] as? [[String: Any]] else {
            return "Ollama returned an unreadable model list"
        }
        let names = models.compactMap { $0["name"] as? String }
        // Ollama reports "qwen3:4b-instruct"; accept a bare name as ":latest".
        let wanted = model.contains(":") ? model : model + ":latest"
        guard names.contains(wanted) else {
            return "model \(model) not pulled -- run: ollama pull \(model)"
        }
        return nil
    }

    /// Loads the weights so the first utterance of a meeting does not pay for
    /// it. Also the moment `keep_alive` starts counting, which is why it is
    /// worth doing even though the first real request would load the model
    /// anyway.
    static func prewarm(host: URL = defaultHost, model: String = defaultModel) {
        guard probe(host: host, model: model) == nil else { return }
        var request = URLRequest(url: host.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model, "messages": [], "stream": false, "keep_alive": -1,
        ])
        request.timeoutInterval = 120
        URLSession.shared.dataTask(with: request).resume()
    }

    // MARK: - Translation

    func translate(_ text: String, context: [(source: String, target: String)]) -> AsyncStream<TranslationDelta> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    let produced = try await stream(text, context: context) {
                        continuation.yield($0)
                    }
                    if !produced {
                        continuation.yield(.failed("Ollama (\(model)) returned no text"))
                    }
                    continuation.yield(.done)
                } catch is CancellationError {
                    // no-op: caller went away
                } catch {
                    Self.log.error("translate failed: \(error.localizedDescription)")
                    continuation.yield(.failed(error.localizedDescription,
                                               transient: TranslateError.isTransient(error)))
                    continuation.yield(.done)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// - Returns: whether any text was actually emitted.
    private func stream(_ text: String,
                        context: [(source: String, target: String)],
                        emit: @Sendable (TranslationDelta) -> Void) async throws -> Bool {

        var messages: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        for turn in context {
            messages.append(["role": "user",      "content": turn.source])
            messages.append(["role": "assistant", "content": turn.target])
        }
        messages.append(["role": "user", "content": text])

        let body: [String: Any] = [
            "model":    model,
            "messages": messages,
            "stream":   true,
            // Qwen3's hybrid tier reasons by default. Left on, it spends the
            // whole budget deliberating over a one-line translation and returns
            // nothing -- the same failure DeepSeek has without `thinking:
            // disabled`. Accepted without error by non-thinking builds too.
            "think":    false,
            // Never unload. The default 5-minute idle eviction means a quiet
            // stretch in a meeting is paid for by the next speaker, as a
            // multi-second reload of a 2.5GB model.
            "keep_alive": -1,
            "options": [
                "temperature": 0.2,
                "num_predict": 512,
                "num_ctx":     4096,
            ],
        ]

        var request = URLRequest(url: host.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 60

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranslateError.transport("no HTTP response")
        }
        guard http.statusCode == 200 else {
            var detail = ""
            for try await line in bytes.lines { detail += line; if detail.count > 500 { break } }
            throw TranslateError.http(http.statusCode, detail)
        }

        var producedText = false
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if let err = obj["error"] as? String { throw TranslateError.api(err) }

            if let message = obj["message"] as? [String: Any],
               let chunk = message["content"] as? String, !chunk.isEmpty {
                producedText = true
                emit(.text(chunk))
            }
            if obj["done"] as? Bool == true { break }
        }
        return producedText
    }

    enum TranslateError: Error, LocalizedError {
        case http(Int, String)
        case api(String)
        case transport(String)
        var errorDescription: String? {
            switch self {
            case .http(let code, let body): "HTTP \(code): \(body.prefix(200))"
            case .api(let m):               "Ollama error: \(m)"
            case .transport(let m):         "transport: \(m)"
            }
        }

        /// Whether `FallbackTranslator` should send the line again. A server
        /// that is not running refuses the connection, which counts: Ollama
        /// restarting is exactly the case a retry covers.
        static func isTransient(_ error: Error) -> Bool {
            switch error as? TranslateError {
            case .http(let code, _)?: TransientFailure.isTransient(status: code)
            case .api?:               false
            case .transport?:         true
            case nil:                 TransientFailure.isTransient(error)
            }
        }
    }
}
