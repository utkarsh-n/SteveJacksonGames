import Foundation

public struct Card: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let number: Int
    public let name: String
    public let setID: String
    public let setName: String
    public let type: String
    public let rarity: String
    public let sourceURL: String
    public let variant: String?

    public init(id: String, number: Int, name: String, setID: String, setName: String, type: String, rarity: String, sourceURL: String, variant: String? = nil) {
        self.id = id; self.number = number; self.name = name; self.setID = setID; self.setName = setName; self.type = type; self.rarity = rarity; self.sourceURL = sourceURL; self.variant = variant
    }
    public var isFaction: Bool { type == "Faction" }
    public var isGroup: Bool { ["Group", "Personality", "Place"].contains(type) }
    public var isPlot: Bool { ["Plot", "Goal", "Assassination", "Disaster"].contains(type) || type.hasPrefix("NWO") }
    public var searchText: String { [name, setName, type, rarity, variant ?? ""].joined(separator: " ") }
    public func matches(_ query: String) -> Bool {
        let text = searchText
        var normalizedText: String?
        return query.split(whereSeparator: \.isWhitespace).allSatisfy { token in
            let term = String(token)
            if text.localizedStandardContains(term) { return true }
            let normalizedTerm = Self.normalized(term)
            guard !normalizedTerm.isEmpty else { return false }
            // Most searches use the localized match. Fold the full record only
            // once when a term needs the punctuation/transliteration fallback.
            let searchable = normalizedText ?? Self.normalized(text)
            normalizedText = searchable
            return searchable.contains(normalizedTerm)
        }
    }
    public static func normalized(_ name: String) -> String {
        name.replacingOccurrences(of: "ø", with: "o").replacingOccurrences(of: "Ø", with: "O")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
}

public struct SavedDeck: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var quantities: [String: Int]
    public init(id: UUID = UUID(), name: String, quantities: [String: Int] = [:]) { self.id = id; self.name = name; self.quantities = quantities }
    public var count: Int { quantities.values.reduce(0, +) }
    public var cardIDs: [String] { quantities.keys.sorted().flatMap { Array(repeating: $0, count: max(0, quantities[$0, default: 0])) } }
    public mutating func adjust(_ cardID: String, by amount: Int) {
        let count = max(0, min(20, quantities[cardID, default: 0] + amount))
        if count == 0 { quantities.removeValue(forKey: cardID) } else { quantities[cardID] = count }
    }
}
