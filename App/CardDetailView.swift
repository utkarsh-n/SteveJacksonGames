import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import CardCore

struct CardDetailView: View {
    let card: Card
    let store: AtlasStore
    @State private var photo: PhotosPickerItem?
    @State private var importFile = false
    @State private var notes = ""
    @State private var zoom = false
    @State private var scanError: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack { ArchiveEyebrow(text: "Dossier \(String(format: "%03d", card.number))"); Spacer(); Text(card.rarity.uppercased()).font(.system(size: 10, design: .monospaced)).foregroundStyle(AtlasTheme.muted) }
                Button { zoom = true } label: { CardFace(card: card).frame(maxWidth: 295).rotationEffect(.degrees(-1.5)).shadow(color: .black.opacity(0.3), radius: 15, y: 10).frame(maxWidth: .infinity).padding(.vertical, 10) }.buttonStyle(.plain).accessibilityLabel("Enlarge \(card.name)")
                Text(card.name).font(.system(size: 31, weight: .regular, design: .serif)).foregroundStyle(AtlasTheme.paper)
                HStack(spacing: 8) { badge(card.type); badge(card.setName) }
                if let variant = card.variant, !variant.isEmpty { Text(variant).font(.caption).foregroundStyle(AtlasTheme.muted) }
                HStack {
                    Button { store.toggleFavorite(card.id) } label: { Label(store.favorites.contains(card.id) ? "Starred" : "Star card", systemImage: store.favorites.contains(card.id) ? "star.fill" : "star").frame(maxWidth: .infinity, minHeight: 44) }.buttonStyle(.bordered).accessibilityIdentifier("favorite_card")
                    Menu {
                        ForEach(store.decks) { deck in Button("\(deck.name) (\(deck.count))") { store.adjustDeck(deck.id, cardID: card.id, by: 1) } }
                        Button("New deck with this card") { let id = store.addDeck(name: "New conspiracy"); store.adjustDeck(id, cardID: card.id, by: 1) }
                    } label: { Label("Add to deck", systemImage: "plus.rectangle.on.rectangle").frame(maxWidth: .infinity, minHeight: 44) }.buttonStyle(.borderedProminent).accessibilityIdentifier("add_to_deck")
                }.font(.caption)
                ArchivePanel {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) { Text("In your binder").font(.headline); Text("Track your physical copies.").font(.caption).foregroundStyle(AtlasTheme.muted) }
                        Spacer()
                        Button { store.adjustOwned(card.id, by: -1) } label: { Image(systemName: "minus").frame(width: 44, height: 44) }.disabled(store.owned(card.id) == 0).accessibilityLabel("Remove one owned copy")
                        Text("\(store.owned(card.id))").monospacedDigit().frame(minWidth: 24).accessibilityIdentifier("owned_count")
                        Button { store.adjustOwned(card.id, by: 1) } label: { Image(systemName: "plus").frame(width: 44, height: 44) }.accessibilityLabel("Add one owned copy")
                    }
                }
                ArchivePanel {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(store.image(for: card.id) == nil ? "Attach your card scan" : "Your card scan", systemImage: "photo.on.rectangle").font(.headline)
                        Text("Attach an image from your own collection to see its original art and read its printed ability at the table.").font(.caption).foregroundStyle(AtlasTheme.muted)
                        HStack {
                            PhotosPicker(selection: $photo, matching: .images) { Label("Photos", systemImage: "photo") }.buttonStyle(.bordered)
                            Button { importFile = true } label: { Label("Files", systemImage: "folder") }.buttonStyle(.bordered)
                            if store.image(for: card.id) != nil { Button("Remove", role: .destructive) { store.removeArt(card.id) }.font(.caption) }
                        }
                    }
                }
                ArchivePanel {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Your field notes", systemImage: "pencil.line").font(.headline)
                        Text("Record abilities, combinations, and table rulings.").font(.caption).foregroundStyle(AtlasTheme.muted)
                        TextEditor(text: $notes).frame(minHeight: 105).scrollContentBackground(.hidden).font(.body).accessibilityIdentifier("card_notes")
                    }
                }
                if !store.recognizedText(for: card.id).isEmpty {
                    ArchivePanel {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Recognized card text", systemImage: "text.viewfinder").font(.headline)
                            Text("OCR transcription · Check numbers and abilities against your scan.").font(.caption).foregroundStyle(AtlasTheme.muted)
                            Text(store.recognizedText(for: card.id)).font(.subheadline).textSelection(.enabled).accessibilityIdentifier("recognized_card_text")
                        }
                    }
                }
                Link(destination: URL(string: card.sourceURL)!) { HStack { Label("Publisher catalog entry", systemImage: "arrow.up.right.square"); Spacer(); Image(systemName: "chevron.right") }.font(.subheadline).padding(.vertical, 12) }
                Text("The cover shown without an attached scan is an original catalog design. Numerical stats and printed card abilities are not included in the publisher’s card list.").font(.caption2).foregroundStyle(AtlasTheme.muted)
            }.padding(22)
        }.background(AtlasTheme.background).navigationTitle("Card dossier").navigationBarTitleDisplayMode(.inline)
        .onAppear { notes = store.note(card.id) }
        .onChange(of: notes) { _, value in store.setNote(card.id, value) }
        .onChange(of: photo) { _, value in
            guard let value else { return }
            Task {
                do {
                    guard let data = try await value.loadTransferable(type: Data.self) else { throw AtlasStore.ImportError.invalidImage }
                    guard data.count < 25_000_000 else { throw AtlasStore.ImportError.tooLarge }
                    guard let image = UIImage(data: data) else { throw AtlasStore.ImportError.invalidImage }
                    try store.storeImage(image, for: card.id)
                } catch { scanError = error.localizedDescription }
                photo = nil
            }
        }
        .fileImporter(isPresented: $importFile, allowedContentTypes: [.image]) { result in do { try store.importArt(result.get(), for: card.id) } catch { scanError = error.localizedDescription } }
        .sheet(isPresented: $zoom) { CardZoomView(card: card) }
        .alert("Scan import", isPresented: Binding(get: { scanError != nil }, set: { if !$0 { scanError = nil } })) { Button("OK") { scanError = nil } } message: { Text(scanError ?? "") }
        .sensoryFeedback(.selection, trigger: store.favorites.contains(card.id))
    }
    private func badge(_ label: String) -> some View { Text(label).font(.system(size: 10, weight: .medium, design: .monospaced)).padding(.horizontal, 10).padding(.vertical, 8).background(AtlasTheme.panel, in: Capsule()).foregroundStyle(AtlasTheme.gold) }
}

struct CardZoomView: View {
    let card: Card
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @GestureState private var gestureScale: CGFloat = 1
    var body: some View {
        NavigationStack {
            ScrollView([.vertical, .horizontal]) {
                CardFace(card: card).frame(width: 320 * min(4, max(1, scale * gestureScale))).padding(20)
            }.defaultScrollAnchor(.center).background(AtlasTheme.background)
            .gesture(MagnificationGesture().updating($gestureScale) { value, state, _ in state = value }.onEnded { scale = min(4, max(1, scale * $0)) })
            .navigationTitle(card.name).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Reset") { scale = 1 } }; ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}
