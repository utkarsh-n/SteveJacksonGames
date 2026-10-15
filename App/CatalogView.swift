import SwiftUI
import CardCore

struct CatalogView: View {
    let store: AtlasStore
    @State private var search = ""
    @State private var setID = ""
    @State private var type = ""
    @State private var rarity = ""
    @State private var sortByNumber = false
    @State private var showingSources = false
    private var filtered: [Card] {
        let result = store.cards.filter { store.matches($0, query: search) && (setID.isEmpty || $0.setID == setID) && (type.isEmpty || $0.type == type) && (rarity.isEmpty || $0.rarity == rarity) }
        return sortByNumber ? result.sorted { $0.number < $1.number } : result
    }
    private var sets: [(id: String, name: String)] { Dictionary(grouping: store.cards, by: \.setID).map { (id: $0.key, name: $0.value.first!.setName) }.sorted { $0.name < $1.name } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                ArchiveSearch(text: $search)
                filters
                if search.isEmpty && setID.isEmpty && type.isEmpty && rarity.isEmpty { spotlight }
                HStack {
                    ArchiveEyebrow(text: "\(filtered.count) dossiers")
                    Spacer()
                    Menu { Button("Name, A–Z") { sortByNumber = false }; Button("Catalog number") { sortByNumber = true } } label: { Label(sortByNumber ? "Number" : "A–Z", systemImage: "arrow.up.arrow.down").font(.caption) }
                }
                if filtered.isEmpty {
                    ContentUnavailableView("No cards found", systemImage: "magnifyingglass", description: Text("Try another name or clear your filters."))
                    Button("Clear filters and search") { search = ""; setID = ""; type = ""; rarity = "" }.frame(maxWidth: .infinity)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 22) {
                        ForEach(filtered) { card in
                            NavigationLink { CardDetailView(card: card, store: store) } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    CardFace(card: card, compact: true)
                                    Text(card.name).font(.system(size: 13, weight: .semibold)).lineLimit(2).foregroundStyle(.white)
                                    HStack(spacing: 5) {
                                        Text(card.type).font(.system(size: 10, design: .monospaced)).foregroundStyle(AtlasTheme.muted)
                                        Spacer(minLength: 0)
                                        if store.favorites.contains(card.id) { Image(systemName: "star.fill").font(.caption2).foregroundStyle(AtlasTheme.gold) }
                                        if store.owned(card.id) > 0 { Image(systemName: "checkmark.circle.fill").font(.caption2).foregroundStyle(AtlasTheme.gold) }
                                    }
                                }
                            }.buttonStyle(.plain).accessibilityIdentifier("card_" + card.id)
                        }
                    }
                }
                Text("Generic card collection source shell").font(.caption2).foregroundStyle(AtlasTheme.muted).frame(maxWidth: .infinity).padding(.vertical)
            }.padding(.horizontal, 22).padding(.bottom, 20)
        }
        .background(AtlasTheme.background)
        .navigationTitle("Card Atlas").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { showingSources = true } label: { Image(systemName: "book.closed") }.accessibilityLabel("Sources and guide") } }
        .sheet(isPresented: $showingSources) { SourcesView(store: store) }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { ArchiveEyebrow(text: "Card Atlas"); Spacer(); Text("SAMPLE DATA").font(.system(size: 10, design: .monospaced)).foregroundStyle(AtlasTheme.muted) }
            Text("Everything is\nconnected.").font(.system(size: 40, weight: .regular, design: .serif)).tracking(-1).foregroundStyle(AtlasTheme.paper)
            Text("An atlas of sample card collections.").font(.subheadline).foregroundStyle(AtlasTheme.muted)
            HStack(spacing: 24) {
                metric("\(store.cards.count)", "ENTRIES")
                metric("\(sets.count)", "COLLECTIONS")
                metric("\(store.ownedTotal)", "IN YOUR BINDER")
            }.padding(.top, 5)
        }.padding(.top, 16)
    }
    private func metric(_ number: String, _ label: String) -> some View { VStack(alignment: .leading, spacing: 4) { Text(number).font(.system(size: 26, weight: .light, design: .monospaced)).foregroundStyle(AtlasTheme.gold); Text(label).font(.system(size: 8, design: .monospaced)).tracking(1).foregroundStyle(AtlasTheme.muted) } }
    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu { Button("All collections") { setID = "" }; ForEach(sets, id: \.id) { set in Button(set.name) { setID = set.id } } } label: { filterLabel(setID.isEmpty ? "Collection" : sets.first { $0.id == setID }?.name ?? "Collection", active: !setID.isEmpty) }
                Menu { Button("All types") { type = "" }; ForEach(Array(Set(store.cards.map(\.type))).sorted(), id: \.self) { item in Button(item) { type = item } } } label: { filterLabel(type.isEmpty ? "Type" : type, active: !type.isEmpty) }
                Menu { Button("All rarities") { rarity = "" }; ForEach(Array(Set(store.cards.map(\.rarity))).sorted(), id: \.self) { item in Button(item) { rarity = item } } } label: { filterLabel(rarity.isEmpty ? "Rarity" : rarity, active: !rarity.isEmpty) }
                if !setID.isEmpty || !type.isEmpty || !rarity.isEmpty { Button("Reset") { setID = ""; type = ""; rarity = "" }.font(.caption).padding(10) }
            }
        }
    }
    private func filterLabel(_ label: String, active: Bool) -> some View { HStack(spacing: 8) { Text(label); Image(systemName: "chevron.down").font(.system(size: 9)) }.font(.system(size: 12, weight: .medium)).padding(.horizontal, 13).frame(minHeight: 42).background(active ? AtlasTheme.gold.opacity(0.2) : AtlasTheme.panel, in: Capsule()).foregroundStyle(active ? AtlasTheme.gold : AtlasTheme.paper) }
    private var spotlight: some View {
        Button { type = "Faction" } label: {
            HStack(spacing: 15) {
                ZStack { Circle().stroke(AtlasTheme.gold.opacity(0.4)); Image(systemName: "eye").font(.system(size: 28, weight: .ultraLight)).foregroundStyle(AtlasTheme.gold) }.frame(width: 58, height: 58)
                VStack(alignment: .leading, spacing: 6) { ArchiveEyebrow(text: "Example factions"); Text("Meet the Faction").font(.system(size: 20, design: .serif)).foregroundStyle(AtlasTheme.paper); Text("User-defined groups in your own collection.").font(.caption).foregroundStyle(AtlasTheme.muted) }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").foregroundStyle(AtlasTheme.gold)
            }.padding(17).background(AtlasTheme.panel, in: RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(.plain).accessibilityIdentifier("browse_faction")
    }
}
