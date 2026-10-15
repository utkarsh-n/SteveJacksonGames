import Foundation

/// A text observation in normalized image coordinates, with Vision's bottom-left origin.
public struct OCRTextLine: Hashable, Sendable {
    public let text: String
    public let confidence: Double
    public let y: Double
    public let height: Double

    public init(text: String, confidence: Double, y: Double, height: Double) {
        self.text = text
        self.confidence = confidence
        self.y = y
        self.height = height
    }
}

public struct ScanMatchCandidate: Codable, Hashable, Sendable {
    public let cardID: String
    /// A ranking score, not a calibrated probability of correctness.
    public let score: Double

    public init(cardID: String, score: Double) {
        self.cardID = cardID
        self.score = score
    }
}

public struct CardScanMatch: Hashable, Sendable {
    public let candidates: [ScanMatchCandidate]
    public let automaticCardID: String?
    public let recognizedText: String

    public init(candidates: [ScanMatchCandidate], automaticCardID: String?, recognizedText: String) {
        self.candidates = candidates
        self.automaticCardID = automaticCardID
        self.recognizedText = recognizedText
    }
}

/// Finds a catalog identity from card titles. Body text and filenames can offer
/// review suggestions, but never identify a card on their own.
public enum CardScanMatcher {
    public static func match(lines: [OCRTextLine], cards: [Card], filename: String? = nil) -> CardScanMatch {
        let observations = lines.enumerated().compactMap { index, line -> Observation? in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, line.confidence.isFinite, line.y.isFinite, line.height.isFinite,
                  line.height > 0 else { return nil }
            return Observation(text: text, confidence: clamp(line.confidence), y: clamp(line.y),
                               height: clamp(line.height), originalIndex: index)
        }.sorted {
            let firstTop = $0.y + $0.height
            let secondTop = $1.y + $1.height
            return firstTop == secondTop ? $0.originalIndex < $1.originalIndex : firstTop > secondTop
        }
        let recognizedText = observations.map(\.text).joined(separator: "\n")
        let sortedHeights = observations.map(\.height).sorted()
        let medianHeight = sortedHeights.isEmpty ? 0 : sortedHeights[sortedHeights.count / 2]
        let snippets = titleSnippets(from: observations, medianHeight: medianHeight)
        let hint = filename.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent.lowercased() }
        var evidence: [Evidence] = []

        for card in cards {
            let aliases = titleAliases(for: card.name)
            var best: Evidence?
            for snippet in snippets {
                for alias in aliases {
                    guard let similarity = similarity(snippet.normalizedText, alias) else { continue }
                    let score = 0.58 * similarity + 0.22 * snippet.confidence + 0.20 * snippet.titleStrength
                    let item = Evidence(cardID: card.id, title: Card.normalized(card.name), score: score,
                                        canIdentify: snippet.confidence >= 0.86 && snippet.titleStrength >= 0.9
                                            && similarity >= 0.9,
                                        hasFilenameHint: hint == card.id.lowercased())
                    if best == nil || item.score > best!.score { best = item }
                }
            }
            if var best {
                // Stable catalog IDs are useful when the caller deliberately names
                // a file. Camera names such as IMG_0123 are never title guesses.
                if best.hasFilenameHint { best.score = min(1, best.score + 0.04) }
                evidence.append(best)
            } else if hint == card.id.lowercased() {
                evidence.append(Evidence(cardID: card.id, title: Card.normalized(card.name), score: 0.6,
                                         canIdentify: false, hasFilenameHint: true))
            }
        }

        evidence.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.hasFilenameHint != $1.hasFilenameHint { return $0.hasFilenameHint }
            return $0.cardID < $1.cardID
        }
        // Two independently legible titles can indicate a sheet or photo with
        // multiple cards. Let the importer split/crop it before assigning scans.
        let strongTitles = Set(evidence.filter(\.canIdentify).map(\.title))
        var automaticCardID: String?
        if strongTitles.count == 1, let first = evidence.first, first.canIdentify, first.score >= 0.93 {
            let sameTitle = evidence.filter { $0.title == first.title }
            let explicitVariant = sameTitle.count > 1 && first.hasFilenameHint
                && sameTitle.filter(\.hasFilenameHint).count == 1
            let margin = first.score - (evidence.dropFirst().first?.score ?? 0)
            if (sameTitle.count == 1 && margin >= 0.075) || explicitVariant {
                automaticCardID = first.cardID
            }
        }
        return CardScanMatch(candidates: evidence.map { ScanMatchCandidate(cardID: $0.cardID, score: $0.score) },
                             automaticCardID: automaticCardID, recognizedText: recognizedText)
    }

    private struct Observation {
        let text: String
        let confidence: Double
        let y: Double
        let height: Double
        let originalIndex: Int
    }

    private struct Snippet {
        let normalizedText: String
        let confidence: Double
        let titleStrength: Double
    }

    private struct Evidence {
        let cardID: String
        let title: String
        var score: Double
        let canIdentify: Bool
        let hasFilenameHint: Bool
    }

    private static func titleSnippets(from observations: [Observation], medianHeight: Double) -> [Snippet] {
        var result: [Snippet] = []
        for start in observations.indices {
            var group: [Observation] = []
            for end in start..<min(start + 3, observations.count) {
                let line = observations[end]
                if let previous = group.last {
                    let gap = previous.y - (line.y + line.height)
                    let sizeRatio = max(previous.height, line.height) / min(previous.height, line.height)
                    // Stack wrapped title lines, but do not join a title to its
                    // smaller rules text or to distant text below the artwork.
                    guard gap >= -0.008, gap <= max(previous.height, line.height) * 0.8 + 0.008,
                          sizeRatio <= 1.45 else { break }
                }
                group.append(line)
                let text = group.map(\.text).joined(separator: " ")
                let top = group.map { $0.y + $0.height }.max() ?? 0
                let bottom = group.map(\.y).min() ?? 0
                let height = group.map(\.height).min() ?? 0
                let nearTop = top >= 0.74
                let nearBottom = bottom <= 0.15
                let prominent = medianHeight > 0 && height >= medianHeight * 1.35 && height >= 0.025
                let veryProminent = medianHeight > 0 && height >= medianHeight * 1.65 && height >= 0.035
                let titleStrength: Double
                if nearTop && (height >= 0.035 || prominent) {
                    titleStrength = 1
                } else if veryProminent || (nearBottom && prominent) {
                    // Some layouts, rotations and crops put the large title away
                    // from the top. Require strong typographic evidence there.
                    titleStrength = 0.95
                } else if nearTop {
                    titleStrength = 0.55
                } else {
                    titleStrength = 0.15
                }
                result.append(Snippet(normalizedText: Card.normalized(text),
                                      confidence: group.map(\.confidence).min() ?? 0,
                                      titleStrength: titleStrength))
            }
        }
        return result
    }

    private static func titleAliases(for name: String) -> Set<String> {
        var aliases = Set([Card.normalized(name)])
        for prefix in ["NWO:", "Goal:", "NWO-Card:"] where name.hasPrefix(prefix) {
            aliases.insert(Card.normalized(String(name.dropFirst(prefix.count))))
        }
        aliases.remove("")
        return aliases
    }

    private static func similarity(_ observed: String, _ title: String) -> Double? {
        if observed == title { return 1 }
        let length = max(observed.count, title.count)
        // Short names and acronyms are too easy to confuse with other cards,
        // statistics or rules words. Only exact whole-line matches qualify.
        guard min(observed.count, title.count) >= 8 else { return nil }
        let allowedEdits = length >= 18 ? 2 : 1
        guard abs(observed.count - title.count) <= allowedEdits else { return nil }
        let distance = editDistance(observed, title, limit: allowedEdits)
        guard distance <= allowedEdits else { return nil }
        let similarity = 1 - Double(distance) / Double(length)
        return similarity >= 0.9 ? similarity : nil
    }

    private static func editDistance(_ lhs: String, _ rhs: String, limit: Int) -> Int {
        let left = Array(lhs), right = Array(rhs)
        var previous = Array(0...right.count)
        for (row, character) in left.enumerated() {
            var current = Array(repeating: 0, count: right.count + 1)
            current[0] = row + 1
            for column in 1...right.count {
                current[column] = min(current[column - 1] + 1, previous[column] + 1,
                                      previous[column - 1] + (character == right[column - 1] ? 0 : 1))
            }
            if current.min()! > limit { return limit + 1 }
            previous = current
        }
        return previous[right.count]
    }

    private static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
}
