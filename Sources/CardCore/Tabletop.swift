import Foundation

/// One physical copy of a catalog card. Multiple copies share a cardID, not an instance ID.
public struct TableCardInstance: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let cardID: String

    public init(id: UUID = UUID(), cardID: String) {
        self.id = id
        self.cardID = cardID
    }
}

public enum CardZone: Codable, Equatable, Sendable {
    case drawPile
    case hand(Int)
    case controlled(Int)
    case neutral
    case discard
    case destroyed
}

public enum TabletopError: Error, Equatable, LocalizedError, Sendable {
    case invalidPlayerCount
    case invalidPlayer(Int)
    case invalidCount
    case unknownCard(UUID)
    case emptyDrawPile
    case cardNotControlled
    case actionAlreadySpent
    case factionCannotBeHidden
    case invalidDieFace

    public var errorDescription: String? {
        switch self {
        case .invalidPlayerCount: "Choose between two and four players."
        case .invalidPlayer: "That player is not at this table."
        case .invalidCount: "The requested card count must be zero or greater."
        case .unknownCard: "That card instance is not at this table."
        case .emptyDrawPile: "There are no cards left to draw."
        case .cardNotControlled: "Only a controlled card can spend an action."
        case .actionAlreadySpent: "This card has already spent its action."
        case .factionCannotBeHidden: "A chosen faction must remain visible. Clear its faction role first."
        case .invalidDieFace: "Each die must show a number from one to six."
        }
    }
}

public struct DiceRoll: Codable, Equatable, Sendable {
    public let die1: Int
    public let die2: Int
    public var total: Int { die1 + die2 }

    public init(die1: Int, die2: Int) throws {
        guard (1...6).contains(die1), (1...6).contains(die2) else {
            throw TabletopError.invalidDieFace
        }
        self.die1 = die1
        self.die2 = die2
    }

    fileprivate init(uncheckedDie1: Int, die2: Int) {
        self.die1 = uncheckedDie1
        self.die2 = die2
    }
}

/// A manual shared-deck sandbox, not an automatic implementation of card abilities.
/// Player indexes are zero based. `turn` is a round and increments when play wraps.
public struct TabletopState: Codable, Equatable, Sendable {
    public private(set) var cards: [TableCardInstance]
    public private(set) var playerCount: Int
    public private(set) var activePlayer: Int
    public private(set) var turn: Int
    public private(set) var drawPile: [UUID]
    public private(set) var hands: [[UUID]]
    public private(set) var controlled: [[UUID]]
    public private(set) var factionRoots: [UUID?]
    public private(set) var neutral: [UUID]
    public private(set) var discard: [UUID]
    public private(set) var destroyed: [UUID]
    public private(set) var spentActions: Set<UUID>
    public private(set) var lastRoll: DiceRoll?
    private var random: SeededTableRandom

    public static func create(
        cardIDs: [String],
        playerCount: Int,
        seed: UInt64,
        openingHandSize: Int = 5,
        neutralCount: Int = 3
    ) throws -> TabletopState {
        guard (2...4).contains(playerCount) else { throw TabletopError.invalidPlayerCount }
        guard openingHandSize >= 0, neutralCount >= 0 else { throw TabletopError.invalidCount }
        var random = SeededTableRandom(seed: seed)
        let cards = cardIDs.map { TableCardInstance(id: random.uuid(), cardID: $0) }
        var pile = cards.map(\.id)
        random.shuffle(&pile)
        var hands = Array(repeating: [UUID](), count: playerCount)
        // Round-robin dealing gives every player the same opportunity if the pile is short.
        for _ in 0..<openingHandSize {
            for player in 0..<playerCount {
                if let card = pile.popLast() { hands[player].append(card) }
            }
        }
        var neutral: [UUID] = []
        for _ in 0..<neutralCount {
            if let card = pile.popLast() { neutral.append(card) }
        }
        return TabletopState(
            cards: cards, playerCount: playerCount, activePlayer: 0, turn: 1,
            drawPile: pile, hands: hands,
            controlled: Array(repeating: [], count: playerCount),
            factionRoots: Array(repeating: nil, count: playerCount),
            neutral: neutral, discard: [], destroyed: [], spentActions: [],
            lastRoll: nil, random: random
        )
    }

    public func instance(_ id: UUID) -> TableCardInstance? {
        cards.first { $0.id == id }
    }

    public func zone(of id: UUID) -> CardZone? {
        if drawPile.contains(id) { return .drawPile }
        for player in 0..<playerCount {
            if hands[player].contains(id) { return .hand(player) }
            if controlled[player].contains(id) { return .controlled(player) }
        }
        if neutral.contains(id) { return .neutral }
        if discard.contains(id) { return .discard }
        if destroyed.contains(id) { return .destroyed }
        return nil
    }

    public func hasAction(_ id: UUID) -> Bool {
        controlled.contains { $0.contains(id) } && !spentActions.contains(id)
    }

    /// Validates the move before changing state. A faction transferred between controlled
    /// zones loses its faction role; visible moves clear the role when it leaves its owner.
    public mutating func move(_ id: UUID, to destination: CardZone) throws {
        guard instance(id) != nil, zone(of: id) != nil else { throw TabletopError.unknownCard(id) }
        try validate(destination)
        if factionRoots.contains(where: { $0 == id }) {
            if case .hand = destination { throw TabletopError.factionCannotBeHidden }
            if case .drawPile = destination { throw TabletopError.factionCannotBeHidden }
        }
        let oldZone = zone(of: id)
        guard oldZone != destination else { return }
        removeFromZones(id)
        switch destination {
        case .drawPile: drawPile.append(id)
        case .hand(let player): hands[player].append(id)
        case .controlled(let player): controlled[player].append(id)
        case .neutral: neutral.append(id)
        case .discard: discard.append(id)
        case .destroyed: destroyed.append(id)
        }
        for player in 0..<playerCount where factionRoots[player] == id {
            if destination != .controlled(player) { factionRoots[player] = nil }
        }
        if case .controlled = destination {
            // An action follows an instance when it is transferred between players.
        } else {
            spentActions.remove(id)
        }
    }

    /// Draws as many as remain. An empty pile returns an empty list, without changing state.
    @discardableResult
    public mutating func draw(count: Int = 1, for player: Int? = nil) throws -> [UUID] {
        let player = player ?? activePlayer
        try validatePlayer(player)
        guard count >= 0 else { throw TabletopError.invalidCount }
        let drawCount = min(count, drawPile.count)
        var drawn: [UUID] = []
        for _ in 0..<drawCount {
            let id = drawPile.removeLast()
            hands[player].append(id)
            drawn.append(id)
        }
        return drawn
    }

    public mutating func reveal(_ id: UUID) throws { try move(id, to: .neutral) }
    public mutating func discardCard(_ id: UUID) throws { try move(id, to: .discard) }
    public mutating func destroyCard(_ id: UUID) throws { try move(id, to: .destroyed) }

    /// Removes a physical copy from the sandbox. Discard/destroy preserve the copy instead.
    public mutating func removeCard(_ id: UUID) throws {
        guard instance(id) != nil else { throw TabletopError.unknownCard(id) }
        removeFromZones(id)
        cards.removeAll { $0.id == id }
        spentActions.remove(id)
        for player in 0..<playerCount where factionRoots[player] == id { factionRoots[player] = nil }
    }

    /// Adds a catalog card copy to this sandbox, useful for choosing a starting faction.
    @discardableResult
    public mutating func addCard(cardID: String, to destination: CardZone) throws -> UUID {
        try validate(destination)
        var id = random.uuid()
        while instance(id) != nil { id = random.uuid() }
        cards.append(TableCardInstance(id: id, cardID: cardID))
        neutral.append(id)
        try move(id, to: destination)
        return id
    }

    /// Classification belongs to the catalog/UI; this method assigns only the visible role.
    public mutating func chooseFaction(_ id: UUID, for player: Int? = nil) throws {
        let player = player ?? activePlayer
        try validatePlayer(player)
        guard instance(id) != nil else { throw TabletopError.unknownCard(id) }
        try move(id, to: .controlled(player))
        // One instance cannot be the root for two players. Replaced roots remain visible.
        for other in 0..<playerCount where factionRoots[other] == id { factionRoots[other] = nil }
        factionRoots[player] = id
    }

    public mutating func clearFaction(for player: Int? = nil) throws {
        let player = player ?? activePlayer
        try validatePlayer(player)
        factionRoots[player] = nil
    }

    public mutating func spendAction(_ id: UUID) throws {
        guard instance(id) != nil else { throw TabletopError.unknownCard(id) }
        guard controlled.contains(where: { $0.contains(id) }) else { throw TabletopError.cardNotControlled }
        guard !spentActions.contains(id) else { throw TabletopError.actionAlreadySpent }
        spentActions.insert(id)
    }

    /// Manual token correction; the turn transition restores only the upcoming player's cards.
    public mutating func restoreAction(_ id: UUID) throws {
        guard instance(id) != nil else { throw TabletopError.unknownCard(id) }
        guard controlled.contains(where: { $0.contains(id) }) else { throw TabletopError.cardNotControlled }
        spentActions.remove(id)
    }

    public mutating func passTurn() {
        activePlayer = (activePlayer + 1) % playerCount
        if activePlayer == 0 { turn += 1 }
        spentActions.subtract(controlled[activePlayer])
        lastRoll = nil
    }

    @discardableResult
    public mutating func rollDice() -> DiceRoll {
        let roll = DiceRoll(uncheckedDie1: random.number(upTo: 6) + 1, die2: random.number(upTo: 6) + 1)
        lastRoll = roll
        return roll
    }

    /// Reorders the remaining pile only; dealt and visible cards stay in their zones.
    public mutating func shuffleDrawPile() { random.shuffle(&drawPile) }

    /// Useful after decoding an external or old save. No card may occupy two zones.
    public var isConsistent: Bool {
        guard (2...4).contains(playerCount), (0..<playerCount).contains(activePlayer), turn >= 1,
              hands.count == playerCount, controlled.count == playerCount,
              factionRoots.count == playerCount else { return false }
        if let lastRoll,
           !(1...6).contains(lastRoll.die1) || !(1...6).contains(lastRoll.die2) { return false }
        let catalogInstances = cards.map(\.id)
        let zones = drawPile + hands.flatMap { $0 } + controlled.flatMap { $0 } + neutral + discard + destroyed
        guard Set(catalogInstances).count == catalogInstances.count,
              Set(zones).count == zones.count,
              Set(zones) == Set(catalogInstances),
              spentActions.isSubset(of: Set(controlled.flatMap { $0 })) else { return false }
        let roots = factionRoots.compactMap { $0 }
        guard Set(roots).count == roots.count else { return false }
        return (0..<playerCount).allSatisfy { player in
            factionRoots[player].map { controlled[player].contains($0) } ?? true
        }
    }

    private func validatePlayer(_ player: Int) throws {
        guard (0..<playerCount).contains(player) else { throw TabletopError.invalidPlayer(player) }
    }

    private func validate(_ zone: CardZone) throws {
        switch zone {
        case .hand(let player), .controlled(let player): try validatePlayer(player)
        default: break
        }
    }

    private mutating func removeFromZones(_ id: UUID) {
        drawPile.removeAll { $0 == id }
        for player in 0..<playerCount {
            hands[player].removeAll { $0 == id }
            controlled[player].removeAll { $0 == id }
        }
        neutral.removeAll { $0 == id }
        discard.removeAll { $0 == id }
        destroyed.removeAll { $0 == id }
    }
}

private struct SeededTableRandom: Codable, Equatable, Sendable {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    // SplitMix64 provides reproducible sandbox setup and rolls across app launches.
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }

    mutating func number(upTo upperBound: Int) -> Int {
        // Rejection sampling avoids modulo bias in both dice rolls and shuffles.
        let bound = UInt64(upperBound)
        let threshold = (0 &- bound) % bound
        var value = next()
        while value < threshold { value = next() }
        return Int(value % bound)
    }

    mutating func shuffle<T>(_ values: inout [T]) {
        guard values.count > 1 else { return }
        for index in stride(from: values.count - 1, through: 1, by: -1) {
            values.swapAt(index, number(upTo: index + 1))
        }
    }

    mutating func uuid() -> UUID {
        let first = next()
        let second = next()
        let bytes = (0..<8).map { UInt8(truncatingIfNeeded: first >> ($0 * 8)) }
            + (0..<8).map { UInt8(truncatingIfNeeded: second >> ($0 * 8)) }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
                           (bytes[6] & 0x0F) | 0x40, bytes[7], (bytes[8] & 0x3F) | 0x80,
                           bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

public enum AttackAlignment: String, CaseIterable, Codable, Identifiable, Sendable {
    case government, corporate, liberal, conservative, peaceful, violent, straight, weird, criminal, fanatic
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }

    public var opposite: AttackAlignment? {
        switch self {
        case .government: .corporate
        case .corporate: .government
        case .liberal: .conservative
        case .conservative: .liberal
        case .peaceful: .violent
        case .violent: .peaceful
        case .straight: .weird
        case .weird: .straight
        case .criminal: nil
        case .fanatic: .fanatic
        }
    }
}

public enum AttackMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case control, destroy
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public struct AttackPreview: Equatable, Sendable {
    public let baseStrength: Int
    public let commonCount: Int
    public let opposedCount: Int
    public let alignmentModifier: Int
    public let manualModifier: Int
    public var strength: Int { baseStrength + alignmentModifier + manualModifier }
    public var requiredRoll: Int { strength < 2 ? 0 : min(strength, 10) }
    public var probability: Double {
        Double((1...6).reduce(0) { total, first in
            total + (1...6).filter { succeeds(total: first + $0) }.count
        }) / 36.0
    }
    public func succeeds(total: Int) -> Bool { (2...10).contains(total) && total <= strength }
    public func succeeds(roll: DiceRoll) -> Bool { succeeds(total: roll.total) }
}

/// Only the core arithmetic is automated. Card abilities, structural defense, aid,
/// interference, and temporary changes must be included in the manual modifier.
public enum AttackCalculator {
    public static func preview(
        power: Int,
        resistance: Int,
        targetPower: Int,
        attackerAlignments: Set<AttackAlignment> = [],
        targetAlignments: Set<AttackAlignment> = [],
        mode: AttackMode = .control,
        modifier: Int = 0
    ) -> AttackPreview {
        let common = attackerAlignments.intersection(targetAlignments).subtracting([.fanatic]).count
        let opposed = attackerAlignments.filter { alignment in
            alignment.opposite.map { targetAlignments.contains($0) } ?? false
        }.count
        let direction = mode == .control ? 1 : -1
        return AttackPreview(
            baseStrength: power - (mode == .control ? resistance : targetPower),
            commonCount: common, opposedCount: opposed,
            alignmentModifier: direction * 4 * (common - opposed), manualModifier: modifier
        )
    }
}

public enum DeckValidationIssue: Equatable, Sendable {
    case incorrectCardCount(expected: Int, actual: Int)
    case missingFaction
    case invalidStartingFaction
    case startingFactionNotInDeck
    case unknownCards([String])

    public var message: String {
        switch self {
        case .incorrectCardCount(let expected, let actual): "Deck has \(actual) cards; a standard constructed deck has \(expected)."
        case .missingFaction: "Add an Faction card to choose a starting faction."
        case .invalidStartingFaction: "The designated starting faction is not an Faction card."
        case .startingFactionNotInDeck: "Include the designated starting faction in the deck."
        case .unknownCards(let ids): "The deck contains \(ids.count) unknown catalog card(s)."
        }
    }
}

public enum CardDeckValidator {
    /// Catalog classification is supplied by the caller. Additional Faction copies are
    /// allowed; validation does not invent restrictions for individual card abilities.
    public static func validate(
        cardIDs: [String],
        factionCardIDs: Set<String>,
        startingFactionID: String? = nil,
        knownCardIDs: Set<String>? = nil,
        targetSize: Int = 45
    ) -> [DeckValidationIssue] {
        var issues: [DeckValidationIssue] = []
        if cardIDs.count != targetSize { issues.append(.incorrectCardCount(expected: targetSize, actual: cardIDs.count)) }
        if !cardIDs.contains(where: factionCardIDs.contains) { issues.append(.missingFaction) }
        if let startingFactionID {
            if !factionCardIDs.contains(startingFactionID) { issues.append(.invalidStartingFaction) }
            if !cardIDs.contains(startingFactionID) { issues.append(.startingFactionNotInDeck) }
        }
        if let knownCardIDs {
            let unknown = Set(cardIDs).subtracting(knownCardIDs).sorted()
            if !unknown.isEmpty { issues.append(.unknownCards(unknown)) }
        }
        return issues
    }
}
