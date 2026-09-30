import Foundation
import OSLog

/// Incremental output of a live translation session.
///
/// Richer than `TranslationDelta` because a live session is not one request
/// per line: the source transcript and the translation come back as two
/// interleaved streams, the server -- not a gate -- decides where a turn ends,
/// and the connection underneath is replaced several times an hour.
/// `LiveRowSegmenter` turns this into subtitle rows.
enum LiveDelta: Sendable, Equatable {
    /// Recognized source speech, a fragment at a time. `language` is the
    /// server's BCP-47 code, when it sends one.
    case source(String, language: String?)
    /// Translated text, a fragment at a time.
    case target(String, language: String?)
    /// The server closed the current turn. The translate model never sends
    /// one; other Live models, selectable with `--gemini-model`, do.
    case turnEnd
    /// The connection is being replaced. Audio is buffered meanwhile.
    case reconnecting
    /// Reconnecting gave up. Terminal: nothing follows it.
    case failed(String)
}

/// A backend that holds one streaming session open for the whole meeting and
/// is fed audio continuously.
///
/// Not `AudioTranslator`: that protocol takes one finished utterance and
/// returns its translation, which is exactly the request-per-line shape a live
/// session does not have. The model translates as it hears, so there is no
/// utterance to hand over, and output for one sentence is still arriving
/// while the next is heard.
protocol LiveTranslator: Sendable {
    /// - Parameter audio: the tap's stream, in `WAVEncoder.captureFormat`.
    func translate(_ audio: AsyncStream<AudioChunk>) -> AsyncStream<LiveDelta>
}

/// Speech-to-English through Gemini Live Translate, over the Live API's
/// bidirectional WebSocket.
///
/// Three properties of the translate model shape this client:
///
///   - **It only speaks.** `responseModalities` must be `AUDIO`; there is no
///     text tier. The text comes from `outputTranscription`, and the audio is
///     discarded unread -- but it is still billed, at roughly six times the
///     input rate. That is the price of this backend, not a bug in it.
///   - **It takes no instructions.** No system prompt, so neither
///     `InterpreterPrompt` nor the glossary reaches it, and there is no context
///     window of prior lines to send. It detects the source language itself.
///   - **Connections are short-lived.** About ten minutes per connection, with
///     a `goAway` warning first. A meeting outlives several, so the session is
///     resumed on a new socket with the last `sessionResumptionUpdate` handle,
///     and audio captured during the handover is buffered, not dropped.
struct GeminiLiveTranslator: LiveTranslator {

    private static let log = Logger(subsystem: "com.loind.tsuyaku", category: "gemini")

    static let endpoint = URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")!

    /// A preview ID, so a default rather than a constant: `--gemini-model`
    /// overrides it, and `--gemini-test` prints the server's close reason
    /// verbatim when the ID is wrong.
    static let defaultModel = "gemini-3.5-live-translate-preview"

    /// 100 ms of 16 kHz mono Int16, the chunk size the translate guide asks for.
    static let frameBytes = 3_200

    let apiKey: String
    let model: String
    /// Whether speech already in the target language is repeated back. On,
    /// English turns come through verbatim; off, they produce nothing.
    let echoTargetLanguage: Bool
    let targetLanguageCode: String
    /// Every server message, with audio payloads elided. For `--gemini-test`.
    let trace: (@Sendable (String) -> Void)?
    /// How long to keep listening once the audio ends, so the translation of
    /// the last words still arrives.
    var drain: Duration = .seconds(4)
    /// Consecutive failed connections before giving up.
    var maxAttempts = 5

    init(apiKey: String,
         model: String = defaultModel,
         echoTargetLanguage: Bool = true,
         targetLanguageCode: String = "en",
         trace: (@Sendable (String) -> Void)? = nil) {
        self.apiKey = apiKey
        self.model = model
        self.echoTargetLanguage = echoTargetLanguage
        self.targetLanguageCode = targetLanguageCode
        self.trace = trace
    }

    func translate(_ audio: AsyncStream<AudioChunk>) -> AsyncStream<LiveDelta> {
        AsyncStream { continuation in
            let task = Task {
                await run(audio) { continuation.yield($0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private enum Role: Sendable { case pump, sender, connection }

    /// Three tasks: one cuts the tap's audio into frames, one sends them on
    /// whichever socket is current, one owns the socket and replaces it.
    ///
    /// The sender outlives every connection. It holds the frame stream, and a
    /// stream can only be iterated once, so it cannot belong to a connection.
    /// While no socket is ready it simply stops pulling, and the frame stream's
    /// `bufferingNewest` keeps the most recent five seconds.
    private func run(_ audio: AsyncStream<AudioChunk>,
                     emit: @escaping @Sendable (LiveDelta) -> Void) async {
        let (frames, sink) = AsyncStream.makeStream(of: Data.self,
                                                   bufferingPolicy: .bufferingNewest(50))
        let link = Link()

        await withTaskGroup(of: Role.self) { group in
            group.addTask { await Self.pump(audio, into: sink); return .pump }
            group.addTask { await send(frames, over: link); return .sender }
            group.addTask { await connect(link: link, emit: emit); return .connection }

            while let finished = await group.next() {
                if finished == .pump { continue }
                // The audio ended and has all been sent. Stay connected long
                // enough to hear the translation of the last sentence.
                if finished == .sender { try? await Task.sleep(for: drain) }
                break
            }
            await link.close()
            group.cancelAll()
        }
    }

    private static func pump(_ audio: AsyncStream<AudioChunk>,
                             into sink: AsyncStream<Data>.Continuation) async {
        var pending = Data()
        for await chunk in audio {
            pending.append(WAVEncoder.pcm([chunk.buffer]))
            while pending.count >= frameBytes {
                sink.yield(Data(pending.prefix(frameBytes)))
                pending.removeFirst(frameBytes)
            }
        }
        if !pending.isEmpty { sink.yield(pending) }
        sink.finish()
    }

    private func send(_ frames: AsyncStream<Data>, over link: Link) async {
        for await frame in frames {
            guard let socket = await link.current() else { return }
            // Hand-built: base64 needs no JSON escaping, and this runs ten
            // times a second for the length of the meeting.
            let message = #"{"realtimeInput":{"audio":{"data":""#
                + frame.base64EncodedString()
                + #"","mimeType":"audio/pcm;rate=16000"}}}"#
            do {
                try await socket.send(.string(message))
            } catch {
                // The receive side sees the same failure and reconnects; this
                // only stops the sender from writing into a dead socket.
                await link.drop(socket)
            }
        }
        // Tells the server no more audio is coming. The translate model does
        // not flush on it -- measured: the last words go untranslated unless
        // silence follows them -- but it costs nothing, and the other Live
        // models do.
        if let socket = await link.current() {
            try? await socket.send(.string(#"{"realtimeInput":{"audioStreamEnd":true}}"#))
        }
    }

    // MARK: - Connection

    private struct SessionState {
        var handle: String?
        var established = false
    }

    /// Replaces the socket until cancelled, or until `maxAttempts` connections
    /// in a row fail.
    ///
    /// A connection counts as healthy if it ended on a `goAway` or ran for
    /// thirty seconds. Reaching `setupComplete` is not enough on its own: a
    /// server that accepts the setup and then drops every connection at the
    /// first audio frame would otherwise be retried forever.
    private func connect(link: Link, emit: @escaping @Sendable (LiveDelta) -> Void) async {
        var handle: String?
        var failures = 0
        while !Task.isCancelled {
            var state = SessionState(handle: handle)
            let started = ContinuousClock.now
            var failure: Error?
            do {
                try await session(&state, link: link, emit: emit)
            } catch {
                if Task.isCancelled { return }
                failure = error
            }

            // The server refused the setup itself: a malformed field (1007) or
            // a bad key (1008). Sending the same setup again cannot succeed.
            if !state.established, let refused = failure as? GeminiError, refused.isRefusal {
                Self.log.error("setup refused: \(refused.localizedDescription, privacy: .public)")
                emit(.failed(refused.localizedDescription))
                return
            }

            let lasted = started.duration(to: .now) >= .seconds(30)
            if state.established && (failure == nil || lasted) {
                failures = 0
                Self.log.info("connection replaced: \(failure?.localizedDescription ?? "goAway", privacy: .public)")
            } else {
                failures += 1
                let why = failure?.localizedDescription ?? "closed before setup"
                // Public: close reasons are server text and never carry the key,
                // which travels in a header.
                Self.log.error("connection failed (\(failures)/\(maxAttempts)): \(why, privacy: .public)")
                if failures >= maxAttempts {
                    emit(.failed(why))
                    return
                }
                // A handle the server no longer honours is one reason a setup
                // is refused; the next attempt starts a fresh session.
                if !state.established { state.handle = nil }
            }
            handle = state.handle
            emit(.reconnecting)
            if failures > 0 { try? await Task.sleep(for: .milliseconds(250 << failures)) }
        }
    }

    /// One connection, from handshake to `goAway` (returns) or failure (throws).
    private func session(_ state: inout SessionState,
                         link: Link,
                         emit: @Sendable (LiveDelta) -> Void) async throws {
        var request = URLRequest(url: Self.endpoint)
        // A header rather than the `?key=` query parameter the samples use, so
        // the key never appears in a URL that might be logged.
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.maximumMessageSize = 16 << 20
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        do {
            try await socket.send(.string(setupMessage(resuming: state.handle)))
        } catch {
            throw Self.describe(socket, error)
        }

        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await withTaskCancellationHandler {
                    try await socket.receive()
                } onCancel: {
                    socket.cancel(with: .goingAway, reason: nil)
                }
            } catch {
                await link.drop(socket)
                try Task.checkCancellation()
                throw Self.describe(socket, error)
            }

            // The Live API sends its JSON in binary frames, not text ones.
            let text: String
            switch message {
            case .string(let s): text = s
            case .data(let d):   text = String(decoding: d, as: UTF8.self)
            @unknown default:    continue
            }
            trace?(Self.elidingAudio(text))
            guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
            else { continue }

            if obj["setupComplete"] != nil {
                state.established = true
                await link.publish(socket)
            }
            if let update = obj["sessionResumptionUpdate"] as? [String: Any],
               update["resumable"] as? Bool ?? true,
               let next = update["newHandle"] as? String, !next.isEmpty {
                state.handle = next
            }
            if let content = obj["serverContent"] as? [String: Any] {
                Self.parse(content, emit: emit)
            }
            if obj["goAway"] != nil {
                await link.drop(socket)
                return
            }
        }
    }

    /// The transcription fields sit at the top level of `setup`, as the Live
    /// API reference lists them. The translate guide's WebSocket sample puts
    /// them inside `generationConfig`, and the server refuses that: "Unknown
    /// name "inputAudioTranscription" at 'setup.generation_config'".
    private func setupMessage(resuming handle: String?) -> String {
        var resumption: [String: Any] = [:]
        if let handle { resumption["handle"] = handle }
        let setup: [String: Any] = [
            "setup": [
                "model": model.hasPrefix("models/") ? model : "models/\(model)",
                "inputAudioTranscription": [String: Any](),
                "outputAudioTranscription": [String: Any](),
                "generationConfig": [
                    "responseModalities": ["AUDIO"],
                    "translationConfig": [
                        "targetLanguageCode": targetLanguageCode,
                        "echoTargetLanguage": echoTargetLanguage,
                    ],
                ],
                // An empty object still matters: it is what asks the server to
                // send resumption handles at all.
                "sessionResumption": resumption,
                // Without it an audio session ends outright at fifteen minutes.
                "contextWindowCompression": ["slidingWindow": [String: Any]()],
            ],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: setup)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func parse(_ content: [String: Any], emit: @Sendable (LiveDelta) -> Void) {
        if let t = content["inputTranscription"] as? [String: Any],
           let text = t["text"] as? String, !text.isEmpty {
            emit(.source(text, language: t["languageCode"] as? String))
        }
        if let t = content["outputTranscription"] as? [String: Any],
           let text = t["text"] as? String, !text.isEmpty {
            emit(.target(text, language: t["languageCode"] as? String))
        }
        // Either one ends the turn as far as a subtitle is concerned. The
        // translate model sends neither, so `LiveRowSegmenter` cuts rows from
        // the text; these matter only for the other Live models.
        if content["generationComplete"] as? Bool == true || content["turnComplete"] as? Bool == true {
            emit(.turnEnd)
        }
    }

    /// A dropped connection says why in its close frame -- that is where a
    /// malformed setup or a bad model ID is reported -- so prefer that over
    /// URLSession's generic "socket is not connected".
    private static func describe(_ socket: URLSessionWebSocketTask, _ error: Error) -> GeminiError {
        if socket.closeCode != .invalid {
            // Cut at 123 bytes by the WebSocket protocol, often mid-word; the
            // first complaint is always whole, which is the one that matters.
            let reason = socket.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? ""
            return .closed(socket.closeCode.rawValue,
                           reason.replacingOccurrences(of: "\n", with: " "))
        }
        if let http = socket.response as? HTTPURLResponse, http.statusCode != 101 {
            return .handshake(http.statusCode)
        }
        return .transport(error.localizedDescription)
    }

    private static func elidingAudio(_ text: String) -> String {
        text.replacingOccurrences(of: #""data"\s*:\s*"[A-Za-z0-9+/=]{64,}""#,
                                  with: #""data":"…""#,
                                  options: .regularExpression)
    }

    enum GeminiError: Error, LocalizedError {
        case closed(Int, String)
        case handshake(Int)
        case transport(String)

        /// Close codes that mean "this request is wrong", not "try later".
        var isRefusal: Bool {
            if case .closed(let code, _) = self { return code == 1007 || code == 1008 }
            return false
        }

        var errorDescription: String? {
            switch self {
            case .closed(let code, let reason):
                "closed \(code): \(reason.isEmpty ? "(no reason given)" : String(reason.prefix(300)))"
            case .handshake(let code):
                "HTTP \(code) on connect -- check the key"
            case .transport(let m):
                "transport: \(m)"
            }
        }
    }

    /// The socket the sender should write to, or none while one is being
    /// replaced. Published only after `setupComplete`: audio sent before the
    /// setup is acknowledged is rejected.
    private actor Link {
        private var socket: URLSessionWebSocketTask?
        private var waiters: [CheckedContinuation<URLSessionWebSocketTask?, Never>] = []
        private var closed = false

        /// Waits for a socket. Nil means the session is over.
        func current() async -> URLSessionWebSocketTask? {
            if let socket { return socket }
            if closed { return nil }
            return await withCheckedContinuation { waiters.append($0) }
        }

        func publish(_ s: URLSessionWebSocketTask) {
            guard !closed else { return }
            socket = s
            resume(with: s)
        }

        /// Only if `s` is still current: a late failure on the previous socket
        /// must not unpublish its replacement.
        func drop(_ s: URLSessionWebSocketTask) {
            if socket === s { socket = nil }
        }

        func close() {
            closed = true
            socket = nil
            resume(with: nil)
        }

        private func resume(with s: URLSessionWebSocketTask?) {
            let pending = waiters
            waiters = []
            for w in pending { w.resume(returning: s) }
        }
    }
}
