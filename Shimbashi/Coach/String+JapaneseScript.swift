import Foundation

extension String {
    /// Whether this text contains any actual Japanese script (hiragana,
    /// katakana, or kanji) — used to skip translating/breaking down a turn
    /// that turned out to be English. The tutor persona explicitly allows
    /// asking "how do I say X" in English, and a learner's own turn can be
    /// that English question rather than an attempted Japanese sentence;
    /// running it through the Japanese-to-English translator anyway doesn't
    /// error, it just paraphrases the English back, which reads as nonsense.
    var containsJapaneseScript: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF: return true // hiragana + katakana
            case 0x3400...0x4DBF: return true // CJK extension A
            case 0x4E00...0x9FFF: return true // CJK unified ideographs (kanji)
            case 0xFF66...0xFF9D: return true // halfwidth katakana
            default: return false
            }
        }
    }
}
