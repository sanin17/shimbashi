import Foundation

/// Synthesizes speech audio for arbitrary Japanese text via Gemini's
/// Interactions API — used for the "play again" button on turns and
/// breakdown phrases, not the live conversation itself (that's Gemini
/// Live's own native audio, played directly as it streams in). Field
/// shapes verified against a full live response round-trip (pretty-printed,
/// audio payload elided), not just docs — which described an SDK
/// convenience accessor, `interaction.output_audio`, that doesn't match the
/// actual wire JSON at all. The real shape:
/// `{"steps": [{"content": [{"type": "audio", "data": "<base64 PCM16>",
/// "sample_rate": 24000, "channels": 1, "mime_type": "audio/l16; ..."}]}]}`
/// — note it's `content[].type`, not `.modality` (a `"modality"` string
/// does appear elsewhere in the response, in an unrelated token-usage
/// breakdown, which is a trap for exactly this kind of field-name guess).
struct SpeechClient {
    enum SpeechError: Error {
        case noAudioInResponse
        case requestFailed(status: Int, body: String)
    }

    let apiKey: String
    var session = URLSession(configuration: .default)

    /// Tried in order. The first is Google's full-fidelity TTS (best for the
    /// pronunciation a learner is studying); the second is the cheaper
    /// Flash-Lite variant, used when the first is throttled, overloaded, or
    /// not available to this key. Both take the identical request. They
    /// replace gemini-3.1-flash-tts-preview, which Google retires on
    /// 2026-11-17.
    var models = ["gemini-3.8-flash-tts", "gemini-3.8-flash-lite-tts"]
    private static let voice = "Kore"

    /// Returns a playable WAV file. Gemini 3.8 TTS answers with a complete
    /// WAV (RIFF header included); the older preview returned raw headerless
    /// PCM16 (`audio/l16`), which `AVAudioPlayer` can't auto-detect and so
    /// had to be wrapped. `playableAudio(fromResponse:)` handles both, so
    /// audio is never wrapped twice.
    func synthesize(_ text: String) async throws -> Data {
        var lastError: Error = SpeechError.noAudioInResponse
        for model in models {
            do {
                return try await synthesize(text, with: model)
            } catch SpeechError.requestFailed(let status, let body) {
                lastError = SpeechError.requestFailed(status: status, body: body)
                // Throttled, overloaded, or this model isn't there for this
                // key: the other model is a different quota and capacity pool.
                guard [404, 429, 500, 502, 503, 504].contains(status) else { throw lastError }
                debugLog("[DEBUG SpeechClient] \(model) failed with \(status), trying next")
            }
        }
        throw lastError
    }

    private func synthesize(_ text: String, with model: String) async throws -> Data {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.requestBody(text: text, model: model))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw SpeechError.requestFailed(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        return try Self.playableAudio(fromResponse: data)
    }

    /// The 3.8 TTS request: `input` is a list of typed user turns, and the
    /// text is spoken verbatim (style guidance would go in a
    /// `speech_metadata` annotation, never in the text itself).
    static func requestBody(text: String, model: String) -> [String: Any] {
        [
            "model": model,
            "input": [[
                "type": "user_input",
                "content": [["type": "text", "text": text]],
            ]],
            "response_format": ["type": "audio"],
            "generation_config": [
                "speech_config": [["voice": voice]],
            ],
        ]
    }

    /// Pulls the audio out of an Interactions response and returns bytes
    /// `AVAudioPlayer` can play. Steps without `content` (anything that
    /// isn't model output) are ignored rather than failing the decode.
    static func playableAudio(fromResponse data: Data) throws -> Data {
        struct InteractionResponse: Decodable {
            struct Step: Decodable {
                struct Content: Decodable {
                    var data: String?
                    var type: String?
                    var sampleRate: Int?
                    var channels: Int?

                    enum CodingKeys: String, CodingKey {
                        case data, type, channels
                        case sampleRate = "sample_rate"
                    }
                }
                var type: String?
                var content: [Content]?
            }
            var steps: [Step]?
        }

        let decoded: InteractionResponse
        do {
            decoded = try JSONDecoder().decode(InteractionResponse.self, from: data)
        } catch {
            // TEMPORARY DEBUG
            debugLog("[DEBUG SpeechClient] decode failed (\(error)); raw response: \(String(data: data, encoding: .utf8) ?? "<non-utf8>")")
            throw error
        }
        guard let audioContent = (decoded.steps ?? []).flatMap({ $0.content ?? [] }).last(where: { $0.type == "audio" }),
              let base64 = audioContent.data,
              let audio = Data(base64Encoded: base64) else {
            // TEMPORARY DEBUG
            debugLog("[DEBUG SpeechClient] no audio content found; raw response: \(String(data: data, encoding: .utf8) ?? "<non-utf8>")")
            throw SpeechError.noAudioInResponse
        }

        // Already a WAV (RIFF header): play as-is. Otherwise it's raw PCM16
        // and needs a header, using the rate/channels the response reports.
        if audio.starts(with: Data("RIFF".utf8)) {
            return audio
        }
        let sampleRate = UInt32(audioContent.sampleRate ?? 24_000)
        let channels = UInt16(audioContent.channels ?? 1)
        return wavData(fromPCM16: audio, sampleRate: sampleRate, channels: channels)
    }

    /// Exposed beyond this file so already-captured PCM16 (e.g. the model's
    /// own live-conversation audio, saved on `Turn.audio`) can be wrapped for
    /// `AVAudioPlayer` the same way synthesized speech is here — without a
    /// second network round-trip through `synthesize(_:)`.
    static func wavData(fromPCM16 pcm: Data, sampleRate: UInt32, channels: UInt16) -> Data {
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(pcm.count)

        var header = Data()
        header.append(contentsOf: "RIFF".utf8)
        header.appendLittleEndian(UInt32(36) + dataSize)
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.appendLittleEndian(UInt32(16))
        header.appendLittleEndian(UInt16(1)) // PCM
        header.appendLittleEndian(channels)
        header.appendLittleEndian(sampleRate)
        header.appendLittleEndian(byteRate)
        header.appendLittleEndian(blockAlign)
        header.appendLittleEndian(bitsPerSample)
        header.append(contentsOf: "data".utf8)
        header.appendLittleEndian(dataSize)
        return header + pcm
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt32) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: MemoryLayout<UInt32>.size))
    }

    mutating func appendLittleEndian(_ value: UInt16) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: MemoryLayout<UInt16>.size))
    }
}
