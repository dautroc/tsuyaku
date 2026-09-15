import Foundation

/// Server-Sent Events framing for the Anthropic Messages protocol.
///
/// The spec terminates an event with a blank line, but Foundation's
/// `AsyncLineSequence` does not reliably surface empty lines, so a parser that
/// waits for one can silently consume an entire stream and emit nothing. Both
/// Anthropic and DeepSeek send exactly one complete JSON object per `data:`
/// line, so each such line is treated as a whole event. A blank line, if one
/// does arrive, just clears any pending event name.
struct SSEParser {
    private var event: String?

    struct Frame { let event: String?; let data: String }

    /// Feed one line (newline already stripped). Returns a frame per `data:`.
    mutating func consume(_ line: String) -> Frame? {
        let line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        if line.isEmpty { event = nil; return nil }

        if line.hasPrefix("event:") {
            event = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
            return nil
        }
        if line.hasPrefix("data:") {
            let payload = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty, payload != "[DONE]" else { return nil }
            defer { event = nil }
            return Frame(event: event, data: payload)
        }
        return nil   // comments (":" keepalives), id:, retry:
    }
}
