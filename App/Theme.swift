import SwiftUI
import CardCore

enum AtlasTheme {
    static let background = Color(red: 0.055, green: 0.075, blue: 0.08)
    static let panel = Color(red: 0.10, green: 0.125, blue: 0.13)
    static let paper = Color(red: 0.91, green: 0.88, blue: 0.79)
    static let ink = Color(red: 0.08, green: 0.11, blue: 0.12)
    static let gold = Color(red: 0.82, green: 0.69, blue: 0.42)
    static let muted = Color(red: 0.62, green: 0.68, blue: 0.66)
    static func accent(for card: Card) -> Color {
        if card.isFaction { return gold }
        if card.isGroup { return Color(red: 0.72, green: 0.29, blue: 0.25) }
        if card.isPlot { return Color(red: 0.30, green: 0.53, blue: 0.70) }
        return Color(red: 0.55, green: 0.43, blue: 0.69)
    }
    static func symbol(for card: Card) -> String {
        let name = card.name.lowercased()
        if card.isFaction { return "eye" }
        if name.contains("computer") || name.contains("internet") || name.contains("hacker") { return "network" }
        if name.contains("nuclear") || name.contains("atomic") { return "atom" }
        if name.contains("earth") || name.contains("world") { return "globe.americas" }
        if name.contains("bank") || name.contains("money") || name.contains("econom") { return "banknote" }
        if name.contains("church") || name.contains("relig") { return "building.columns" }
        if name.contains("satel") || name.contains("orbit") || name.contains("ufo") { return "sparkles" }
        if name.contains("media") || name.contains("television") || name.contains("news") { return "tv" }
        switch card.type {
        case "Place": return "globe.europe.africa"
        case "Personality": return "person.crop.square"
        case "Resource": return "diamond"
        case "Goal": return "scope"
        default: return card.isPlot ? "hand.raised" : "person.3.sequence"
        }
    }
}

struct CardFace: View {
    let card: Card
    var compact = false
    @Environment(AtlasStore.self) private var store
    var body: some View {
        ZStack {
            if let image = store.image(for: card.id) {
                Image(uiImage: image).resizable().scaledToFit().background(AtlasTheme.ink)
            } else {
                VStack(alignment: .leading, spacing: compact ? 7 : 13) {
                    HStack {
                        Text(String(format: "%03d", card.number)).font(.system(size: compact ? 9 : 12, design: .monospaced))
                        Spacer()
                        Image(systemName: "circle.grid.cross").font(.system(size: compact ? 11 : 15))
                    }.foregroundStyle(AtlasTheme.accent(for: card))
                    Text(card.name).font(.system(size: compact ? 13 : 25, weight: .bold, design: .serif)).lineLimit(compact ? 3 : 5).minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                    ZStack {
                        Circle().stroke(AtlasTheme.accent(for: card).opacity(0.2), lineWidth: 1)
                        Circle().inset(by: compact ? 7 : 15).stroke(AtlasTheme.accent(for: card).opacity(0.15), lineWidth: 1)
                        Image(systemName: AtlasTheme.symbol(for: card)).font(.system(size: compact ? 28 : 62, weight: .ultraLight)).foregroundStyle(AtlasTheme.accent(for: card))
                    }.frame(maxWidth: .infinity).aspectRatio(1, contentMode: .fit).padding(.horizontal, compact ? 5 : 15)
                    Spacer(minLength: 0)
                    Rectangle().fill(AtlasTheme.accent(for: card)).frame(height: 2)
                    Text(card.type.uppercased()).font(.system(size: compact ? 9 : 12, weight: .bold, design: .monospaced)).tracking(1).foregroundStyle(AtlasTheme.accent(for: card))
                    if !compact {
                        Text(card.setName + " · " + card.rarity).font(.system(size: 10, design: .monospaced))
                        Text("CATALOG ENTRY").font(.system(size: 8, design: .monospaced)).tracking(2).foregroundStyle(AtlasTheme.ink.opacity(0.55))
                    }
                }.padding(compact ? 11 : 20).foregroundStyle(AtlasTheme.ink).background(AtlasTheme.paper)
            }
        }
        .aspectRatio(0.69, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: compact ? 7 : 13))
        .overlay(RoundedRectangle(cornerRadius: compact ? 7 : 13).stroke(AtlasTheme.gold.opacity(0.25), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(card.name), \(card.type), \(card.setName), \(card.rarity)")
    }
}

struct ArchiveEyebrow: View {
    let text: String
    var body: some View { Text(text.uppercased()).font(.system(size: 11, weight: .medium, design: .monospaced)).tracking(2).foregroundStyle(AtlasTheme.gold) }
}

struct ArchivePanel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { content.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(AtlasTheme.panel, in: RoundedRectangle(cornerRadius: 18)) }
}

struct ArchiveSearch: View {
    @Binding var text: String
    var placeholder = "Search the archive"
    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(AtlasTheme.gold)
            TextField(placeholder, text: $text).autocorrectionDisabled().textInputAutocapitalization(.never).accessibilityIdentifier("card_search")
            if !text.isEmpty { Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Clear search") }
        }.padding(14).background(AtlasTheme.panel, in: RoundedRectangle(cornerRadius: 13)).foregroundStyle(.white)
    }
}
