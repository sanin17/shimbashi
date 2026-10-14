import Testing
import Foundation
@testable import VoiceCore

@Suite struct LiveInboundTests {
    private func decode(_ json: String) throws -> LiveServerMessage {
        try JSONDecoder().decode(LiveServerMessage.self, from: Data(json.utf8))
    }

    @Test func setupCompleteProducesEvent() throws {
        let message = try decode(#"{"setupComplete":{}}"#)
        #expect(message.events() == [.setupComplete])
    }

    @Test func inputTranscriptionDeltaIsEmitted() throws {
        let message = try decode(#"{"serverContent":{"inputTranscription":{"text":"hello"}}}"#)
        #expect(message.events() == [.inputTranscriptionDelta("hello")])
    }

    @Test func emptyInputTranscriptionTextIsFiltered() throws {
        let message = try decode(#"{"serverContent":{"inputTranscription":{"text":""}}}"#)
        #expect(message.events().isEmpty)
    }

    @Test func outputTranscriptionDeltaIsEmitted() throws {
        let message = try decode(#"{"serverContent":{"outputTranscription":{"text":"こんにちは"}}}"#)
        #expect(message.events() == [.outputTranscriptionDelta("こんにちは")])
    }

    @Test func modelAudioIsDecodedFromBase64() throws {
        let payload = Data([1, 2, 3, 4]).base64EncodedString()
        let message = try decode(#"{"serverContent":{"modelTurn":{"parts":[{"inlineData":{"data":""# + payload + #"","mimeType":"audio/pcm"}}]}}}"#)
        #expect(message.events() == [.modelAudio(Data([1, 2, 3, 4]))])
    }

    @Test func invalidBase64AudioIsSkipped() throws {
        let message = try decode(#"{"serverContent":{"modelTurn":{"parts":[{"inlineData":{"data":"not-valid-base64!!","mimeType":"audio/pcm"}}]}}}"#)
        #expect(message.events().isEmpty)
    }

    @Test func interruptedTrueProducesEvent() throws {
        let message = try decode(#"{"serverContent":{"interrupted":true}}"#)
        #expect(message.events() == [.interrupted])
    }

    @Test func interruptedFalseProducesNoEvent() throws {
        let message = try decode(#"{"serverContent":{"interrupted":false}}"#)
        #expect(message.events().isEmpty)
    }

    @Test func turnCompleteTrueProducesEvent() throws {
        let message = try decode(#"{"serverContent":{"turnComplete":true}}"#)
        #expect(message.events() == [.turnComplete])
    }

    @Test func goAwayWithParseableTimeLeftIsEmitted() throws {
        let message = try decode(#"{"goAway":{"timeLeft":"3.000001s"}}"#)
        let events = message.events()
        guard case .goAway(let timeLeft) = events.first else {
            Issue.record("expected .goAway event")
            return
        }
        #expect(timeLeft != nil)
        #expect(abs((timeLeft ?? 0) - 3.000001) < 0.0001)
    }

    @Test func goAwayWithMalformedTimeLeftEmitsNilDuration() throws {
        let message = try decode(#"{"goAway":{"timeLeft":"not-a-duration"}}"#)
        #expect(message.events() == [.goAway(timeLeft: nil)])
    }

    @Test func goAwayMissingTimeLeftEmitsNilDuration() throws {
        let message = try decode(#"{"goAway":{}}"#)
        #expect(message.events() == [.goAway(timeLeft: nil)])
    }

    @Test func noGoAwayFieldProducesNoGoAwayEvent() throws {
        let message = try decode(#"{"setupComplete":{}}"#)
        #expect(!message.events().contains { if case .goAway = $0 { return true }; return false })
    }

    @Test func sessionResumptionUpdateWithHandleIsEmitted() throws {
        let message = try decode(#"{"sessionResumptionUpdate":{"newHandle":"abc123","resumable":true}}"#)
        #expect(message.events() == [.sessionResumptionUpdate(handle: "abc123", resumable: true)])
    }

    @Test func sessionResumptionUpdateMissingResumableDefaultsFalse() throws {
        let message = try decode(#"{"sessionResumptionUpdate":{"newHandle":"abc123"}}"#)
        #expect(message.events() == [.sessionResumptionUpdate(handle: "abc123", resumable: false)])
    }

    @Test func sessionResumptionUpdateMissingHandleProducesNoEvent() throws {
        let message = try decode(#"{"sessionResumptionUpdate":{"resumable":true}}"#)
        #expect(message.events().isEmpty)
    }

    @Test func oneMessageCanProduceMultipleEventsInOrder() throws {
        let payload = Data([9, 9]).base64EncodedString()
        let json = """
        {"serverContent":{
            "outputTranscription":{"text":"ok"},
            "modelTurn":{"parts":[{"inlineData":{"data":"\(payload)","mimeType":"audio/pcm"}}]},
            "turnComplete":true
        }}
        """
        let message = try decode(json)
        #expect(message.events() == [
            .outputTranscriptionDelta("ok"),
            .modelAudio(Data([9, 9])),
            .turnComplete,
        ])
    }
}
