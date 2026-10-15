import SwiftUI
import CardCore
import UniformTypeIdentifiers
import PhotosUI

struct BinderView: View {
    let store: AtlasStore
    @State private var selection = 0
    @State private var newDeck = false
    @State private var name = ""
    @State private var importer = false
    @State private var reviewScans = false
    @State private var scanPhotos: [PhotosPickerItem] = []
    @State private var preparingPhotos = false
    @State private var search = ""
    private var collection: [Card] { store.cards.filter { (selection == 0 ? store.owned($0.id) > 0 : store.favorites.contains($0.id)) && store.matches($0, query: search) } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ArchiveEyebrow(text: "Your collection")
                Text("The private\narchive.").font(.system(size: 38, design: .serif)).foregroundStyle(AtlasTheme.paper)
                ArchivePanel {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) { Text("\(store.ownedTotal) owned entries").font(.headline); Text("\(store.favorites.count) starred · \(store.importedTotal) scans").font(.caption).foregroundStyle(AtlasTheme.muted) }
                        Spacer()
                        Image(systemName: "rectangle.stack.fill").font(.system(size: 27, weight: .light)).foregroundStyle(AtlasTheme.gold)
                    }
                }
                scanImportPanel
                HStack { ArchiveEyebrow(text: "Decks"); Spacer(); Button { name = ""; newDeck = true } label: { Label("New", systemImage: "plus").font(.caption) }.accessibilityIdentifier("new_deck") }
                if store.decks.isEmpty {
                    ArchivePanel { VStack(alignment: .leading, spacing: 12) { Text("Build your first conspiracy.").font(.headline); Text("Create a deck from any card dossier, or start with a 45-card selection and make it your own.").font(.caption).foregroundStyle(AtlasTheme.muted); Button("Make a starter deck") { _ = store.makeStarterDeck() }.buttonStyle(.borderedProminent).accessibilityIdentifier("starter_deck") } }
                } else {
                    ForEach(store.decks) { deck in
                        NavigationLink { DeckEditorView(deckID: deck.id, store: store) } label: {
                            HStack { Image(systemName: "rectangle.stack").font(.title2).foregroundStyle(AtlasTheme.gold); VStack(alignment: .leading, spacing: 6) { Text(deck.name).font(.headline).foregroundStyle(AtlasTheme.paper); Text("\(deck.count) cards · \(deck.quantities.count) different entries").font(.caption).foregroundStyle(AtlasTheme.muted) }; Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(AtlasTheme.gold) }.padding(18).background(AtlasTheme.panel, in: RoundedRectangle(cornerRadius: 16))
                        }.buttonStyle(.plain)
                    }
                }
                ArchiveEyebrow(text: "Binder")
                Picker("Collection", selection: $selection) { Text("Owned").tag(0); Text("Starred").tag(1) }.pickerStyle(.segmented)
                ArchiveSearch(text: $search, placeholder: "Search your binder")
                if collection.isEmpty { ContentUnavailableView(selection == 0 ? "Your binder is waiting" : "No starred cards", systemImage: selection == 0 ? "rectangle.stack" : "star", description: Text("Open a card in the Atlas to track copies or star it.")) }
                LazyVStack(spacing: 12) { ForEach(collection) { card in NavigationLink { CardDetailView(card: card, store: store) } label: { CardListRow(card: card, subtitle: selection == 0 ? "\(store.owned(card.id)) owned · \(card.setName)" : card.setName) }.buttonStyle(.plain) } }

            }.padding(22)
        }.background(AtlasTheme.background).navigationTitle("Binder").navigationBarTitleDisplayMode(.inline)
        .alert("Name your deck", isPresented: $newDeck) { TextField("Deck name", text: $name); Button("Create") { _ = store.addDeck(name: name) }; Button("Cancel", role: .cancel) {} }
        .fileImporter(isPresented: $importer, allowedContentTypes: [.image, .pdf], allowsMultipleSelection: true) { result in do { store.importBatch(try result.get()) } catch { store.importReport = error.localizedDescription } }
        .sheet(isPresented: $reviewScans) { ScanReviewView(store: store) }
        .onChange(of: scanPhotos) { _, photos in
            guard !photos.isEmpty, !preparingPhotos, !store.isImporting else { return }
            preparingPhotos = true
            Task {
                defer { preparingPhotos = false; scanPhotos = [] }
                var files: [URL] = []; var errors: [String] = []
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ScanPhotos-" + UUID().uuidString)
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    for (index, photo) in photos.enumerated() {
                        do {
                            guard let data = try await photo.loadTransferable(type: Data.self) else { throw AtlasStore.ImportError.invalidImage }
                            guard data.count < 25_000_000 else { throw AtlasStore.ImportError.tooLarge }
                            let url = folder.appendingPathComponent("Photo-\(index + 1).img")
                            try data.write(to: url, options: .atomic); files.append(url)
                        } catch { errors.append("Photo \(index + 1): \(error.localizedDescription)") }
                    }
                    if !files.isEmpty { store.importBatch(files, temporaryFolder: folder) }
                    else { store.importReport = errors.joined(separator: "\n"); try? FileManager.default.removeItem(at: folder) }
                    if !errors.isEmpty && !files.isEmpty { store.issue = "Some photos could not be read:\n" + errors.joined(separator: "\n") }
                } catch { store.issue = error.localizedDescription; try? FileManager.default.removeItem(at: folder) }
            }
        }
        .alert("Scan import", isPresented: Binding(get: { store.importReport != nil }, set: { if !$0 { store.importReport = nil } })) { Button("OK") { store.importReport = nil } } message: { Text(store.importReport ?? "") }
    }
    private var scanImportPanel: some View {
                ArchivePanel {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Scan → identify → collect", systemImage: "text.viewfinder").font(.headline)
                        Text("Choose images or a PDF with one card front per page. OCR reads the name, fills catalog metadata, and saves searchable printed text. You don’t need to rename files.").font(.caption).foregroundStyle(AtlasTheme.muted)
                        if preparingPhotos {
                            ProgressView("Loading selected photos…").font(.caption)
                        } else if store.isImporting {
                            ProgressView(value: Double(store.importCompleted), total: Double(max(1, store.importTotal)))
                            Text(store.importStatus).font(.caption).foregroundStyle(AtlasTheme.muted).lineLimit(2)
                            Button("Stop import", role: .cancel) { store.cancelScanImport() }.font(.caption)
                        } else {
                            HStack {
                                Button { importer = true } label: { Label("Files / PDF", systemImage: "folder") }.buttonStyle(.bordered).accessibilityIdentifier("import_scans")
                                PhotosPicker(selection: $scanPhotos, maxSelectionCount: 100, matching: .images) { Label("Photos", systemImage: "photo") }.buttonStyle(.bordered)
                            }
                        }
                        if !store.pendingScans.isEmpty {
                            Button { reviewScans = true } label: { Label("Review \(store.pendingScans.count) scan\(store.pendingScans.count == 1 ? "" : "s")", systemImage: "checkmark.rectangle").frame(maxWidth: .infinity, minHeight: 44) }.buttonStyle(.borderedProminent).accessibilityIdentifier("review_scans")
                            Text("Unclear names, variants, and existing scans are saved for your review.").font(.caption2).foregroundStyle(AtlasTheme.muted)
                        }
                    }
                }
    }
}

struct CardListRow: View {
    let card: Card
    var subtitle: String
    var body: some View { HStack(spacing: 15) { CardFace(card: card, compact: true).frame(width: 57); VStack(alignment: .leading, spacing: 6) { Text(card.name).font(.subheadline.weight(.semibold)).foregroundStyle(AtlasTheme.paper); Text(subtitle).font(.caption).foregroundStyle(AtlasTheme.muted); Text(card.type.uppercased()).font(.system(size: 9, design: .monospaced)).foregroundStyle(AtlasTheme.gold) }; Spacer(minLength: 0) }.padding(12).background(AtlasTheme.panel, in: RoundedRectangle(cornerRadius: 13)) }
}

struct DeckEditorView: View {
    let deckID: UUID
    let store: AtlasStore
    @State private var search = ""
    @State private var showAll = false
    @State private var rename = false
    @State private var name = ""
    @State private var delete = false
    @Environment(\.dismiss) private var dismiss
    private var deck: SavedDeck? { store.deck(deckID) }
    private var cards: [Card] { store.cards.filter { store.matches($0, query: search) && (showAll || !search.isEmpty || (deck?.quantities[$0.id] ?? 0) > 0) } }
    private var factions: Int { store.cards.filter(\.isFaction).reduce(0) { $0 + (deck?.quantities[$1.id] ?? 0) } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ArchivePanel { VStack(alignment: .leading, spacing: 9) { ArchiveEyebrow(text: "Deck composition"); Text("\(deck?.count ?? 0) / 45 cards").font(.system(size: 30, design: .serif)).foregroundStyle(AtlasTheme.paper); Text("\(factions) Faction · \(deck?.quantities.count ?? 0) different entries").font(.caption).foregroundStyle(AtlasTheme.muted); Text(deck?.count == 45 && factions > 0 ? "Standard size with a starting faction. Check printed abilities for card-specific restrictions." : "Standard constructed decks use 45 cards, including a starting Faction. The manual tabletop also accepts custom decks.").font(.caption).foregroundStyle(AtlasTheme.gold) } }
                ArchiveSearch(text: $search, placeholder: "Find cards to add")
                Toggle("Browse all cards", isOn: $showAll).font(.subheadline)
                LazyVStack(spacing: 13) {
                    ForEach(cards) { card in
                        VStack(spacing: 0) {
                            NavigationLink { CardDetailView(card: card, store: store) } label: { CardListRow(card: card, subtitle: card.setName) }.buttonStyle(.plain)
                            HStack { Text("Copies in deck").font(.caption).foregroundStyle(AtlasTheme.muted); Spacer(); Button { store.adjustDeck(deckID, cardID: card.id, by: -1) } label: { Image(systemName: "minus").frame(width: 44, height: 44) }.disabled((deck?.quantities[card.id] ?? 0) == 0).accessibilityLabel("Remove \(card.name) from deck"); Text("\(deck?.quantities[card.id] ?? 0)").monospacedDigit().frame(minWidth: 25); Button { store.adjustDeck(deckID, cardID: card.id, by: 1) } label: { Image(systemName: "plus").frame(width: 44, height: 44) }.accessibilityLabel("Add \(card.name) to deck") }.padding(.horizontal, 12)
                        }.background(AtlasTheme.panel, in: RoundedRectangle(cornerRadius: 13))
                    }
                }
                if cards.isEmpty { ContentUnavailableView("No cards in this view", systemImage: "rectangle.stack", description: Text("Search a name or turn on Browse all cards.")) }
            }.padding(22)
        }.background(AtlasTheme.background).navigationTitle(deck?.name ?? "Deck").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Menu { Button("Rename") { name = deck?.name ?? ""; rename = true }; Button("Delete deck", role: .destructive) { delete = true } } label: { Image(systemName: "ellipsis.circle") } } }
        .alert("Rename deck", isPresented: $rename) { TextField("Name", text: $name); Button("Save") { store.renameDeck(deckID, to: name) }; Button("Cancel", role: .cancel) {} }
        .alert("Delete this deck?", isPresented: $delete) { Button("Delete", role: .destructive) { store.removeDeck(deckID); dismiss() }; Button("Cancel", role: .cancel) {} } message: { Text("Your card scans and binder entries will stay in your collection.") }
    }
}
