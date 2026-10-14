import Foundation

/// The first message sent on the Gemini Live WebSocket, establishing the
/// model, behavior, and session-level configuration for everything that
/// follows. Field shapes verified against the `BidiGenerateContentSetup`
/// reference (ai.google.dev/api/live) — in particular, `responseModalities`
/// nests inside `generationConfig`, not top-level in `setup`.
struct LiveSetupFrame: Encodable {
    struct Setup: Encodable {
        var model: String
        var generationConfig: GenerationConfig
        var systemInstruction: Content?
        var inputAudioTranscription: EmptyConfig? = EmptyConfig()
        var outputAudioTranscription: EmptyConfig? = EmptyConfig()
        var sessionResumption: SessionResumptionConfig?
        /// Present with `slidingWindow` selected to lift the ~15 minute
        /// session cap; omit `targetTokens` to use the server's default.
        var contextWindowCompression: ContextWindowCompression? = ContextWindowCompression()
        /// Tunes how readily the server's own voice-activity detection
        /// decides you've started talking — see `RealtimeInputConfig`.
        var realtimeInputConfig: RealtimeInputConfig?
    }

    struct GenerationConfig: Encodable {
        var responseModalities: [String] = ["AUDIO"]
        var speechConfig: SpeechConfig?
    }

    struct Content: Encodable {
        struct Part: Encodable { var text: String }
        var parts: [Part]

        init(text: String) {
            self.parts = [Part(text: text)]
        }
    }

    /// Marker for fields whose JSON value is just `{}` to opt in to a feature.
    struct EmptyConfig: Encodable {}

    struct SessionResumptionConfig: Encodable {
        /// Present when resuming a prior session; omitted to start fresh.
        var handle: String?
    }

    struct ContextWindowCompression: Encodable {
        var slidingWindow: EmptyConfig = EmptyConfig()
    }

    /// Field shape verified against `BidiGenerateContentSetup.realtimeInputConfig`
    /// (ai.google.dev/api/live): `automaticActivityDetection` nests under
    /// `realtimeInputConfig`, not top-level in `setup`.
    struct RealtimeInputConfig: Encodable {
        var automaticActivityDetection: AutomaticActivityDetection
    }

    struct AutomaticActivityDetection: Encodable {
        /// `true` puts the connection in push-to-talk mode: the server does
        /// no VAD of its own, and the client must bracket each utterance
        /// with an explicit `activityStart`/`activityEnd` (see `LiveOutbound`).
        var disabled: Bool?
        /// `"START_SENSITIVITY_HIGH"` (server default) or `"START_SENSITIVITY_LOW"`
        /// — LOW requires louder/clearer speech before committing a turn start.
        /// Meaningless (and omitted) once `disabled` is true.
        var startOfSpeechSensitivity: String?
        /// How much sustained speech is required before start-of-speech is
        /// committed, in milliseconds — higher rejects brief noise blips.
        /// Meaningless (and omitted) once `disabled` is true.
        var prefixPaddingMs: Int?
    }

    struct SpeechConfig: Encodable {
        var voiceConfig: VoiceConfig
        struct VoiceConfig: Encodable {
            var prebuiltVoiceConfig: PrebuiltVoiceConfig
            struct PrebuiltVoiceConfig: Encodable { var voiceName: String }
        }

        init(voiceName: String) {
            self.voiceConfig = VoiceConfig(prebuiltVoiceConfig: .init(voiceName: voiceName))
        }
    }

    var setup: Setup
}
