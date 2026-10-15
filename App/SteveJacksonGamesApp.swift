import SwiftUI

@main struct SteveJacksonGamesApp: App {
    @State private var store = AtlasStore()
    var body: some Scene {
        WindowGroup {
            AppShell(store: store).environment(store).preferredColorScheme(.dark).tint(AtlasTheme.gold)
        }
    }
}

struct AppShell: View {
    let store: AtlasStore
    @State private var tab = 0
    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { CatalogView(store: store) }.tabItem { Label("Atlas", systemImage: "square.grid.2x2") }.tag(0)
            NavigationStack { BinderView(store: store) }.tabItem { Label("Binder", systemImage: "rectangle.stack") }.tag(1)
            NavigationStack { TabletopView(store: store) }.tabItem { Label("Tabletop", systemImage: "hand.draw") }.tag(2)
        }
        .toolbarBackground(AtlasTheme.background, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .alert("Archive message", isPresented: Binding(get: { store.issue != nil }, set: { if !$0 { store.issue = nil } })) { Button("OK") { store.issue = nil } } message: { Text(store.issue ?? "") }
    }
}
