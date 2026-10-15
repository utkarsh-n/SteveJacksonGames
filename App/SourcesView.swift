import SwiftUI
import CardCore

struct SourcesView: View {
    let store: AtlasStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ArchiveEyebrow(text: "Source shell")
                    Text("Your collection.\nYour data.").font(.system(size: 35, design: .serif)).foregroundStyle(AtlasTheme.paper)
                    ArchivePanel {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("An empty catalog by design").font(.headline)
                            Text("This public source snapshot supplies no publisher catalog, card artwork or rules. Supply metadata and original artwork that you have permission to use. Catalog search and OCR identification require that dataset.")
                                .font(.subheadline).foregroundStyle(AtlasTheme.muted)
                            Text("\(store.cards.count) loaded entries").font(.caption)
                        }
                    }
                    ArchivePanel {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Local collection tools").font(.headline)
                            Text("The source demonstrates a searchable atlas, binder notes, user-supplied scans, generic OCR matching and a manual tabletop. Data is stored locally. No account is bundled.")
                                .font(.subheadline).foregroundStyle(AtlasTheme.muted)
                        }
                    }
                    Text("See PUBLICATION.md and README.md for excluded resources and setup. This source shell is not a complete implementation of a publisher’s game and grants no license to third-party content.")
                        .font(.caption).foregroundStyle(AtlasTheme.muted)
                }.padding(22)
            }.background(AtlasTheme.background).navigationTitle("Sources & guide").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}
