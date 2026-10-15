import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Vision
import CardCore

/// Reads a single card image on the device. Images and OCR results never leave
/// this process; the catalog matcher decides whether a title is unambiguous.
enum CardScanOCR {
    enum ScanError: LocalizedError {
        case invalidImage
        case invalidPDF
        case invalidPDFPage
        case renderingFailed

        var errorDescription: String? {
            switch self {
            case .invalidImage: return "This file could not be read as an image."
            case .invalidPDF: return "This PDF could not be opened. It may be damaged or password protected."
            case .invalidPDFPage: return "This PDF page could not be read."
            case .renderingFailed: return "This PDF page could not be converted to an image."
            }
        }
    }

    static func recognize(data: Data, cards: [Card], filename: String? = nil) async throws -> CardScanMatch {
        try await background {
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetCount(source) > 0,
                  CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
                throw ScanError.invalidImage
            }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let orientationValue = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
            let orientation = CGImagePropertyOrientation(rawValue: orientationValue) ?? .up
            let words = Array(Set(cards.map(\.name))).sorted()
            let lines = try recognizeLines(data: data, orientation: orientation, customWords: words)
            try Task.checkCancellation()
            let firstMatch = CardScanMatcher.match(lines: lines, cards: cards, filename: filename)
            if firstMatch.automaticCardID != nil { return firstMatch }

            // A scanner may save a physically inverted card without recording
            // that orientation in EXIF. Retry only when the first pass needs help.
            let invertedLines = try recognizeLines(data: data, orientation: inverted(orientation), customWords: words)
            try Task.checkCancellation()
            let invertedMatch = CardScanMatcher.match(lines: invertedLines, cards: cards, filename: filename)
            if invertedMatch.automaticCardID != nil { return invertedMatch }
            let firstScore = firstMatch.candidates.first?.score ?? 0
            let invertedScore = invertedMatch.candidates.first?.score ?? 0
            if invertedScore > firstScore { return invertedMatch }
            if firstMatch.recognizedText.isEmpty && !invertedMatch.recognizedText.isEmpty { return invertedMatch }
            return firstMatch
        }
    }

    static func pdfPageCount(url: URL) async throws -> Int {
        try await background {
            try Task.checkCancellation()
            let document = try openPDF(url)
            return document.numberOfPages
        }
    }

    /// `index` is zero based. The caller keeps any security-scoped URL access
    /// active until this operation completes and imports pages sequentially.
    static func pdfPageData(url: URL, index: Int) async throws -> Data {
        try await background {
            try Task.checkCancellation()
            let document = try openPDF(url)
            guard index >= 0, index < document.numberOfPages,
                  let page = document.page(at: index + 1) else { throw ScanError.invalidPDFPage }
            let box = page.getBoxRect(.cropBox)
            guard box.width.isFinite, box.height.isFinite, box.width > 0, box.height > 0 else {
                throw ScanError.invalidPDFPage
            }
            let rotation = ((page.rotationAngle % 360) + 360) % 360
            let rotatedSize = rotation == 90 || rotation == 270
                ? CGSize(width: box.height, height: box.width) : box.size
            let scale = 2400 / max(rotatedSize.width, rotatedSize.height)
            let width = max(1, min(2400, Int((rotatedSize.width * scale).rounded())))
            let height = max(1, min(2400, Int((rotatedSize.height * scale).rounded())))
            guard let context = CGContext(data: nil, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw ScanError.renderingFailed
            }
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(rect)
            context.concatenate(page.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(page)
            try Task.checkCancellation()
            guard let image = context.makeImage() else { throw ScanError.renderingFailed }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
                throw ScanError.renderingFailed
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw ScanError.renderingFailed }
            return output as Data
        }
    }

    private static func recognizeLines(data: Data, orientation: CGImagePropertyOrientation, customWords: [String]) throws -> [OCRTextLine] {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US", "de-DE"]
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.01
        request.customWords = customWords
        let handler = VNImageRequestHandler(data: data, orientation: orientation, options: [:])
        try handler.perform([request])
        try Task.checkCancellation()
        let observations = (request.results ?? []).sorted { lhs, rhs in
            // Vision coordinates start at the lower left. Read lines from the
            // top down, preserving left-to-right order for adjacent blocks.
            if lhs.boundingBox.maxY == rhs.boundingBox.maxY {
                return lhs.boundingBox.minX < rhs.boundingBox.minX
            }
            return lhs.boundingBox.maxY > rhs.boundingBox.maxY
        }
        return observations.compactMap { observation in
            guard let text = observation.topCandidates(1).first else { return nil }
            return OCRTextLine(text: text.string, confidence: Double(text.confidence),
                               y: Double(observation.boundingBox.minY), height: Double(observation.boundingBox.height))
        }
    }

    private static func openPDF(_ url: URL) throws -> CGPDFDocument {
        guard let document = CGPDFDocument(url as CFURL), document.numberOfPages > 0,
              !document.isEncrypted || document.isUnlocked else { throw ScanError.invalidPDF }
        return document
    }

    private static func inverted(_ orientation: CGImagePropertyOrientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: return .down
        case .upMirrored: return .downMirrored
        case .down: return .up
        case .downMirrored: return .upMirrored
        case .left: return .right
        case .leftMirrored: return .rightMirrored
        case .right: return .left
        case .rightMirrored: return .leftMirrored
        @unknown default: return .down
        }
    }

    private static func background<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let worker = Task.detached(priority: .userInitiated, operation: operation)
        return try await withTaskCancellationHandler(operation: {
            try await worker.value
        }, onCancel: {
            worker.cancel()
        })
    }
}
