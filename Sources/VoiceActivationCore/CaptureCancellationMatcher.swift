import Foundation

enum CaptureCancellationMatcher {
    private static let cancellationWords: Set<String> = ["cancel", "dismiss", "stop"]

    static func matches(_ transcript: String, isComplete: Bool) -> Bool {
        let words = transcript
            .split(whereSeparator: { !$0.isLetter })
            .map {
                String($0).folding(
                    options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                    locale: Locale(identifier: "en_US_POSIX"))
            }

        if isComplete, words.count == 1, cancellationWords.contains(words[0]) {
            return true
        }

        return zip(words, words.dropFirst()).contains { current, next in
            current == next && cancellationWords.contains(current)
        }
    }
}
