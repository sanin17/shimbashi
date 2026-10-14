import Testing
import Foundation
@testable import VoiceCore

@Suite struct LiveSetupFrameTests {
    private func encode(_ frame: LiveSetupFrame) throws -> [String: Any] {
        let data = try JSONEncoder().encode(frame)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    private func setup(_ object: [String: Any]) throws -> [String: Any] {
        try #require(object["setup"] as? [String: Any])
    }

    @Test func minimalSetupOmitsOptionalFields() throws {
        let frame = LiveSetupFrame(setup: .init(model: "models/gemini-live", generationConfig: .init()))
        let root = try setup(try encode(frame))
        #expect(root["systemInstruction"] == nil)
        #expect(root["sessionResumption"] == nil)
        #expect(root["realtimeInputConfig"] == nil)
        let generationConfig = try #require(root["generationConfig"] as? [String: Any])
        #expect(generationConfig["responseModalities"] as? [String] == ["AUDIO"])
        #expect(generationConfig["speechConfig"] == nil)
    }

    @Test func emptyConfigMarkersAreEmptyObjectsNotAbsent() throws {
        let frame = LiveSetupFrame(setup: .init(model: "m", generationConfig: .init()))
        let root = try setup(try encode(frame))
        #expect(root["inputAudioTranscription"] as? [String: String] == [:])
        #expect(root["outputAudioTranscription"] as? [String: String] == [:])
        let compression = try #require(root["contextWindowCompression"] as? [String: Any])
        #expect(compression["slidingWindow"] as? [String: String] == [:])
    }

    @Test func systemInstructionNestsAsPartsArray() throws {
        var setupValue = LiveSetupFrame.Setup(model: "m", generationConfig: .init())
        setupValue.systemInstruction = .init(text: "You are a Japanese tutor.")
        let root = try setup(try encode(LiveSetupFrame(setup: setupValue)))
        let instruction = try #require(root["systemInstruction"] as? [String: Any])
        let parts = try #require(instruction["parts"] as? [[String: Any]])
        #expect(parts.first?["text"] as? String == "You are a Japanese tutor.")
    }

    @Test func sessionResumptionWithHandlePresent() throws {
        var setupValue = LiveSetupFrame.Setup(model: "m", generationConfig: .init())
        setupValue.sessionResumption = .init(handle: "resume-token-123")
        let root = try setup(try encode(LiveSetupFrame(setup: setupValue)))
        let resumption = try #require(root["sessionResumption"] as? [String: Any])
        #expect(resumption["handle"] as? String == "resume-token-123")
    }

    @Test func sessionResumptionWithNilHandleIsStillAnEmptyObject() throws {
        var setupValue = LiveSetupFrame.Setup(model: "m", generationConfig: .init())
        setupValue.sessionResumption = .init(handle: nil)
        let root = try setup(try encode(LiveSetupFrame(setup: setupValue)))
        #expect(root["sessionResumption"] as? [String: String] == [:])
    }

    @Test func pushToTalkNestsAutomaticActivityDetectionUnderRealtimeInputConfig() throws {
        var setupValue = LiveSetupFrame.Setup(model: "m", generationConfig: .init())
        setupValue.realtimeInputConfig = .init(automaticActivityDetection: .init(disabled: true))
        let root = try setup(try encode(LiveSetupFrame(setup: setupValue)))
        let realtimeInputConfig = try #require(root["realtimeInputConfig"] as? [String: Any])
        let detection = try #require(realtimeInputConfig["automaticActivityDetection"] as? [String: Any])
        #expect(detection["disabled"] as? Bool == true)
        #expect(detection["startOfSpeechSensitivity"] == nil)
        #expect(detection["prefixPaddingMs"] == nil)
    }

    @Test func speechConfigNestsVoiceNameUnderGenerationConfig() throws {
        let generationConfig = LiveSetupFrame.GenerationConfig(speechConfig: .init(voiceName: "Kore"))
        let root = try setup(try encode(LiveSetupFrame(setup: .init(model: "m", generationConfig: generationConfig))))
        let gc = try #require(root["generationConfig"] as? [String: Any])
        let speechConfig = try #require(gc["speechConfig"] as? [String: Any])
        let voiceConfig = try #require(speechConfig["voiceConfig"] as? [String: Any])
        let prebuilt = try #require(voiceConfig["prebuiltVoiceConfig"] as? [String: Any])
        #expect(prebuilt["voiceName"] as? String == "Kore")
    }
}
