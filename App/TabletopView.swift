import SwiftUI
import CardCore

/// A hot-seat sandbox: the people at the table resolve card abilities using their cards.
struct TabletopView: View {
    let store: AtlasStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var table: TabletopState?
    @State private var undoHistory: [TabletopState] = []
    @State private var handVisible = false
    @State private var didRestore = false
    @State private var sheet: TableSheet?
    @State private var confirmsNewTable = false
    @State private var failure: String?
    @State private var feedback = 0
    @State private var diceFeedback = 0

    private static let rulesURL = URL(string: "https://example.com")!

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                if let table {
                    sessionHeader(table)
                    tableControls(table)
                    privateHand(table)
                    publicTable(table)
                    tableNotes
                } else {
                    emptyTable
                }
            }
            .padding(20)
            .padding(.bottom, 20)
        }
        .background(AtlasTheme.background)
        .navigationTitle("Tabletop")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if table != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Undo last action", systemImage: "arrow.uturn.backward", action: undo)
                            .disabled(undoHistory.isEmpty)
                        Button("New table", systemImage: "plus") {
                            coverPrivateContent()
                            confirmsNewTable = true
                        }
                        Link("Generic tabletop source", destination: Self.rulesURL)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Table options")
                }
            }
        }
        .sheet(item: $sheet) { destination in
            switch destination {
            case .setup:
                TableSetupSheet(store: store, create: startTable)
            case .card(let selection):
                TableCardSheet(selection: selection, store: store, perform: perform)
            case .attack:
                TableAttackSheet(rollDice: rollDice)
            }
        }
        .confirmationDialog("Replace this table?", isPresented: $confirmsNewTable, titleVisibility: .visible) {
            Button("Set up a new table", role: .destructive) { sheet = .setup }
        } message: {
            Text("Dealing a new table replaces the saved game. Your card collection and decks stay saved.")
        }
        .alert("Table action unavailable", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") { failure = nil }
        } message: {
            Text(failure ?? "")
        }
        .sensoryFeedback(.selection, trigger: feedback)
        .sensoryFeedback(.impact(weight: .medium), trigger: diceFeedback)
        .task {
            guard !didRestore else { return }
            didRestore = true
            if let saved = store.loadTable() {
                if saved.isConsistent,
                   saved.cards.allSatisfy({ store.card($0.cardID) != nil }),
                   saved.factionRoots.compactMap({ $0 }).allSatisfy({ definition($0, in: saved)?.isFaction == true }) {
                    table = saved
                } else {
                    failure = "The saved table contains invalid card positions, card references or starting factions. Start a new table to continue."
                }
            }
            handVisible = false
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { coverPrivateContent() }
        }
        .onDisappear { coverPrivateContent() }
    }

    private var emptyTable: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: 42))
                Spacer()
                Text("LOCAL PLAY")
                    .font(.system(.caption, design: .monospaced, weight: .semibold))
                    .tracking(2)
            }
            .foregroundStyle(AtlasTheme.gold)
            Text("Every conspiracy\nneeds a table.")
                .font(.system(size: 36, weight: .bold, design: .serif))
                .foregroundStyle(AtlasTheme.paper)
            Text("Deal a shared card pool for 2–4 people on one iPhone. Pass the phone, reveal your hand, and move cards between visible zones.")
                .font(.body)
                .foregroundStyle(AtlasTheme.muted)
            VStack(alignment: .leading, spacing: 16) {
                setupFeature("hand.raised.fill", "Private hands", "A privacy cover closes each time you pass the turn.")
                setupFeature("circle.grid.2x2.fill", "A tactile card table", "Track controlled groups, action tokens, discards and dice.")
                setupFeature("book.closed.fill", "You resolve the effects", "Use your imported scans and the official rules for card abilities.")
            }
            .padding(18)
            .background(AtlasTheme.panel, in: RoundedRectangle(cornerRadius: 18))
            Button { sheet = .setup } label: {
                Label("Start table", systemImage: "plus.rectangle.on.rectangle")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(AtlasTheme.gold)
            .foregroundStyle(AtlasTheme.ink)
            .accessibilityIdentifier("start_table")
            tableNotes
        }
    }

    private func setupFeature(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(AtlasTheme.gold)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).foregroundStyle(AtlasTheme.paper)
                Text(detail).font(.subheadline).foregroundStyle(AtlasTheme.muted)
            }
        }
    }

    private func sessionHeader(_ state: TabletopState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("ROUND \(state.turn)")
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .tracking(2)
                Spacer()
                Text("\(state.playerCount) PLAYERS")
                    .font(.system(.caption, design: .monospaced))
            }
            .foregroundStyle(AtlasTheme.gold)
            Text("Player \(state.activePlayer + 1)’s turn")
                .font(.system(size: 30, weight: .bold, design: .serif))
                .foregroundStyle(AtlasTheme.paper)
            if let root = state.factionRoots[state.activePlayer], let card = definition(root, in: state) {
                Text(card.name).font(.subheadline).foregroundStyle(AtlasTheme.muted)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func tableControls(_ state: TabletopState) -> some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Button {
                    mutate { try $0.draw(count: 1) }
                } label: {
                    Label("Draw card", systemImage: "rectangle.stack.badge.plus")
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .disabled(state.drawPile.isEmpty)
                .accessibilityIdentifier("draw_card")
                Button {
                    handVisible = false
                    mutate { $0.passTurn() }
                } label: {
                    Label("Pass turn", systemImage: "arrow.right")
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .accessibilityIdentifier("pass_turn")
            }
            .buttonStyle(.borderedProminent)
            .tint(AtlasTheme.gold)
            .foregroundStyle(AtlasTheme.ink)

            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    diceFace(state.lastRoll?.die1)
                    diceFace(state.lastRoll?.die2)
                    Text(state.lastRoll.map { "= \($0.total)" } ?? "2d6")
                        .font(.system(.headline, design: .monospaced))
                        .foregroundStyle(AtlasTheme.paper)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(state.lastRoll.map { "Dice: \($0.die1) and \($0.die2), total \($0.total)" } ?? "Two dice, no roll yet")
                Spacer(minLength: 8)
                Button("Roll dice", systemImage: "dice") { _ = rollDice() }
                    .buttonStyle(.bordered)
                    .tint(AtlasTheme.gold)
                    .accessibilityIdentifier("roll_dice")
            }
            HStack {
                Label("\(state.drawPile.count) left in pool", systemImage: "rectangle.stack")
                Spacer()
                Button("Undo", systemImage: "arrow.uturn.backward", action: undo)
                    .disabled(undoHistory.isEmpty)
                    .accessibilityIdentifier("undo_table")
            }
            .font(.caption)
            .foregroundStyle(AtlasTheme.muted)
        }
        .padding(16)
        .background(AtlasTheme.panel, in: RoundedRectangle(cornerRadius: 18))
    }

    private func diceFace(_ face: Int?) -> some View {
        Image(systemName: face.map { "die.face.\($0).fill" } ?? "square.dashed")
            .font(.system(size: 29))
            .foregroundStyle(AtlasTheme.gold)
            .contentTransition(.symbolEffect(.replace))
            .accessibilityHidden(true)
    }

    private func privateHand(_ state: TabletopState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Your hand", systemImage: handVisible ? "eye" : "eye.slash")
                    .font(.headline)
                Spacer()
                Text("\(state.hands[state.activePlayer].count) cards")
                    .font(.caption.monospaced())
                    .accessibilityIdentifier("active_hand_count")
                if handVisible {
                    Button("Hide") { handVisible = false }
                        .font(.subheadline)
                        .accessibilityIdentifier("hide_hand")
                }
            }
            .foregroundStyle(AtlasTheme.paper)
            if handVisible {
                cardStrip(state.hands[state.activePlayer], state: state, empty: "Your hand is empty. Draw from the shared pool.", destination: .hand(state.activePlayer))
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "hand.raised.slash.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(AtlasTheme.gold)
                    Text("Pass the phone to Player \(state.activePlayer + 1).")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(AtlasTheme.paper)
                        .accessibilityIdentifier("hand_privacy_message")
                    Button("Reveal my hand", systemImage: "eye") {
                        handVisible = true
                        feedback += 1
                    }
                    .buttonStyle(.bordered)
                    .tint(AtlasTheme.gold)
                    .accessibilityIdentifier("reveal_hand")
                }
                .frame(maxWidth: .infinity, minHeight: 175)
                .padding(16)
                .background(AtlasTheme.panel, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private func publicTable(_ state: TabletopState) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text("THE TABLE")
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(AtlasTheme.gold)
                Spacer()
                Button("Attack calculator", systemImage: "plus.forwardslash.minus") { sheet = .attack }
                    .font(.caption)
                    .tint(AtlasTheme.gold)
                    .accessibilityIdentifier("attack_calculator")
            }
            ForEach(0..<state.playerCount, id: \.self) { player in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Circle()
                            .fill(player == state.activePlayer ? AtlasTheme.gold : AtlasTheme.muted)
                            .frame(width: 6, height: 6)
                        Text("Player \(player + 1) · Controlled")
                            .font(.headline)
                        Spacer()
                        Text("\(state.controlled[player].count)")
                            .font(.caption.monospaced())
                    }
                    .foregroundStyle(AtlasTheme.paper)
                    cardStrip(state.controlled[player], state: state, empty: "Tap a card to control it here.", destination: .controlled(player))
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                zoneTitle("Uncontrolled / revealed", count: state.neutral.count)
                cardStrip(state.neutral, state: state, empty: "Reveal cards here for everyone to see.", destination: .neutral)
            }
            DisclosureGroup {
                cardStrip(state.discard, state: state, empty: "No discarded cards.", destination: .discard)
                    .padding(.top, 10)
            } label: {
                zoneTitle("Discard", count: state.discard.count)
            }
            .tint(AtlasTheme.gold)
            DisclosureGroup {
                cardStrip(state.destroyed, state: state, empty: "No destroyed cards.", destination: .destroyed)
                    .padding(.top, 10)
            } label: {
                zoneTitle("Destroyed", count: state.destroyed.count)
            }
            .tint(AtlasTheme.gold)
        }
    }

    private func zoneTitle(_ title: String, count: Int) -> some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            Text("\(count)").font(.caption.monospaced())
        }
        .foregroundStyle(AtlasTheme.paper)
    }

    private func cardStrip(_ ids: [UUID], state: TabletopState, empty: String, destination: CardZone) -> some View {
        Group {
            if ids.isEmpty {
                Text(empty)
                    .font(.subheadline)
                    .foregroundStyle(AtlasTheme.muted)
                    .frame(maxWidth: .infinity, minHeight: 75, alignment: .center)
                    .padding(12)
                    .background(AtlasTheme.panel, in: RoundedRectangle(cornerRadius: 14))
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(ids, id: \.self) { id in
                            if let card = definition(id, in: state) {
                                TableCardTile(card: card, id: id, isFaction: state.factionRoots.contains { $0 == id }, spent: state.spentActions.contains(id), hasToken: state.controlled.contains { $0.contains(id) }) {
                                    sheet = .card(TableCardSelection(id: id, card: card, state: state))
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
            }
        }
        .dropDestination(for: String.self) { strings, _ in
            let ids = strings.compactMap(UUID.init(uuidString:))
            guard !ids.isEmpty else { return false }
            return mutate { state in
                for id in ids { try state.move(id, to: destination) }
            }
        }
    }

    private var tableNotes: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("A shared-deck sandbox")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AtlasTheme.paper)
            Text("Tap a card for moves and action tokens, or drag it into a zone. Card effects, power structures and victory conditions are resolved by the players. Normal constructed sample format uses a separate deck for each player.")
                .font(.caption)
                .foregroundStyle(AtlasTheme.muted)
            Link(destination: Self.rulesURL) {
                Label("Read setup notes", systemImage: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AtlasTheme.gold)
            }
        }
    }

    private func definition(_ id: UUID, in state: TabletopState) -> Card? {
        state.instance(id).flatMap { store.card($0.cardID) }
    }

    private func startTable(_ cardIDs: [String], playerCount: Int, factionIDs: [String]) throws {
        guard factionIDs.count == playerCount, Set(factionIDs).count == playerCount,
              factionIDs.allSatisfy({ store.card($0)?.isFaction == true }),
              Set(factionIDs.compactMap { store.card($0)?.name }).count == playerCount else {
            throw TableSetupError.missingFactions
        }
        guard cardIDs.allSatisfy({ store.card($0) != nil }) else { throw TableSetupError.unknownCards }
        let playableIDs = cardIDs.filter { store.card($0).map { !$0.isFaction } == true }
        guard playableIDs.count >= playerCount * 5 else { throw TableSetupError.insufficientCards(playerCount * 5) }
        let seed = UInt64.random(in: UInt64.min...UInt64.max)
        var state = try TabletopState.create(cardIDs: playableIDs, playerCount: playerCount, seed: seed, neutralCount: 0)
        for player in 0..<playerCount {
            let id = try state.addCard(cardID: factionIDs[player], to: .controlled(player))
            try state.chooseFaction(id, for: player)
        }
        table = state
        handVisible = false
        undoHistory.removeAll()
        store.saveTable(state)
        feedback += 1
    }

    @discardableResult
    private func mutate(_ operation: (inout TabletopState) throws -> Void) -> Bool {
        guard var state = table else { return false }
        let previous = state
        do {
            try operation(&state)
            guard state != previous else { return true }
            undoHistory.append(previous)
            if undoHistory.count > 20 { undoHistory.removeFirst() }
            table = state
            store.saveTable(state)
            feedback += 1
            return true
        } catch {
            failure = error.localizedDescription
            return false
        }
    }

    private func coverPrivateContent() {
        handVisible = false
        if case .card(let selection)? = sheet,
           case .hand(_)? = selection.state.zone(of: selection.id) {
            // A selected private card can also be visible in its nested dossier or zoom.
            // Dismiss the entire card presentation before handing the phone back.
            sheet = nil
        }
    }

    private func undo() {
        guard let previous = undoHistory.popLast() else { return }
        handVisible = false
        sheet = nil
        table = previous
        store.saveTable(previous)
        feedback += 1
    }

    private func rollDice() -> DiceRoll? {
        mutate { _ = $0.rollDice() }
        diceFeedback += 1
        return table?.lastRoll
    }

    private func perform(_ action: TableCardAction, id: UUID) {
        mutate { state in
            switch action {
            case .move(let zone): try state.move(id, to: zone)
            case .spend: try state.spendAction(id)
            case .restore: try state.restoreAction(id)
            }
        }
    }
}

private enum TableSheet: Identifiable {
    case setup
    case card(TableCardSelection)
    case attack

    var id: String {
        switch self {
        case .setup: "setup"
        case .card(let selection): selection.id.uuidString
        case .attack: "attack"
        }
    }
}

private struct TableCardSelection: Identifiable {
    let id: UUID
    let card: Card
    let state: TabletopState
}

private enum TableCardAction {
    case move(CardZone)
    case spend
    case restore
}

private enum TableSetupError: LocalizedError {
    case missingFactions
    case insufficientCards(Int)
    case unknownCards
    var errorDescription: String? {
        switch self {
        case .missingFactions: "Choose a different Faction faction for each player."
        case .insufficientCards(let minimum): "This shared pool needs at least \(minimum) non-faction cards for the opening hands. Add cards to your deck or choose the whole archive."
        case .unknownCards: "This deck references cards outside the current archive. Edit the deck or choose the whole archive before dealing."
        }
    }
}

private struct TableCardTile: View {
    let card: Card
    let id: UUID
    let isFaction: Bool
    let spent: Bool
    let hasToken: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 7) {
                CardFace(card: card, compact: true)
                    .frame(width: 104)
                    .opacity(spent ? 0.6 : 1)
                    .overlay(alignment: .topTrailing) {
                        if hasToken {
                            Image(systemName: spent ? "circle" : "circle.inset.filled")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(spent ? AtlasTheme.muted : AtlasTheme.gold)
                                .padding(6)
                                .background(AtlasTheme.background.opacity(0.9), in: Circle())
                                .padding(5)
                        }
                    }
                Text(card.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AtlasTheme.paper)
                    .lineLimit(2)
                    .frame(height: 31, alignment: .topLeading)
                if isFaction || hasToken {
                    Text(isFaction ? "ILLUMINATI" : (spent ? "ACTION SPENT" : "ACTION READY"))
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .tracking(0.7)
                        .foregroundStyle(AtlasTheme.gold)
                }
            }
            .frame(width: 104, alignment: .leading)
        }
        .buttonStyle(.plain)
        .draggable(id.uuidString)
        .accessibilityLabel("\(card.name)\(isFaction ? ", starting faction" : "")\(hasToken ? (spent ? ", action spent" : ", action ready") : "")")
        .accessibilityHint("Opens card actions. You can also drag this card to a zone.")
        .accessibilityIdentifier("table_card_\(card.id)")
    }
}

private struct TableSetupSheet: View {
    let store: AtlasStore
    let create: ([String], Int, [String]) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var playerCount = 2
    @State private var deckID = "archive"
    @State private var factions: [String] = []
    @State private var error: String?

    private var factionCards: [Card] { store.cards.filter(\.isFaction) }
    private var pool: [String] {
        guard let id = UUID(uuidString: deckID), let deck = store.deck(id) else { return store.cards.map(\.id) }
        return deck.cardIDs
    }
    private var poolCount: Int { pool.filter { store.card($0).map { !$0.isFaction } == true }.count }
    private var hasUnknownCards: Bool { pool.contains { store.card($0) == nil } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Players", selection: $playerCount) {
                        ForEach(2...4, id: \.self) { Text("\($0) players").tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("One iPhone · local hot-seat")
                }
                Section {
                    Picker("Card pool", selection: $deckID) {
                        Text("Whole indexed archive").tag("archive")
                        ForEach(store.decks) { deck in
                            Text("\(deck.name) · \(deck.count) cards").tag(deck.id.uuidString)
                        }
                    }
                    LabeledContent("Cards in draw pool", value: "\(poolCount)")
                    LabeledContent("Opening hand", value: "5 each")
                    if hasUnknownCards {
                        Text("This deck references cards outside the current archive. Edit the deck or choose the whole archive before dealing.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if poolCount < playerCount * 5 {
                        Text("Add at least \(playerCount * 5 - poolCount) more non-faction cards to deal five cards to each player.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Shared pool")
                } footer: {
                    Text("This is a shared-deck learning sandbox. The selected starting factions stay face up and all other faction cards are excluded from the draw pool. Standard constructed sample format uses separate player decks.")
                }
                Section {
                    ForEach(0..<playerCount, id: \.self) { player in
                        Picker("Player \(player + 1)", selection: factionBinding(player)) {
                            Text("Choose a faction").tag("")
                            ForEach(availableFactions(for: player)) { card in
                                Text("\(card.name)\(card.variant.map { " · \($0)" } ?? "") · \(card.setName)").tag(card.id)
                            }
                        }
                        .accessibilityIdentifier("player_\(player + 1)_faction")
                    }
                } header: {
                    Text("Starting Faction")
                } footer: {
                    Text("Choose one different faction per player. Each starts in that player’s controlled area.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
                Section {
                    Button {
                        do {
                            try create(pool, playerCount, Array(factions.prefix(playerCount)))
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    } label: {
                        Label("Deal the table", systemImage: "rectangle.stack.badge.plus")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .tint(AtlasTheme.gold)
                    .disabled(factions.count < playerCount || factions.prefix(playerCount).contains("") || poolCount < playerCount * 5 || hasUnknownCards)
                    .accessibilityIdentifier("deal_table")
                }
            }
            .navigationTitle("Set up a table")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .scrollContentBackground(.hidden)
            .background(AtlasTheme.background)
            .onAppear { prepareFactions() }
            .onChange(of: playerCount) { _, _ in prepareFactions() }
        }
        .presentationDragIndicator(.visible)
    }

    private func factionBinding(_ player: Int) -> Binding<String> {
        Binding(get: { factions.indices.contains(player) ? factions[player] : "" }, set: { value in
            while factions.count <= player { factions.append("") }
            factions[player] = value
        })
    }

    private func availableFactions(for player: Int) -> [Card] {
        let used = Set(factions.prefix(playerCount).enumerated().filter { $0.offset != player }.compactMap { store.card($0.element)?.name })
        return factionCards.filter { !used.contains($0.name) }
    }

    private func prepareFactions() {
        while factions.count < 4 { factions.append("") }
        var usedNames = Set<String>()
        for player in 0..<4 {
            if let selected = store.card(factions[player]), selected.isFaction, !usedNames.contains(selected.name) {
                usedNames.insert(selected.name)
            } else {
                let next = factionCards.first { !usedNames.contains($0.name) }
                factions[player] = next?.id ?? ""
                if let next { usedNames.insert(next.name) }
            }
        }
    }
}

private struct TableCardSheet: View {
    let selection: TableCardSelection
    let store: AtlasStore
    let perform: (TableCardAction, UUID) -> Void
    @Environment(\.dismiss) private var dismiss

    private var state: TabletopState { selection.state }
    private var isRoot: Bool { state.factionRoots.contains { $0 == selection.id } }
    private var isControlled: Bool { state.controlled.contains { $0.contains(selection.id) } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    CardFace(card: selection.card)
                        .frame(width: 195)
                        .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(selection.card.name)
                            .font(.system(.title2, design: .serif, weight: .bold))
                            .foregroundStyle(AtlasTheme.paper)
                        Text("\(selection.card.type) · \(selection.card.setName)")
                            .font(.subheadline)
                            .foregroundStyle(AtlasTheme.muted)
                    }
                    VStack(spacing: 12) {
                        actionButton("Control for Player \(state.activePlayer + 1)", icon: "person.crop.square", action: .move(.controlled(state.activePlayer)))
                            .disabled(state.zone(of: selection.id) == .controlled(state.activePlayer))
                        actionButton("Reveal on table", icon: "eye", action: .move(.neutral))
                            .disabled(state.zone(of: selection.id) == .neutral)
                        if isControlled {
                            actionButton(state.spentActions.contains(selection.id) ? "Restore action token" : "Spend action token", icon: state.spentActions.contains(selection.id) ? "circle.inset.filled" : "circle", action: state.spentActions.contains(selection.id) ? .restore : .spend)
                        }
                        Menu {
                            ForEach(0..<state.playerCount, id: \.self) { player in
                                Button("Player \(player + 1)’s controlled area") { act(.move(.controlled(player))) }
                                Button("Player \(player + 1)’s hand") { act(.move(.hand(player))) }
                                    .disabled(isRoot)
                            }
                            Button("Top of draw pool") { act(.move(.drawPile)) }.disabled(isRoot)
                        } label: {
                            Label("Move to another zone", systemImage: "arrow.left.arrow.right")
                                .frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .buttonStyle(.bordered)
                        .tint(AtlasTheme.gold)
                        HStack(spacing: 12) {
                            actionButton("Discard", icon: "tray", action: .move(.discard))
                                .disabled(state.zone(of: selection.id) == .discard)
                            actionButton("Destroy", icon: "flame", action: .move(.destroyed))
                                .disabled(state.zone(of: selection.id) == .destroyed)
                        }
                    }
                    if isRoot {
                        Text("This is a starting Faction faction. It stays visible; moving it out of its controlled area clears its starting-faction role.")
                            .font(.caption)
                            .foregroundStyle(AtlasTheme.muted)
                    }
                    if store.image(for: selection.card.id) == nil {
                        Text("Import a scan from the card’s archive page to read its artwork and full effect text here.")
                            .font(.caption)
                            .foregroundStyle(AtlasTheme.muted)
                    }
                    NavigationLink {
                        CardDetailView(card: selection.card, store: store)
                    } label: {
                        Label("Open card dossier", systemImage: "rectangle.stack")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(AtlasTheme.gold)
                    if let url = URL(string: selection.card.sourceURL) {
                        Link("Official card checklist", destination: url)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AtlasTheme.gold)
                    }
                }
                .padding(20)
            }
            .background(AtlasTheme.background)
            .navigationTitle("Card actions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDragIndicator(.visible)
    }

    private func actionButton(_ title: String, icon: String, action: TableCardAction) -> some View {
        Button { act(action) } label: {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.bordered)
        .tint(AtlasTheme.gold)
    }

    private func act(_ action: TableCardAction) {
        perform(action, selection.id)
        dismiss()
    }
}

private struct TableAttackSheet: View {
    let rollDice: () -> DiceRoll?
    @Environment(\.dismiss) private var dismiss
    @State private var mode: AttackMode = .control
    @State private var power = 0
    @State private var resistance = 0
    @State private var targetPower = 0
    @State private var modifier = 0
    @State private var attackerAlignments: Set<AttackAlignment> = []
    @State private var targetAlignments: Set<AttackAlignment> = []
    @State private var roll: DiceRoll?

    private var preview: AttackPreview {
        AttackCalculator.preview(power: power, resistance: resistance, targetPower: targetPower, attackerAlignments: attackerAlignments, targetAlignments: targetAlignments, mode: mode, modifier: modifier)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Attack", selection: $mode) {
                        ForEach(AttackMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Stepper("Attacking Power: \(power)", value: $power, in: 0...99)
                    if mode == .control {
                        Stepper("Target Resistance: \(resistance)", value: $resistance, in: 0...99)
                    } else {
                        Stepper("Target Power: \(targetPower)", value: $targetPower, in: 0...99)
                    }
                    Stepper("Other modifiers: \(modifier > 0 ? "+" : "")\(modifier)", value: $modifier, in: -99...99)
                } header: {
                    Text("Numbers from your cards")
                } footer: {
                    Text("Enter the current printed or modified values yourself. Include defensive position, aid, interference, special abilities and temporary effects in Other modifiers.")
                }
                Section("Alignments") {
                    DisclosureGroup("Attacker · \(attackerAlignments.count) selected") {
                        alignmentChoices($attackerAlignments)
                    }
                    DisclosureGroup("Target · \(targetAlignments.count) selected") {
                        alignmentChoices($targetAlignments)
                    }
                    LabeledContent("Common alignments", value: "\(preview.commonCount)")
                    LabeledContent("Opposed alignments", value: "\(preview.opposedCount)")
                    LabeledContent("Alignment modifier", value: signed(preview.alignmentModifier))
                }
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(preview.requiredRoll == 0 ? "No successful roll" : "Roll \(preview.requiredRoll) or less")
                            .font(.system(.title2, design: .serif, weight: .bold))
                            .foregroundStyle(AtlasTheme.gold)
                        Text("\(Int((preview.probability * 100).rounded()))% chance on two six-sided dice")
                            .font(.subheadline)
                        Text("Strength \(preview.strength) = base \(preview.baseStrength) \(signed(preview.alignmentModifier)) alignments \(signed(preview.manualModifier)) other")
                            .font(.caption.monospaced())
                            .foregroundStyle(AtlasTheme.muted)
                        Text("11 and 12 always fail.")
                            .font(.caption)
                            .foregroundStyle(AtlasTheme.muted)
                    }
                    .padding(.vertical, 8)
                    Button("Roll 2 dice", systemImage: "dice") { roll = rollDice() }
                        .tint(AtlasTheme.gold)
                        .accessibilityIdentifier("attack_roll_dice")
                    if let roll {
                        let succeeds = preview.succeeds(roll: roll)
                        Label("\(roll.die1) + \(roll.die2) = \(roll.total) · \(succeeds ? "Success" : "Failure")", systemImage: succeeds ? "checkmark.circle" : "xmark.circle")
                            .font(.headline)
                            .foregroundStyle(succeeds ? Color.green : Color.orange)
                    }
                } header: {
                    Text("Core attack arithmetic")
                } footer: {
                    Text("This helper does not resolve card abilities or move cards. Confirm all modifiers with the official rules and the cards in play.")
                }
            }
            .navigationTitle("Attack calculator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .scrollContentBackground(.hidden)
            .background(AtlasTheme.background)
        }
        .presentationDragIndicator(.visible)
    }

    private func alignmentChoices(_ selected: Binding<Set<AttackAlignment>>) -> some View {
        ForEach(AttackAlignment.allCases) { alignment in
            Toggle(alignment.title, isOn: Binding(get: { selected.wrappedValue.contains(alignment) }, set: { enabled in
                if enabled { selected.wrappedValue.insert(alignment) } else { selected.wrappedValue.remove(alignment) }
            }))
            .tint(AtlasTheme.gold)
        }
    }

    private func signed(_ number: Int) -> String { number >= 0 ? "+\(number)" : "−\(abs(number))" }
}
