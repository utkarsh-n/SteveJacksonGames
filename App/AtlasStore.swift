import SwiftUI
import Observation
import CardCore
import UIKit

struct PendingCardScan: Codable, Identifiable, Sendable {
    let id: UUID
    let fileName: String
    let candidates: [ScanMatchCandidate]
    let recognizedText: String
    let reason: String
}

private struct UserLibrary: Codable {
    var favorites: Set<String> = []
    var owned: [String: Int] = [:]
    var notes: [String: String] = [:]
    var decks: [SavedDeck] = []
}

@MainActor @Observable final class AtlasStore {
    private(set) var cards: [Card] = []
    private var library = UserLibrary()
    var issue: String?
    var importReport: String?
    private(set) var pendingScans: [PendingCardScan] = []
    private(set) var isImporting = false
    private(set) var importCompleted = 0
    private(set) var importTotal = 0
    private(set) var importStatus = ""
    private(set) var scanRevision = 0
    private(set) var artRevision = 0
    @ObservationIgnored private let imageCache = NSCache<NSString, UIImage>()
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var byID: [String: Card] = [:]
    @ObservationIgnored private var ocrCache: [String: String] = [:]
    @ObservationIgnored private var cardsWithText: Set<String> = []
    @ObservationIgnored private var batchTask: Task<Void, Never>?

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("CardAtlas", isDirectory: true)
        imageCache.countLimit = 60
        do {
            for folder in ["Art", "OCR", "PendingScans"] { try FileManager.default.createDirectory(at: self.directory.appendingPathComponent(folder), withIntermediateDirectories: true) }
            guard let url = Bundle.main.url(forResource: "cards", withExtension: "json") else { throw CocoaError(.fileNoSuchFile) }
            cards = try JSONDecoder().decode([Card].self, from: Data(contentsOf: url)).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            byID = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
            let saved = self.directory.appendingPathComponent("library.json")
            if FileManager.default.fileExists(atPath: saved.path) { library = try JSONDecoder().decode(UserLibrary.self, from: Data(contentsOf: saved)) }
            cardsWithText = Set((try FileManager.default.contentsOfDirectory(atPath: self.directory.appendingPathComponent("OCR").path)).filter { $0.hasSuffix(".txt") }.map { String($0.dropLast(4)) })
            let queue = self.directory.appendingPathComponent("scanqueue.json")
            if FileManager.default.fileExists(atPath: queue.path) { pendingScans = try JSONDecoder().decode([PendingCardScan].self, from: Data(contentsOf: queue)) }
        } catch { issue = "The archive could not be loaded: \(error.localizedDescription)" }
    }
    var decks: [SavedDeck] { library.decks }
    var favorites: Set<String> { library.favorites }
    var ownedTotal: Int { library.owned.values.filter { $0 > 0 }.count }
    var importedTotal: Int { (try? FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Art").path).count) ?? 0 }
    func card(_ id: String) -> Card? { byID[id] }
    func owned(_ id: String) -> Int { library.owned[id, default: 0] }
    func note(_ id: String) -> String { library.notes[id, default: ""] }
    func toggleFavorite(_ id: String) { if !library.favorites.insert(id).inserted { library.favorites.remove(id) }; save() }
    func adjustOwned(_ id: String, by amount: Int) { library.owned[id] = max(0, min(99, owned(id) + amount)); save() }
    func setNote(_ id: String, _ text: String) { library.notes[id] = text; save() }
    func addDeck(name: String) -> UUID { let deck = SavedDeck(name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled deck" : name); library.decks.append(deck); save(); return deck.id }
    func removeDeck(_ id: UUID) { library.decks.removeAll { $0.id == id }; save() }
    func deck(_ id: UUID) -> SavedDeck? { library.decks.first { $0.id == id } }
    func adjustDeck(_ id: UUID, cardID: String, by amount: Int) { guard let i = library.decks.firstIndex(where: { $0.id == id }) else { return }; library.decks[i].adjust(cardID, by: amount); save() }
    func renameDeck(_ id: UUID, to name: String) { guard let i = library.decks.firstIndex(where: { $0.id == id }), !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }; library.decks[i].name = name; save() }
    func makeStarterDeck() -> UUID {
        var deck = SavedDeck(name: "First conspiracy")
        let faction = cards.first { $0.name == "Bavarian Faction" && $0.isFaction } ?? cards.first { $0.isFaction }
        if let faction { deck.adjust(faction.id, by: 1) }
        for card in cards.filter({ $0.setID == "base" && $0.isGroup }).prefix(16) { deck.adjust(card.id, by: 1) }
        for card in cards.filter({ $0.setID == "base" && $0.isPlot }).prefix(28) { deck.adjust(card.id, by: 1) }
        library.decks.append(deck); save(); return deck.id
    }
    func image(for cardID: String) -> UIImage? {
        _ = artRevision
        if let image = imageCache.object(forKey: cardID as NSString) { return image }
        guard let image = UIImage(contentsOfFile: artURL(cardID).path) else { return nil }
        imageCache.setObject(image, forKey: cardID as NSString); return image
    }
    func importArt(_ url: URL, for cardID: String) throws {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size < 25_000_000 else { throw ImportError.tooLarge }
        guard let image = UIImage(data: try Data(contentsOf: url)) else { throw ImportError.invalidImage }
        try storeImage(image, for: cardID)
    }
    func storeImage(_ image: UIImage, for cardID: String) throws {
        guard byID[cardID] != nil else { throw ImportError.invalidImage }
        try commitScan(encodedArt(image), text: nil, to: cardID, markOwned: false)
    }
    private func encodedArt(_ image: UIImage) throws -> Data {
        guard image.size.width.isFinite, image.size.height.isFinite, image.size.width > 0, image.size.height > 0 else { throw ImportError.invalidImage }
        let scale = min(1, 2048 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let data = resized.jpegData(compressionQuality: 0.9) else { throw ImportError.invalidImage }
        return data
    }
    func removeArt(_ id: String) { do { try FileManager.default.removeItem(at: artURL(id)); clearRecognizedText(id); imageCache.removeObject(forKey: id as NSString); artRevision += 1 } catch { issue = error.localizedDescription } }
    func importBatch(_ urls: [URL], temporaryFolder: URL? = nil) {
        guard !isImporting, !urls.isEmpty else { return }
        isImporting = true; importCompleted = 0; importTotal = urls.count
        batchTask = Task {
            var imported = 0; var queued = 0; var skipped: [String] = []; var canceled = false
            defer {
                isImporting = false; importStatus = ""; batchTask = nil
                if let temporaryFolder { try? FileManager.default.removeItem(at: temporaryFolder) }
            }
            for url in urls {
                if Task.isCancelled { canceled = true; break }
                let access = url.startAccessingSecurityScopedResource()
                do {
                    if url.pathExtension.lowercased() == "pdf" {
                        let count = try await CardScanOCR.pdfPageCount(url: url)
                        for page in 0..<count {
                            try Task.checkCancellation()
                            let label = "\(url.lastPathComponent) · page \(page + 1)"
                            importStatus = "Reading \(label)"
                            let data = try await CardScanOCR.pdfPageData(url: url, index: page)
                            if try await processScan(data, fileName: label, filenameHint: nil) { imported += 1 } else { queued += 1 }
                        }
                    } else {
                        importStatus = "Reading \(url.lastPathComponent)"
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size < 25_000_000 else { throw ImportError.tooLarge }
                        let data = try Data(contentsOf: url)
                        if try await processScan(data, fileName: url.lastPathComponent, filenameHint: url.lastPathComponent) { imported += 1 } else { queued += 1 }
                    }
                } catch is CancellationError { canceled = true }
                catch { skipped.append("\(url.lastPathComponent): \(error.localizedDescription)") }
                if access { url.stopAccessingSecurityScopedResource() }
                importCompleted += 1
                if canceled { break }
            }
            importReport = "\(imported) scan\(imported == 1 ? "" : "s") identified and attached.\n\(queued) saved for review." + (canceled ? "\nImport stopped. Completed scans are saved." : "") + (skipped.isEmpty ? "" : "\n\nCould not read \(skipped.count) file\(skipped.count == 1 ? "" : "s"):\n" + skipped.prefix(15).joined(separator: "\n"))
        }
    }
    func cancelScanImport() { batchTask?.cancel() }
    func recognizedText(for cardID: String) -> String {
        _ = scanRevision
        guard cardsWithText.contains(cardID) else { return "" }
        if let text = ocrCache[cardID] { return text }
        let text = (try? String(contentsOf: ocrURL(cardID), encoding: .utf8)) ?? ""
        ocrCache[cardID] = text; return text
    }
    func matches(_ card: Card, query: String) -> Bool {
        if card.matches(query) { return true }
        let text = recognizedText(for: card.id)
        guard !text.isEmpty else { return false }
        var folded: String?
        return query.split(whereSeparator: \.isWhitespace).allSatisfy { token in
            let term = String(token)
            if card.matches(term) || text.localizedStandardContains(term) { return true }
            let normalized = Card.normalized(term)
            guard !normalized.isEmpty else { return false }
            if folded == nil { folded = Card.normalized(text) }
            return folded?.contains(normalized) == true
        }
    }
    func reviewImage(scanID: UUID) -> UIImage? { UIImage(contentsOfFile: pendingURL(scanID).path) }
    func resolveScan(scanID: UUID, cardID: String) async {
        guard let scan = pendingScans.first(where: { $0.id == scanID }), byID[cardID] != nil else { return }
        do {
            guard let image = reviewImage(scanID: scanID) else { throw ImportError.invalidImage }
            try attachScan(image, text: scan.recognizedText, to: cardID)
            discardPendingScan(scanID)
        } catch { issue = "Could not attach scan: \(error.localizedDescription)" }
    }
    func discardPendingScan(_ id: UUID) {
        guard pendingScans.contains(where: { $0.id == id }) else { return }
        let previous = pendingScans
        pendingScans.removeAll { $0.id == id }
        do { try saveScanQueue(); if FileManager.default.fileExists(atPath: pendingURL(id).path) { try FileManager.default.removeItem(at: pendingURL(id)) } }
        catch { pendingScans = previous; try? saveScanQueue(); issue = "Could not remove queued scan: \(error.localizedDescription)" }
    }
    private func processScan(_ data: Data, fileName: String, filenameHint: String?) async throws -> Bool {
        guard let image = UIImage(data: data) else { throw ImportError.invalidImage }
        var result: CardScanMatch?
        var failure: String?
        do { result = try await CardScanOCR.recognize(data: data, cards: cards, filename: filenameHint) }
        catch is CancellationError { throw CancellationError() }
        catch { failure = error.localizedDescription }
        try Task.checkCancellation()
        if let cardID = result?.automaticCardID, byID[cardID] != nil, self.image(for: cardID) == nil {
            try attachScan(image, text: result?.recognizedText ?? "", to: cardID)
            return true
        }
        let reason: String
        if failure != nil { reason = "Text recognition could not finish. Choose the card to keep this scan." }
        else if let id = result?.automaticCardID, self.image(for: id) != nil { reason = "This card already has a scan. Review before replacing it." }
        else if (result?.candidates ?? []).isEmpty { reason = "No confident name match. Choose the card or rescan the front." }
        else { reason = "The name or illustration variant needs a quick check." }
        let scan = PendingCardScan(id: UUID(), fileName: fileName, candidates: Array((result?.candidates ?? []).prefix(8)), recognizedText: result?.recognizedText ?? "", reason: reason)
        let normalized = encodedScan(image)
        guard let normalized else { throw ImportError.invalidImage }
        try normalized.write(to: pendingURL(scan.id), options: .atomic)
        pendingScans.append(scan)
        do { try saveScanQueue() } catch { pendingScans.removeAll { $0.id == scan.id }; try? FileManager.default.removeItem(at: pendingURL(scan.id)); throw error }
        return false
    }
    private func attachScan(_ image: UIImage, text: String, to cardID: String) throws {
        try commitScan(encodedArt(image), text: text, to: cardID, markOwned: true)
    }
    private func commitScan(_ art: Data, text: String?, to cardID: String, markOwned: Bool) throws {
        let imageURL = artURL(cardID), textURL = ocrURL(cardID)
        let libraryURL = directory.appendingPathComponent("library.json")
        var updatedLibrary = library
        if markOwned { updatedLibrary.owned[cardID] = max(1, owned(cardID)) }
        var writes: [(URL, Data?)] = [(imageURL, art), (textURL, text.flatMap { $0.isEmpty ? nil : Data($0.utf8) })]
        if markOwned { writes.append((libraryURL, try JSONEncoder().encode(updatedLibrary))) }
        // Retain all prior bytes before changing any file. A failed text or
        // collection save must not destroy a scan being replaced.
        let previous: [(URL, Data?)] = try writes.map { url, _ in
            (url, FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil)
        }
        do {
            for (url, data) in writes { try writeScanFile(data, at: url) }
        } catch {
            var rollbackErrors: [String] = []
            for (url, data) in previous {
                do { try writeScanFile(data, at: url) }
                catch { rollbackErrors.append(error.localizedDescription) }
            }
            if !rollbackErrors.isEmpty {
                imageCache.removeObject(forKey: cardID as NSString); artRevision += 1
                ocrCache.removeValue(forKey: cardID); scanRevision += 1
                if FileManager.default.fileExists(atPath: textURL.path) { cardsWithText.insert(cardID) } else { cardsWithText.remove(cardID) }
                throw ImportError.restoreFailed(rollbackErrors.joined(separator: "; "))
            }
            throw error
        }
        if markOwned { library = updatedLibrary }
        imageCache.removeObject(forKey: cardID as NSString); artRevision += 1
        if let text, !text.isEmpty { cardsWithText.insert(cardID); ocrCache[cardID] = text }
        else { cardsWithText.remove(cardID); ocrCache.removeValue(forKey: cardID) }
        scanRevision += 1
    }
    private func writeScanFile(_ data: Data?, at url: URL) throws {
        if let data { try data.write(to: url, options: .atomic) }
        else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    private func encodedScan(_ image: UIImage) -> Data? {
        let scale = min(1, 2400 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }.jpegData(compressionQuality: 0.95)
    }
    private func pendingURL(_ id: UUID) -> URL { directory.appendingPathComponent("PendingScans").appendingPathComponent(id.uuidString + ".jpg") }
    private func ocrURL(_ id: String) -> URL { directory.appendingPathComponent("OCR").appendingPathComponent(id + ".txt") }
    private func clearRecognizedText(_ id: String) {
        guard cardsWithText.contains(id) else { return }
        try? FileManager.default.removeItem(at: ocrURL(id)); cardsWithText.remove(id); ocrCache.removeValue(forKey: id); scanRevision += 1
    }
    private func saveScanQueue() throws { try JSONEncoder().encode(pendingScans).write(to: directory.appendingPathComponent("scanqueue.json"), options: .atomic) }
    func saveTable(_ state: TabletopState) { do { try JSONEncoder().encode(state).write(to: directory.appendingPathComponent("table.json"), options: .atomic) } catch { issue = "Could not save table: \(error.localizedDescription)" } }
    func loadTable() -> TabletopState? { let url = directory.appendingPathComponent("table.json"); guard FileManager.default.fileExists(atPath: url.path) else { return nil }; do { return try JSONDecoder().decode(TabletopState.self, from: Data(contentsOf: url)) } catch { issue = "Could not restore table: \(error.localizedDescription)"; return nil } }
    private func artURL(_ id: String) -> URL { directory.appendingPathComponent("Art").appendingPathComponent(id + ".jpg") }
    private func save() { do { try JSONEncoder().encode(library).write(to: directory.appendingPathComponent("library.json"), options: .atomic) } catch { issue = "Could not save your collection: \(error.localizedDescription)" } }
    enum ImportError: LocalizedError {
        case tooLarge, invalidImage, restoreFailed(String)
        var errorDescription: String? {
            switch self {
            case .tooLarge: return "Choose an image smaller than 25 MB."
            case .invalidImage: return "This file could not be read as an image."
            case .restoreFailed(let detail): return "A scan could not be saved or fully restored. Your source image is unchanged. \(detail)"
            }
        }
    }
}
