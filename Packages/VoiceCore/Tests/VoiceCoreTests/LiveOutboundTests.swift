import Testing
import Foundation
@testable import VoiceCore

@Suite struct LiveOutboundTests {
    private func jsonObject(_ string: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(string.utf8))
        return try #require(object as? [String: Any])
    }

    @Test func realtimeAudioShape() throws {
        let json = LiveOutbound.realtimeAudio(base64: "QUJD")
        let object = try jsonObject(json)
        let realtimeInput = try #require(object["realtimeInput"] as? [String: Any])
        let audio = try #require(realtimeInput["audio"] as? [String: Any])
        #expect(audio["data"] as? String == "QUJD")
        #expect(audio["mimeType"] as? String == "audio/pcm;rate=16000")
    }

    @Test func audioStreamEndShape() throws {
        let object = try jsonObject(LiveOutbound.audioStreamEnd)
        let realtimeInput = try #require(object["realtimeInput"] as? [String: Any])
        #expect(realtimeInput["audioStreamEnd"] as? Bool == true)
    }

    @Test func activityStartShape() throws {
        let object = try jsonObject(LiveOutbound.activityStart)
        let realtimeInput = try #require(object["realtimeInput"] as? [String: Any])
        #expect(realtimeInput["activityStart"] as? [String: String] == [:])
    }

    @Test func activityEndShape() throws {
        let object = try jsonObject(LiveOutbound.activityEnd)
        let realtimeInput = try #require(object["realtimeInput"] as? [String: Any])
        #expect(realtimeInput["activityEnd"] as? [String: String] == [:])
    }

    @Test func textFrameShape() throws {
        let data = try #require(LiveOutbound.text("How do I say restroom?"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let clientContent = try #require(object["clientContent"] as? [String: Any])
        #expect(clientContent["turnComplete"] as? Bool == true)
        let turns = try #require(clientContent["turns"] as? [[String: Any]])
        #expect(turns.count == 1)
        #expect(turns[0]["role"] as? String == "user")
        let parts = try #require(turns[0]["parts"] as? [[String: Any]])
        #expect(parts[0]["text"] as? String == "How do I say restroom?")
    }
}
