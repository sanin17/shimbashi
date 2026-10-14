import Foundation

/// One completed exchange in the conversation.
public struct Turn: Sendable, Identifiable, Equatable {
    public enum Speaker: Sendable, Equatable {
        case user
        case model
    }

    public let id: UUID
    public var speaker: Speaker
    public var text: String
    /// Raw PCM16 mono 24kHz audio exactly as streamed for this turn, for the
    /// model's own spoken replies — lets playback reuse the audio Gemini
    /// already sent instead of re-synthesizing it through a separate TTS
    /// call. `nil` for user turns (never captured) or if none arrived.
    public var audio: Data?

    public init(id: UUID = UUID(), speaker: Speaker, text: String, audio: Data? = nil) {
        self.id = id
        self.speaker = speaker
        self.text = text
        self.audio = audio
    }
}
