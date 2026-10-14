import Testing
@testable import Shimbashi

@Suite struct StringJapaneseScriptTests {
    @Test func hiraganaDetected() {
        #expect("こんにちは".containsJapaneseScript)
    }

    @Test func katakanaDetected() {
        #expect("コーヒー".containsJapaneseScript)
    }

    @Test func kanjiDetected() {
        #expect("日本語".containsJapaneseScript)
    }

    @Test func halfwidthKatakanaDetected() {
        #expect("ﾄｲﾚ".containsJapaneseScript)
    }

    @Test func pureEnglishIsNotDetected() {
        #expect(!"How do I say restroom?".containsJapaneseScript)
    }

    @Test func mixedJapaneseAndEnglishIsDetected() {
        #expect("Please say トイレ for me".containsJapaneseScript)
    }

    @Test func punctuationOnlyIsNotDetected() {
        #expect(!"?!.,".containsJapaneseScript)
    }

    @Test func emptyStringIsNotDetected() {
        #expect(!"".containsJapaneseScript)
    }
}
