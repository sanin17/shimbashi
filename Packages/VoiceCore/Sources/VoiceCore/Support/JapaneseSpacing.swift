extension String {
    /// Removes spaces the speech recognizer inserts *inside* Japanese text.
    ///
    /// Japanese isn't written with spaces, but `gemini-3.8-live` sometimes
    /// transcribes its own replies tokenized — `東京 は 美味しい もの が …` —
    /// which then shows on screen and flows into the translation and phrase
    /// breakdown. A space is dropped only when it sits between two Japanese
    /// characters, or between a Japanese character and sentence punctuation
    /// (`か ?`). Spaces between Latin words, or between Latin and Japanese
    /// (`AI を 使う` keeps `AI を`), are left alone.
    ///
    /// Safe to re-apply to text that is still being assembled from streamed
    /// deltas: a trailing space with nothing after it yet is kept, and is
    /// judged again once the next piece arrives.
    var removingSpacesBetweenJapanese: String {
        let chars = Array(self)
        guard chars.contains(" ") else { return self }

        var result = ""
        result.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            guard chars[i] == " " else {
                result.append(chars[i])
                i += 1
                continue
            }
            var end = i
            while end < chars.count, chars[end] == " " { end += 1 }

            if let before = result.last, end < chars.count,
               Self.shouldJoin(before, chars[end]) {
                // Drop the whole run of spaces.
            } else {
                result.append(contentsOf: chars[i..<end])
            }
            i = end
        }
        return result
    }

    private static func shouldJoin(_ left: Character, _ right: Character) -> Bool {
        (isJapanese(left) && (isJapanese(right) || isSentencePunctuation(right)))
            || (isSentencePunctuation(left) && isJapanese(right))
    }

    private static func isSentencePunctuation(_ c: Character) -> Bool {
        ".,!?;:".contains(c)
    }

    /// Kana (including ー), kanji, CJK/Japanese punctuation, and fullwidth
    /// forms — the characters a Japanese sentence is built from.
    private static func isJapanese(_ c: Character) -> Bool {
        c.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3000...0x303F,   // CJK symbols & punctuation (。、「」)
                 0x3040...0x309F,   // hiragana
                 0x30A0...0x30FF,   // katakana (incl. ー)
                 0x3400...0x4DBF,   // CJK extension A
                 0x4E00...0x9FFF,   // CJK unified ideographs
                 0xFF00...0xFFEF:   // fullwidth forms / halfwidth katakana (！？)
                return true
            default:
                return false
            }
        }
    }
}
