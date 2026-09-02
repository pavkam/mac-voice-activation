enum RecordingTranscriptTail {
    static func format(_ transcript: String, maximumLength: Int = 72) -> String {
        guard transcript.count > maximumLength else { return transcript }
        guard maximumLength > 1 else { return "…" }

        let contentBudget = maximumLength - 2
        let words = transcript.split(whereSeparator: { $0.isWhitespace })
        var visibleWords: [Substring] = []
        var visibleLength = 0

        for word in words.reversed() {
            let candidateLength = visibleLength + word.count + (visibleWords.isEmpty ? 0 : 1)
            guard candidateLength <= contentBudget else { break }

            visibleWords.append(word)
            visibleLength = candidateLength
        }

        guard !visibleWords.isEmpty else {
            return "…" + transcript.suffix(maximumLength - 1)
        }

        return "… " + visibleWords.reversed().joined(separator: " ")
    }
}
