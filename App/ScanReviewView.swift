import SwiftUI
import UIKit
import CardCore

struct ScanReviewView: View {
    let store: AtlasStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedScan: PendingCardScan?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if store.pendingScans.isEmpty {
                        ContentUnavailableView("All scans reviewed", systemImage: "checkmark.circle", description: Text("Your matched scans are attached to their card dossiers."))
                            .padding(.top, 60)
                    } else {
                        ArchivePanel {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("\(store.pendingScans.count) scan\(store.pendingScans.count == 1 ? "" : "s") to check")
                                    .font(.headline)
                                Text("Choose a card for each uncertain match. These scans stay here until you attach or remove them.")
                                    .font(.subheadline)
                                    .foregroundStyle(AtlasTheme.muted)
                            }
                        }
                        LazyVStack(spacing: 12) {
                            ForEach(store.pendingScans) { scan in
                                Button { selectedScan = scan } label: {
                                    ScanReviewRow(scan: scan, store: store)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("review_scan_\(scan.id.uuidString)")
                            }
                        }
                    }
                }
                .padding(22)
            }
            .background(AtlasTheme.background)
            .navigationTitle("Review scans")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $selectedScan) { scan in
                PendingScanDetailView(scan: scan, store: store)
            }
        }
        .tint(AtlasTheme.gold)
    }
}

private struct ScanReviewRow: View {
    let scan: PendingCardScan
    let store: AtlasStore

    private var suggestion: Card? {
        scan.candidates.first.flatMap { store.card($0.cardID) }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            PendingScanThumbnail(scanID: scan.id, store: store)
                .frame(width: 64, height: 90)
            VStack(alignment: .leading, spacing: 7) {
                Text(scan.fileName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AtlasTheme.paper)
                    .lineLimit(2)
                Text(scan.reason)
                    .font(.caption)
                    .foregroundStyle(AtlasTheme.gold)
                if let card = suggestion {
                    Text("Suggested: \(card.name)")
                        .font(.caption)
                        .foregroundStyle(AtlasTheme.paper)
                    Text(card.setName + (card.variant.map { " · " + $0 } ?? ""))
                        .font(.caption2)
                        .foregroundStyle(AtlasTheme.muted)
                        .lineLimit(2)
                } else {
                    Text("Search the catalog to identify this card.")
                        .font(.caption)
                        .foregroundStyle(AtlasTheme.muted)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AtlasTheme.gold)
                .padding(.top, 4)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AtlasTheme.panel, in: RoundedRectangle(cornerRadius: 15))
        .contentShape(Rectangle())
    }
}

private struct PendingScanThumbnail: View {
    let scanID: UUID
    let store: AtlasStore
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            AtlasTheme.ink
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "photo").foregroundStyle(AtlasTheme.muted)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(AtlasTheme.gold.opacity(0.25)))
        .accessibilityHidden(true)
        .task(id: scanID) { image = store.reviewImage(scanID: scanID) }
    }
}

private struct PendingScanDetailView: View {
    let scan: PendingCardScan
    let store: AtlasStore
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var zoomImage: ReviewScanImage?
    @State private var search = ""
    @State private var browseAll = false
    @State private var replacingCard: Card?
    @State private var removing = false
    @State private var isAttaching = false
    @State private var attachError: String?

    private var suggestedCards: [Card] {
        scan.candidates.compactMap { store.card($0.cardID) }
    }

    private var catalogResults: [Card] {
        store.cards.filter { $0.matches(search) || (!search.isEmpty && $0.id.localizedStandardContains(search)) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    scanPreview
                    ArchivePanel {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(scan.fileName).font(.headline).textSelection(.enabled)
                            Text(scan.reason).font(.subheadline).foregroundStyle(AtlasTheme.gold)
                            Text("Compare the scan with the name, collection, and variant before attaching it.")
                                .font(.caption).foregroundStyle(AtlasTheme.muted)
                        }
                    }
                    if isAttaching {
                        ProgressView("Attaching scan…").frame(maxWidth: .infinity).padding()
                    }
                    if let attachError {
                        Label(attachError, systemImage: "exclamationmark.triangle")
                            .font(.subheadline).foregroundStyle(AtlasTheme.gold)
                    }
                    if !suggestedCards.isEmpty {
                        ArchiveEyebrow(text: "Suggested matches")
                        VStack(spacing: 10) {
                            ForEach(suggestedCards) { card in
                                matchButton(card)
                            }
                        }
                    }
                    catalogSearch
                    ocrText
                    HStack {
                        Button("Keep for later") { dismiss() }
                            .buttonStyle(.bordered)
                        Spacer()
                        Button("Remove scan", role: .destructive) { removing = true }
                            .font(.subheadline)
                    }
                    .disabled(isAttaching)
                }
                .padding(22)
            }
            .background(AtlasTheme.background)
            .navigationTitle("Identify scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.disabled(isAttaching)
                }
            }
            .task(id: scan.id) { image = store.reviewImage(scanID: scan.id) }
            .sheet(item: $zoomImage) { preview in
                ReviewScanZoomView(preview: preview)
            }
            .confirmationDialog("Replace the attached scan?", isPresented: Binding(get: { replacingCard != nil }, set: { if !$0 { replacingCard = nil } }), titleVisibility: .visible, presenting: replacingCard) { card in
                Button("Replace scan for \(card.name)", role: .destructive) {
                    replacingCard = nil
                    attach(to: card)
                }
                Button("Cancel", role: .cancel) { replacingCard = nil }
            } message: { card in
                Text("\(card.name) already has a scan attached. This imported image will replace it.")
            }
            .alert("Remove scan from review?", isPresented: $removing) {
                Button("Remove", role: .destructive) {
                    store.discardPendingScan(scan.id)
                    if !store.pendingScans.contains(where: { $0.id == scan.id }) { dismiss() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The queued copy will be removed from this app. Your original scan file stays where you imported it from.")
            }
            .interactiveDismissDisabled(isAttaching)
        }
        .tint(AtlasTheme.gold)
    }

    @ViewBuilder private var scanPreview: some View {
        if let image {
            Button {
                zoomImage = ReviewScanImage(id: scan.id, image: image, name: scan.fileName)
            } label: {
                VStack(spacing: 8) {
                    Image(uiImage: image)
                        .resizable().scaledToFit()
                        .frame(maxHeight: 390)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    Label("Enlarge scan", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.caption).foregroundStyle(AtlasTheme.gold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Enlarge imported scan, \(scan.fileName)")
        } else {
            ContentUnavailableView("Scan preview unavailable", systemImage: "photo", description: Text("You can still use the recognized text below to identify this card."))
        }
    }

    private var catalogSearch: some View {
        VStack(alignment: .leading, spacing: 12) {
            ArchiveEyebrow(text: "Find in the catalog")
            ArchiveSearch(text: $search, placeholder: "Name, collection, variant, or ID")
            if search.isEmpty {
                Button(browseAll ? "Hide full catalog" : "Browse all \(store.cards.count) entries") {
                    browseAll.toggle()
                }
                .font(.subheadline)
            }
            if !search.isEmpty || browseAll {
                Text("\(catalogResults.count) matching entr\(catalogResults.count == 1 ? "y" : "ies")")
                    .font(.caption).foregroundStyle(AtlasTheme.muted)
                if catalogResults.isEmpty {
                    ContentUnavailableView("No cards found", systemImage: "magnifyingglass", description: Text("Try a shorter name, a collection name, or a catalog ID."))
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(catalogResults) { card in matchButton(card) }
                    }
                }
            }
        }
    }

    private var ocrText: some View {
        ArchivePanel {
            VStack(alignment: .leading, spacing: 10) {
                Label("OCR text (check against scan)", systemImage: "text.viewfinder")
                    .font(.headline)
                Text(scan.recognizedText.isEmpty ? "No readable text was detected. Use the image above to find the card." : scan.recognizedText)
                    .font(.subheadline)
                    .foregroundStyle(scan.recognizedText.isEmpty ? AtlasTheme.muted : AtlasTheme.paper)
                    .textSelection(.enabled)
                Text("OCR may miss symbols, numbers, and small print. This text is a transcription, and card abilities still need to be resolved at the table.")
                    .font(.caption).foregroundStyle(AtlasTheme.muted)
            }
        }
    }

    private func matchButton(_ card: Card) -> some View {
        Button {
            if store.image(for: card.id) != nil {
                replacingCard = card
            } else {
                attach(to: card)
            }
        } label: {
            ScanMatchRow(card: card)
        }
        .buttonStyle(.plain)
        .disabled(isAttaching)
        .accessibilityLabel("Attach scan to \(card.name), \(card.setName), \(card.variant ?? "standard entry"), \(card.id)")
        .accessibilityIdentifier("scan_match_\(card.id)")
    }

    private func attach(to card: Card) {
        guard !isAttaching else { return }
        isAttaching = true
        attachError = nil
        Task {
            await store.resolveScan(scanID: scan.id, cardID: card.id)
            isAttaching = false
            if store.pendingScans.contains(where: { $0.id == scan.id }) {
                attachError = store.issue ?? "The scan could not be attached. Please try again."
            } else {
                dismiss()
            }
        }
    }
}

private struct ScanMatchRow: View {
    let card: Card

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                Text(card.name).font(.subheadline.weight(.semibold)).foregroundStyle(AtlasTheme.paper)
                Text("\(card.type) · \(card.setName)").font(.caption).foregroundStyle(AtlasTheme.muted)
                if let variant = card.variant, !variant.isEmpty {
                    Text(variant).font(.caption).foregroundStyle(AtlasTheme.gold)
                }
                Text(card.id).font(.system(size: 10, design: .monospaced)).foregroundStyle(AtlasTheme.muted)
            }
            Spacer(minLength: 0)
            Label("Attach", systemImage: "checkmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AtlasTheme.gold)
                .padding(.top, 3)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AtlasTheme.panel, in: RoundedRectangle(cornerRadius: 13))
        .contentShape(Rectangle())
    }
}

private struct ReviewScanImage: Identifiable {
    let id: UUID
    let image: UIImage
    let name: String
}

private struct ReviewScanZoomView: View {
    let preview: ReviewScanImage
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @GestureState private var gestureScale: CGFloat = 1

    var body: some View {
        NavigationStack {
            ScrollView([.vertical, .horizontal]) {
                Image(uiImage: preview.image)
                    .resizable().scaledToFit()
                    .frame(width: 320 * min(4, max(1, scale * gestureScale)))
                    .padding(20)
            }
            .defaultScrollAnchor(.center)
            .background(AtlasTheme.background)
            .gesture(MagnificationGesture().updating($gestureScale) { value, state, _ in state = value }.onEnded { scale = min(4, max(1, scale * $0)) })
            .navigationTitle("Imported scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Reset zoom") { scale = 1 } }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .tint(AtlasTheme.gold)
    }
}
