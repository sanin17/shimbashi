import Foundation

/// What a conversation session needs to start — model, persona, and voice.
/// The API key is supplied separately at connect time, never stored here.
public struct LiveSessionConfig: Sendable {
    public var model: String
    public var systemInstruction: String?
    /// One of Gemini's prebuilt voice names (e.g. "Puck", "Kore"); `nil` lets
    /// the server pick a default.
    public var voiceName: String?

    public init(
        model: String = "models/gemini-3.8-live",
        systemInstruction: String? = nil,
        voiceName: String? = nil
    ) {
        self.model = model
        self.systemInstruction = systemInstruction
        self.voiceName = voiceName
    }
}
