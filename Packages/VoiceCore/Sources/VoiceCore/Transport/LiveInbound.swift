import Foundation

/// One decoded server message, normalized into whatever the rest of the app
/// actually needs — callers never touch the raw wire JSON. Transcription
/// fields arrive as incremental deltas to append, not cumulative snapshots.
enum LiveServerEvent: Sendable, Equatable, CustomStringConvertible {
    case setupComplete
    case inputTranscriptionDelta(String)
    case outputTranscriptionDelta(String)
    case modelAudio(Data)
    case interrupted
    case turnComplete
    case goAway(timeLeft: TimeInterval?)
    case sessionResumptionUpdate(handle: String, resumable: Bool)
    /// Synthetic — never decoded off the wire. `GeminiLiveSession` emits these
    /// around an internal reconnect (proactive, ahead of `goAway`'s deadline,
    /// or reactive after an unexpected drop) so a caller can show a transient
    /// "reconnecting" state instead of treating the gap as a hard failure.
    case reconnecting
    case reconnected

    /// Redacts audio payloads to a byte count — printing raw `Data` dumps a
    /// hex string per chunk, which floods the console at 10Hz for no value.
    var description: String {
        switch self {
        case .setupComplete: return "setupComplete"
        case .inputTranscriptionDelta(let text): return "inputTranscriptionDelta(\(text))"
        case .outputTranscriptionDelta(let text): return "outputTranscriptionDelta(\(text))"
        case .modelAudio(let data): return "modelAudio(\(data.count) bytes)"
        case .interrupted: return "interrupted"
        case .turnComplete: return "turnComplete"
        case .goAway(let timeLeft): return "goAway(timeLeft: \(String(describing: timeLeft)))"
        case .sessionResumptionUpdate(let handle, let resumable): return "sessionResumptionUpdate(handle: \(handle.prefix(8))…, resumable: \(resumable))"
        case .reconnecting: return "reconnecting"
        case .reconnected: return "reconnected"
        }
    }
}

/// Decodable mirror of `BidiGenerateContentServerMessage`. Only the fields we
/// consume are modeled — `Decodable` ignores unknown fields by default, so
/// this doesn't need to be exhaustive against the full reference.
struct LiveServerMessage: Decodable {
    struct ServerContent: Decodable {
        struct ModelTurn: Decodable {
            struct Part: Decodable {
                struct InlineData: Decodable { var mimeType: String?; var data: String? }
                var inlineData: InlineData?
            }
            var parts: [Part]?
        }
        struct Transcription: Decodable { var text: String? }

        var modelTurn: ModelTurn?
        var inputTranscription: Transcription?
        var outputTranscription: Transcription?
        var interrupted: Bool?
        var turnComplete: Bool?
    }

    struct GoAway: Decodable { var timeLeft: String? }

    struct SessionResumptionUpdate: Decodable {
        var newHandle: String?
        var resumable: Bool?
    }

    struct EmptyMarker: Decodable {}

    var setupComplete: EmptyMarker?
    var serverContent: ServerContent?
    var goAway: GoAway?
    var sessionResumptionUpdate: SessionResumptionUpdate?

    /// Splits one decoded message into zero or more normalized events — a
    /// single `serverContent` message can carry a transcription delta and
    /// audio together.
    func events() -> [LiveServerEvent] {
        var out: [LiveServerEvent] = []
        if setupComplete != nil { out.append(.setupComplete) }

        if let content = serverContent {
            if let text = content.inputTranscription?.text, !text.isEmpty {
                out.append(.inputTranscriptionDelta(text))
            }
            if let text = content.outputTranscription?.text, !text.isEmpty {
                out.append(.outputTranscriptionDelta(text))
            }
            for part in content.modelTurn?.parts ?? [] {
                if let base64 = part.inlineData?.data, let data = Data(base64Encoded: base64) {
                    out.append(.modelAudio(data))
                }
            }
            if content.interrupted == true { out.append(.interrupted) }
            if content.turnComplete == true { out.append(.turnComplete) }
        }

        if let goAway {
            out.append(.goAway(timeLeft: goAway.timeLeft.flatMap(Self.parseProtobufDuration)))
        }

        if let update = sessionResumptionUpdate, let handle = update.newHandle {
            out.append(.sessionResumptionUpdate(handle: handle, resumable: update.resumable ?? false))
        }

        return out
    }

    /// `google.protobuf.Duration`'s canonical JSON encoding: a decimal number
    /// of seconds followed by "s", e.g. "3.000001s".
    private static func parseProtobufDuration(_ string: String) -> TimeInterval? {
        guard string.hasSuffix("s") else { return nil }
        return TimeInterval(string.dropLast())
    }
}
