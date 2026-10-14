import Foundation

/// Messages the client sends after the initial setup handshake.
enum LiveOutbound {
    /// One ~100ms chunk of mic audio. Built via string interpolation rather
    /// than `JSONEncoder` — base64 output contains no JSON-escapable
    /// characters, and this sits on a 10Hz hot path.
    static func realtimeAudio(base64: String) -> String {
        #"{"realtimeInput":{"audio":{"data":""# + base64 + #"","mimeType":"audio/pcm;rate=16000"}}}"#
    }

    /// Signals the end of the current audio activity (e.g. on mute), letting
    /// the server's VAD close out the turn cleanly rather than hanging
    /// mid-utterance.
    static let audioStreamEnd = #"{"realtimeInput":{"audioStreamEnd":true}}"#

    /// Manually marks the start/end of the user's turn — only valid (and
    /// only sent) when `automaticActivityDetection.disabled` was set in the
    /// setup frame, i.e. push-to-talk mode: the app decides turn boundaries
    /// from Start/Stop taps instead of the server's own VAD. Field shapes
    /// verified against `BidiGenerateContentRealtimeInput` (ai.google.dev/api/live).
    static let activityStart = #"{"realtimeInput":{"activityStart":{}}}"#
    static let activityEnd = #"{"realtimeInput":{"activityEnd":{}}}"#

    /// Free-form text into the conversation — for lesson prompts like
    /// "explain that" rather than spoken audio.
    static func text(_ text: String) -> Data? {
        struct ClientContent: Encodable {
            struct Turn: Encodable {
                struct Part: Encodable { var text: String }
                var role = "user"
                var parts: [Part]
            }
            struct Content: Encodable {
                var turns: [Turn]
                var turnComplete = true
            }
            var clientContent: Content
        }
        let frame = ClientContent(clientContent: .init(turns: [.init(parts: [.init(text: text)])]))
        return try? JSONEncoder().encode(frame)
    }
}
