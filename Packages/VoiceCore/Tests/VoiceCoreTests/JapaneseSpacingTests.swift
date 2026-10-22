import Testing
@testable import VoiceCore

@Suite struct JapaneseSpacingTests {
    @Test func tokenizedJapaneseIsJoined() {
        let spaced = "東京 は 美味しい もの が たくさん あります よ 。どんな 食べ物 に 興味 が あり ます か ?"
        #expect(spaced.removingSpacesBetweenJapanese == "東京は美味しいものがたくさんありますよ。どんな食べ物に興味がありますか?")
    }

    @Test func alreadyCleanTextIsUntouched() {
        let clean = "なるほど。お寿司やラーメンには興味がありますか?"
        #expect(clean.removingSpacesBetweenJapanese == clean)
    }

    @Test func englishKeepsItsSpaces() {
        let english = "What's the best place to eat in Tokyo?"
        #expect(english.removingSpacesBetweenJapanese == english)
    }

    @Test func spacesBetweenLatinAndJapaneseAreKept() {
        #expect("AI を 使う".removingSpacesBetweenJapanese == "AI を使う")
        #expect("私は Tokyo に 住んでいます".removingSpacesBetweenJapanese == "私は Tokyo に住んでいます")
    }

    @Test func runsOfSpacesBetweenJapaneseAreAllRemoved() {
        #expect("これ   は   ペン".removingSpacesBetweenJapanese == "これはペン")
    }

    @Test func fullwidthAndHalfwidthPunctuationBothJoin() {
        #expect("いい ですね !".removingSpacesBetweenJapanese == "いいですね!")
        #expect("いい ですね ！".removingSpacesBetweenJapanese == "いいですね！")
        #expect("そう 、 です".removingSpacesBetweenJapanese == "そう、です")
    }

    @Test func longVowelMarkCountsAsJapanese() {
        #expect("ラーメン を 食べる".removingSpacesBetweenJapanese == "ラーメンを食べる")
    }

    @Test func streamedDeltasConvergeToTheSameResult() {
        // Mirrors how VoiceSession assembles a reply: re-normalizing the
        // whole accumulated string after every delta, where a delta may end
        // or start with the space.
        let deltas = ["東京 は ", "美味しい", " もの が たくさん", " あります よ 。", "どんな 食べ物", " に 興味", " が あり ます か ?"]
        var partial = ""
        for delta in deltas {
            partial = (partial + delta).removingSpacesBetweenJapanese
        }
        #expect(partial == "東京は美味しいものがたくさんありますよ。どんな食べ物に興味がありますか?")
    }

    @Test func aTrailingSpaceWaitsForTheNextPiece() {
        // Nothing follows the space yet, so it can't be judged — kept.
        #expect("東京 は ".removingSpacesBetweenJapanese == "東京は ")
    }

    @Test func emptyAndSpaceOnlyStringsAreSafe() {
        #expect("".removingSpacesBetweenJapanese == "")
        #expect("   ".removingSpacesBetweenJapanese == "   ")
    }
}
