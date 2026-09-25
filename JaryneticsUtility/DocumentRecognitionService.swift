import Foundation
import PDFKit
import UIKit
import Vision

struct RecognizedDocumentLine: Sendable, Equatable {
    let text: String
    let normalizedBoundingBox: CGRect
}

struct RecognizedDocumentPage: Sendable, Equatable {
    let pageIndex: Int
    let lines: [RecognizedDocumentLine]
    let warnings: [RecognitionWarning]

    var text: String {
        lines.map(\.text).joined(separator: "\n")
    }
}

struct DocumentRecognitionResult: Sendable, Equatable {
    let pages: [RecognizedDocumentPage]

    var text: String {
        pages.map(\.text).joined(separator: "\n\n")
    }

    var lineCount: Int {
        pages.reduce(0) { $0 + $1.lines.count }
    }

    var warnings: [RecognitionWarning] {
        pages.flatMap(\.warnings)
    }
}

struct RecognitionWarning: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case noTextDetected
    }

    let pageIndex: Int
    let kind: Kind
}

struct RecognitionPageInput: Sendable, Equatable {
    let pageIndex: Int
    let imageData: Data
}

enum DocumentRecognitionError: LocalizedError, Equatable {
    case unsupportedDocumentType
    case unreadableImage
    case corruptPDF
    case emptyPDF
    case pageRenderingFailed(pageIndex: Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedDocumentType:
            String(localized: "This source document type is not supported for recognition.")
        case .unreadableImage:
            String(localized: "The image could not be read for text recognition.")
        case .corruptPDF:
            String(localized: "The PDF could not be read for text recognition.")
        case .emptyPDF:
            String(localized: "The PDF does not contain any pages.")
        case .pageRenderingFailed:
            String(localized: "A PDF page could not be prepared for text recognition.")
        }
    }
}

struct SourceDocumentPageLoader {
    private let pdfRenderWidth: CGFloat

    init(pdfRenderWidth: CGFloat = 2_000) {
        self.pdfRenderWidth = pdfRenderWidth
    }

    func pages(
        from sourceURL: URL,
        documentType: SourceDocumentType
    ) throws -> [RecognitionPageInput] {
        switch documentType {
        case .image:
            try imagePages(from: sourceURL)
        case .pdf:
            try pdfPages(from: sourceURL)
        }
    }

    private func imagePages(from sourceURL: URL) throws -> [RecognitionPageInput] {
        let imageData = try Data(contentsOf: sourceURL)
        guard UIImage(data: imageData) != nil else {
            throw DocumentRecognitionError.unreadableImage
        }
        return [RecognitionPageInput(pageIndex: 0, imageData: imageData)]
    }

    private func pdfPages(from sourceURL: URL) throws -> [RecognitionPageInput] {
        guard let document = PDFDocument(url: sourceURL) else {
            throw DocumentRecognitionError.corruptPDF
        }
        guard document.pageCount > 0 else {
            throw DocumentRecognitionError.emptyPDF
        }

        return try (0..<document.pageCount).map { pageIndex in
            guard let page = document.page(at: pageIndex) else {
                throw DocumentRecognitionError.pageRenderingFailed(pageIndex: pageIndex)
            }
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.width > 0, bounds.height > 0 else {
                throw DocumentRecognitionError.pageRenderingFailed(pageIndex: pageIndex)
            }
            let targetSize = CGSize(
                width: pdfRenderWidth,
                height: pdfRenderWidth * bounds.height / bounds.width
            )
            let image = page.thumbnail(of: targetSize, for: .mediaBox)
            guard let imageData = image.pngData() else {
                throw DocumentRecognitionError.pageRenderingFailed(pageIndex: pageIndex)
            }
            return RecognitionPageInput(pageIndex: pageIndex, imageData: imageData)
        }
    }
}

struct DocumentRecognitionService {
    private let pageLoader: SourceDocumentPageLoader

    init(pageLoader: SourceDocumentPageLoader = SourceDocumentPageLoader()) {
        self.pageLoader = pageLoader
    }

    func recognize(
        sourceURL: URL,
        documentType: SourceDocumentType
    ) async throws -> DocumentRecognitionResult {
        let pageInputs = try pageLoader.pages(
            from: sourceURL,
            documentType: documentType
        )
        var pages: [RecognizedDocumentPage] = []
        pages.reserveCapacity(pageInputs.count)

        for pageInput in pageInputs {
            pages.append(try await recognize(pageInput))
        }
        return DocumentRecognitionResult(pages: pages)
    }

    private func recognize(
        _ pageInput: RecognitionPageInput
    ) async throws -> RecognizedDocumentPage {
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.automaticallyDetectLanguage = true
        let observations = try await request.perform(on: pageInput.imageData)

        guard let document = observations.first?.document else {
            return RecognizedDocumentPage(
                pageIndex: pageInput.pageIndex,
                lines: [],
                warnings: [
                    RecognitionWarning(
                        pageIndex: pageInput.pageIndex,
                        kind: .noTextDetected
                    ),
                ]
            )
        }

        let lines = document.text.lines.map { line in
            RecognizedDocumentLine(
                text: line.transcript,
                normalizedBoundingBox: line.boundingRegion.boundingBox.cgRect
            )
        }
        let warnings = lines.isEmpty
            ? [RecognitionWarning(pageIndex: pageInput.pageIndex, kind: .noTextDetected)]
            : []
        return RecognizedDocumentPage(
            pageIndex: pageInput.pageIndex,
            lines: lines,
            warnings: warnings
        )
    }
}
