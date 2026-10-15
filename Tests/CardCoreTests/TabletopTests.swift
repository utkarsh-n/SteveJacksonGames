import Foundation
import XCTest
@testable import CardCore

final class TabletopTests: XCTestCase {
    private func table(count: Int = 30, players: Int = 2, seed: UInt64 = 42) throws -> TabletopState {
        try TabletopState.create(cardIDs: (0..<count).map { "card-\($0)" }, playerCount: players, seed: seed)
    }

    func testSeededSetupAndPhysicalCopies() throws {
        let first = try TabletopState.create(cardIDs: Array(repeating: "same", count: 30), playerCount: 2, seed: 5)
        let second = try TabletopState.create(cardIDs: Array(repeating: "same", count: 30), playerCount: 2, seed: 5)
        XCTAssertEqual(first, second)
        XCTAssertEqual(Set(first.cards.map(\.id)).count, 30)
        XCTAssertEqual(first.hands.map(\.count), [5, 5])
        XCTAssertEqual(first.neutral.count, 3)
        XCTAssertEqual(first.drawPile.count, 17)
        XCTAssertTrue(first.isConsistent)
    }

    func testShortPileDealsRoundRobinAndEmptyDrawIsSafe() throws {
        var state = try table(count: 3, players: 4)
        XCTAssertEqual(state.hands.map(\.count), [1, 1, 1, 0])
        XCTAssertEqual(try state.draw(count: 5), [])
        XCTAssertTrue(state.isConsistent)
    }

    func testOverdrawReturnsOnlyAvailableCopies() throws {
        var state = try table(count: 15)
        let available = state.drawPile.count
        let drawn = try state.draw(count: 100, for: 1)
        XCTAssertEqual(drawn.count, available)
        XCTAssertEqual(state.hands[1].count, 5 + available)
        XCTAssertTrue(state.drawPile.isEmpty)
        XCTAssertTrue(state.isConsistent)
    }

    func testInvalidMovesAreAtomic() throws {
        var state = try table()
        let initial = state
        XCTAssertThrowsError(try state.move(state.hands[0][0], to: .controlled(4)))
        XCTAssertEqual(state, initial)
        XCTAssertThrowsError(try state.move(UUID(), to: .discard))
        XCTAssertEqual(state, initial)
        XCTAssertThrowsError(try state.draw(count: -1))
        XCTAssertEqual(state, initial)
        XCTAssertThrowsError(try state.draw(for: -1))
        XCTAssertEqual(state, initial)
    }

    func testMovesMaintainOneZonePerCopyAndRemoveSpentTokens() throws {
        var state = try table()
        let id = state.hands[0][0]
        try state.move(id, to: .controlled(0))
        XCTAssertEqual(state.zone(of: id), .controlled(0))
        XCTAssertTrue(state.hasAction(id))
        try state.spendAction(id)
        XCTAssertFalse(state.hasAction(id))
        try state.move(id, to: .controlled(1))
        XCTAssertTrue(state.spentActions.contains(id))
        try state.reveal(id)
        XCTAssertEqual(state.zone(of: id), .neutral)
        XCTAssertFalse(state.spentActions.contains(id))
        try state.discardCard(id)
        XCTAssertEqual(state.zone(of: id), .discard)
        try state.destroyCard(id)
        XCTAssertEqual(state.zone(of: id), .destroyed)
        XCTAssertTrue(state.isConsistent)
        try state.removeCard(id)
        XCTAssertNil(state.instance(id))
        XCTAssertNil(state.zone(of: id))
        XCTAssertTrue(state.isConsistent)
    }

    func testTurnReplenishesOnlyUpcomingPlayersControlledCards() throws {
        var state = try table()
        let first = state.hands[0][0]
        let second = state.hands[1][0]
        try state.move(first, to: .controlled(0))
        try state.move(second, to: .controlled(1))
        try state.spendAction(first)
        try state.spendAction(second)
        state.passTurn()
        XCTAssertEqual(state.activePlayer, 1)
        XCTAssertEqual(state.turn, 1)
        XCTAssertTrue(state.spentActions.contains(first))
        XCTAssertFalse(state.spentActions.contains(second))
        state.passTurn()
        XCTAssertEqual(state.activePlayer, 0)
        XCTAssertEqual(state.turn, 2)
        XCTAssertFalse(state.spentActions.contains(first))
        XCTAssertTrue(state.isConsistent)
    }

    func testOnlyControlledCardsCanSpendAndTokenCannotBeSpentTwice() throws {
        var state = try table()
        let id = state.hands[0][0]
        XCTAssertThrowsError(try state.spendAction(id))
        try state.move(id, to: .controlled(0))
        try state.spendAction(id)
        XCTAssertThrowsError(try state.spendAction(id))
        try state.restoreAction(id)
        XCTAssertTrue(state.hasAction(id))
        XCTAssertTrue(state.isConsistent)
    }

    func testFactionsStayVisibleAndClearOnTransferOrRemoval() throws {
        var state = try table()
        let id = state.hands[0][0]
        try state.chooseFaction(id, for: 0)
        XCTAssertEqual(state.factionRoots[0], id)
        XCTAssertEqual(state.zone(of: id), .controlled(0))
        let beforeHiddenMove = state
        XCTAssertThrowsError(try state.move(id, to: .hand(0)))
        XCTAssertEqual(state, beforeHiddenMove)
        XCTAssertThrowsError(try state.move(id, to: .drawPile))
        XCTAssertEqual(state, beforeHiddenMove)
        try state.chooseFaction(id, for: 1)
        XCTAssertNil(state.factionRoots[0])
        XCTAssertEqual(state.factionRoots[1], id)
        XCTAssertTrue(state.isConsistent)
        try state.discardCard(id)
        XCTAssertNil(state.factionRoots[1])
        try state.chooseFaction(id, for: 0)
        try state.clearFaction(for: 0)
        try state.move(id, to: .hand(0))
        XCTAssertTrue(state.isConsistent)
    }

    func testAddCopyAndReplaceFactionDoesNotDuplicateOrLoseOldCopy() throws {
        var state = try table()
        let first = try state.addCard(cardID: "root", to: .controlled(0))
        let second = try state.addCard(cardID: "root", to: .neutral)
        XCTAssertNotEqual(first, second)
        try state.chooseFaction(first)
        try state.chooseFaction(second)
        XCTAssertEqual(state.factionRoots[0], second)
        XCTAssertEqual(state.zone(of: first), .controlled(0))
        XCTAssertTrue(state.isConsistent)
    }

    func testDecodedSnapshotKeepsZonesAndFutureDiceSequence() throws {
        var original = try table()
        let id = original.hands[0][0]
        try original.chooseFaction(id)
        try original.spendAction(id)
        _ = original.rollDice()
        let data = try JSONEncoder().encode(original)
        var restored = try JSONDecoder().decode(TabletopState.self, from: data)
        XCTAssertEqual(original, restored)
        XCTAssertTrue(restored.isConsistent)
        for _ in 0..<20 {
            XCTAssertEqual(original.rollDice(), restored.rollDice())
        }
        restored.passTurn()
        XCTAssertNil(restored.lastRoll)
    }

    func testSeededRollsAreReproducibleAndValid() throws {
        var first = try table(seed: 21)
        var second = try table(seed: 21)
        var totals = Set<Int>()
        for _ in 0..<300 {
            let roll = first.rollDice()
            XCTAssertEqual(roll, second.rollDice())
            XCTAssertTrue((1...6).contains(roll.die1))
            XCTAssertTrue((1...6).contains(roll.die2))
            totals.insert(roll.total)
        }
        XCTAssertEqual(totals, Set(2...12))
        XCTAssertThrowsError(try DiceRoll(die1: 0, die2: 6))
    }

    func testCorruptDecodedDiceCannotPassSaveConsistencyValidation() throws {
        var state = try table()
        _ = state.rollDice()
        let data = try JSONEncoder().encode(state)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["lastRoll"] = ["die1": 0, "die2": 7]
        let corruptData = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(TabletopState.self, from: corruptData)
        XCTAssertFalse(decoded.isConsistent, "The app must reject a restored table with invalid die faces.")
        XCTAssertTrue(state.isConsistent)
    }

    func testShuffleChangesOnlyRemainingPileAndPreservesIdentity() throws {
        var state = try table()
        let hands = state.hands
        let neutral = state.neutral
        let oldPile = state.drawPile
        state.shuffleDrawPile()
        XCTAssertEqual(Set(state.drawPile), Set(oldPile))
        XCTAssertNotEqual(state.drawPile, oldPile)
        XCTAssertEqual(state.hands, hands)
        XCTAssertEqual(state.neutral, neutral)
        XCTAssertTrue(state.isConsistent)
    }

    func testSetupRejectsInvalidConfiguration() {
        XCTAssertThrowsError(try TabletopState.create(cardIDs: [], playerCount: 1, seed: 1))
        XCTAssertThrowsError(try TabletopState.create(cardIDs: [], playerCount: 5, seed: 1))
        XCTAssertThrowsError(try TabletopState.create(cardIDs: [], playerCount: 2, seed: 1, openingHandSize: -1))
        XCTAssertThrowsError(try TabletopState.create(cardIDs: [], playerCount: 2, seed: 1, neutralCount: -1))
    }

    func testAttackArithmeticAndModeReversal() {
        let control = AttackCalculator.preview(power: 6, resistance: 2, targetPower: 3,
            attackerAlignments: [.government, .peaceful], targetAlignments: [.government, .violent])
        XCTAssertEqual(control.commonCount, 1)
        XCTAssertEqual(control.opposedCount, 1)
        XCTAssertEqual(control.alignmentModifier, 0)
        XCTAssertEqual(control.strength, 4)
        let destroy = AttackCalculator.preview(power: 6, resistance: 99, targetPower: 3,
            attackerAlignments: [.peaceful], targetAlignments: [.violent], mode: .destroy, modifier: 2)
        XCTAssertEqual(destroy.baseStrength, 3)
        XCTAssertEqual(destroy.alignmentModifier, 4)
        XCTAssertEqual(destroy.strength, 9)
    }

    func testFanaticIsOpposedToFanaticAndCriminalHasNoOpposite() {
        let preview = AttackCalculator.preview(power: 10, resistance: 2, targetPower: 0,
            attackerAlignments: [.fanatic, .criminal], targetAlignments: [.fanatic, .criminal])
        XCTAssertEqual(preview.commonCount, 1)
        XCTAssertEqual(preview.opposedCount, 1)
        XCTAssertEqual(preview.strength, 8)
        let fanatics = AttackCalculator.preview(power: 10, resistance: 2, targetPower: 0,
            attackerAlignments: [.fanatic], targetAlignments: [.fanatic])
        XCTAssertEqual(fanatics.strength, 4)
        XCTAssertNil(AttackAlignment.criminal.opposite)
    }

    func testExactTwoDiceOddsAndAutomaticFailure() {
        let counts = [0, 0, 1, 3, 6, 10, 15, 21, 26, 30, 33, 33, 33]
        for strength in 0...12 {
            let preview = AttackCalculator.preview(power: strength, resistance: 0, targetPower: 0)
            XCTAssertEqual(preview.probability, Double(counts[strength]) / 36, accuracy: 0.000001)
            XCTAssertFalse(preview.succeeds(total: 11))
            XCTAssertFalse(preview.succeeds(total: 12))
            XCTAssertFalse(preview.succeeds(total: 1))
        }
        let impossible = AttackCalculator.preview(power: 0, resistance: 5, targetPower: 0)
        XCTAssertEqual(impossible.requiredRoll, 0)
        XCTAssertEqual(impossible.probability, 0)
        let maximum = AttackCalculator.preview(power: 100, resistance: 0, targetPower: 0)
        XCTAssertEqual(maximum.requiredRoll, 10)
        XCTAssertEqual(maximum.probability, 33.0 / 36.0)
    }

    func testDeckValidationUsesCatalogClassificationAndAllowsExtraFactionCopies() {
        let cards = ["root", "root"] + Array(repeating: "group", count: 43)
        XCTAssertTrue(CardDeckValidator.validate(cardIDs: cards, factionCardIDs: ["root"],
            startingFactionID: "root", knownCardIDs: ["root", "group"]).isEmpty)
        let issues = CardDeckValidator.validate(cardIDs: ["unknown"], factionCardIDs: ["root"],
            startingFactionID: "not-root", knownCardIDs: ["root"])
        XCTAssertEqual(issues, [.incorrectCardCount(expected: 45, actual: 1), .missingFaction,
                                .invalidStartingFaction, .startingFactionNotInDeck, .unknownCards(["unknown"])])
    }
}
