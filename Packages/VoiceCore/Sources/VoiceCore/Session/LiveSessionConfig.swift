import Foundation

/// What a conversation session needs to start — model, persona, and voice.
/// The API key is supplied separately at connect time, never stored here.
public struct LiveSessionConfig: Sendable {
    public var model: String
    public var systemInstruction: String?
    /// One of Gemini's prebuilt voice names (e.g. "Puck", "Kore"); `nil` lets
    /// the server pick a default.
    public var voiceName: String?
    /// 0 (most sensitive to quiet speech — Gemini's own default) to 1 (most
    /// resistant to background noise triggering a false turn start). Maps to
    /// the server's start-of-speech voice-activity-detection sensitivity and
    /// how much sustained speech it requires before committing a turn — see
    /// `GeminiLiveSession`.
    public var noiseResistance: Double

    public init(
        model: String = "models/gemini-3.1-flash-live-preview",
        systemInstruction: String? = nil,
        voiceName: String? = nil,
        noiseResistance: Double = 0
    ) {
        self.model = model
        self.systemInstruction = systemInstruction
        self.voiceName = voiceName
        self.noiseResistance = noiseResistance
    }
}
