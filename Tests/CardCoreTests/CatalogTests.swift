import Foundation
import XCTest
@testable import CardCore

final class CatalogTests: XCTestCase {
    private var airMagic: Card {
        Card(id: "base-air-magic", number: 5, name: "Example Card A",
             setID: "base", setName: "Original / Unlimited", type: "Plot",
             rarity: "Uncommon", sourceURL: "https://example.invalid/cards",
             variant: "Limited / Unlimited illustration variants")
    }

    func testSearchRequiresEveryTermAcrossNameSetTypeRarityAndVariant() {
        XCTAssertTrue(airMagic.matches("  UNCOMMON\t air \n LIMITED  "))
        XCTAssertTrue(airMagic.matches("magic original plot"))
        XCTAssertFalse(airMagic.matches("air assassins"))
        XCTAssertFalse(airMagic.matches("magic group"))
        XCTAssertTrue(airMagic.matches(" \n\t "))
    }

    func testSearchTreatsCaseAndDiacriticsAsEquivalent() {
        let card = Card(id: "base-bjorne", number: 33, name: "Bjørne",
                        setID: "base", setName: "Original / Unlimited", type: "Personality",
                        rarity: "Common", sourceURL: airMagic.sourceURL)
        XCTAssertTrue(card.matches("BJORNE personálity"))
        XCTAssertTrue(card.matches("bjørne \n COMMON\t original"))
        XCTAssertFalse(card.matches("bjørne resource"))
    }

    func testNormalizedNamesMatchUnicodeCompositionAndPunctuation() {
        XCTAssertEqual(Card.normalized("  Café – Society! \n"), "cafesociety")
        XCTAssertEqual(Card.normalized("CAFE\u{301} Society"), "cafesociety")
        XCTAssertEqual(Card.normalized("Bjørne Øresund"), "bjorneoresund")
        XCTAssertEqual(Card.normalized("Straße"), "strasse")
        XCTAssertEqual(Card.normalized("NWO: Don't Forget To Smash The State"),
                       "nwodontforgettosmashthestate")
        XCTAssertEqual(Card.normalized(" \n\t!"), "")
    }

    func testSavedDeckExpandsRepeatedCopiesAndPreservesUnrelatedQuantities() {
        var deck = SavedDeck(name: "Disaster deck",
                             quantities: ["base-bavarian-faction": 1, "base-nuclear-accident": 2])
        let originalID = deck.id
        deck.adjust("base-nuclear-accident", by: 3)
        XCTAssertEqual(deck.id, originalID)
        XCTAssertEqual(deck.quantities["base-bavarian-faction"], 1)
        XCTAssertEqual(deck.quantities["base-nuclear-accident"], 5)
        XCTAssertEqual(deck.count, 6)
        XCTAssertEqual(deck.cardIDs, ["base-bavarian-faction"]
                       + Array(repeating: "base-nuclear-accident", count: 5))
        deck.adjust("base-nuclear-accident", by: -1)
        XCTAssertEqual(deck.quantities["base-nuclear-accident"], 4)
        XCTAssertEqual(deck.quantities["base-bavarian-faction"], 1)
    }

    func testRemovingFinalCopyDeletesKeyAndCannotCreateNegativeCopies() {
        var deck = SavedDeck(name: "Two cards", quantities: ["base-air-magic": 2, "base-ufos": 1])
        deck.adjust("base-air-magic", by: -2)
        XCTAssertNil(deck.quantities["base-air-magic"])
        XCTAssertEqual(deck.cardIDs, ["base-ufos"])
        deck.adjust("base-air-magic", by: -8)
        XCTAssertNil(deck.quantities["base-air-magic"])
        XCTAssertEqual(deck.count, 1)
        deck.adjust("base-air-magic", by: 1)
        XCTAssertEqual(deck.quantities["base-air-magic"], 1)
        XCTAssertEqual(deck.quantities["base-ufos"], 1)
    }

    func testDeckPersistenceRetainsCopiesAndLaterEditsDoNotAffectSnapshot() throws {
        var deck = SavedDeck(name: "Repeated copies",
                             quantities: ["assassins-backfire": 3, "base-the-network": 1])
        let data = try JSONEncoder().encode(deck)
        let restored = try JSONDecoder().decode(SavedDeck.self, from: data)
        XCTAssertEqual(restored, deck)
        XCTAssertEqual(restored.cardIDs.filter { $0 == "assassins-backfire" }.count, 3)
        deck.adjust("assassins-backfire", by: -3)
        XCTAssertNil(deck.quantities["assassins-backfire"])
        XCTAssertEqual(restored.quantities["assassins-backfire"], 3)
        XCTAssertEqual(restored.count, 4)
    }

    func testCardPersistencePreservesVariantAndAcceptsAbsentVariant() throws {
        let encoded = try JSONEncoder().encode(airMagic)
        let decoded = try JSONDecoder().decode(Card.self, from: encoded)
        XCTAssertEqual(decoded, airMagic)
        let withoutVariant = Card(id: "base-ufos", number: 1, name: "UFOs", setID: "base",
                                  setName: "Original / Unlimited", type: "Faction",
                                  rarity: "Faction", sourceURL: airMagic.sourceURL)
        XCTAssertNil(try JSONDecoder().decode(Card.self, from: JSONEncoder().encode(withoutVariant)).variant)
    }
}
