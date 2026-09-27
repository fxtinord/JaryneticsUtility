import Foundation
import PDFKit
import UIKit
import Vision

struct RecognizedDocumentLine: Sendable, Equatable {
    let text: String
    let normalizedBoundingBox: CGRect
    let rowRefinement: RecognizedRowRefinement?

    init(
        text: String,
        normalizedBoundingBox: CGRect,
        rowRefinement: RecognizedRowRefinement? = nil
    ) {
        self.text = text
        self.normalizedBoundingBox = normalizedBoundingBox
        self.rowRefinement = rowRefinement
    }
}

/// The result of a bounded second recognition pass over one source row. A nil
/// value records that refinement was attempted but did not recognize exactly
/// one source-supported value; extraction must then omit rather than infer it.
struct RecognizedRowRefinement: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case signedEnergy
        case settlementMonth
    }

    let kind: Kind
    let valueText: String?
    let normalizedBoundingBox: CGRect?
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

    func highResolutionCrop(
        from sourceURL: URL,
        documentType: SourceDocumentType,
        pageIndex: Int,
        normalizedCrop: CGRect,
        renderWidth: CGFloat
    ) throws -> Data {
        let sourceImage: UIImage
        switch documentType {
        case .image:
            let data = try Data(contentsOf: sourceURL)
            guard let image = UIImage(data: data) else {
                throw DocumentRecognitionError.unreadableImage
            }
            sourceImage = image
        case .pdf:
            guard let document = PDFDocument(url: sourceURL) else {
                throw DocumentRecognitionError.corruptPDF
            }
            guard let page = document.page(at: pageIndex) else {
                throw DocumentRecognitionError.pageRenderingFailed(pageIndex: pageIndex)
            }
            let bounds = page.bounds(for: .mediaBox)
            let width = max(pdfRenderWidth, renderWidth)
            sourceImage = page.thumbnail(
                of: CGSize(width: width, height: width * bounds.height / bounds.width),
                for: .mediaBox
            )
        }

        guard let cgImage = sourceImage.cgImage else {
            throw DocumentRecognitionError.pageRenderingFailed(pageIndex: pageIndex)
        }
        let pixelWidth = CGFloat(cgImage.width)
        let pixelHeight = CGFloat(cgImage.height)
        // Vision boxes use a lower-left origin; CGImage crops use upper-left.
        let pixelCrop = CGRect(
            x: normalizedCrop.minX * pixelWidth,
            y: (1 - normalizedCrop.maxY) * pixelHeight,
            width: normalizedCrop.width * pixelWidth,
            height: normalizedCrop.height * pixelHeight
        ).integral.intersection(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        guard !pixelCrop.isEmpty, let crop = cgImage.cropping(to: pixelCrop),
              let data = UIImage(cgImage: crop).pngData() else {
            throw DocumentRecognitionError.pageRenderingFailed(pageIndex: pageIndex)
        }
        return data
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
            let page = try await recognize(pageInput)
            pages.append(await refineDistributedEnergyRows(
                in: page,
                sourceURL: sourceURL,
                documentType: documentType
            ))
        }
        return DocumentRecognitionResult(pages: pages)
    }

    private func refineDistributedEnergyRows(
        in page: RecognizedDocumentPage,
        sourceURL: URL,
        documentType: SourceDocumentType
    ) async -> RecognizedDocumentPage {
        var lines = page.lines
        for index in lines.indices {
            guard let kind = refinementKind(for: lines[index].text),
                  !containsRequiredValue(lines[index].text, kind: kind),
                  !hasPrimaryRowValue(at: index, among: lines, kind: kind) else {
                continue
            }

            let row = lines[index].normalizedBoundingBox
            let valueText: String?
            var provenanceBox: CGRect?
            if kind == .signedEnergy {
                // Independent render/crop variants must corroborate a sign that
                // the primary pass did not see. A signed/unsigned or +/- split
                // is disagreement, never evidence for semantic sign repair.
                let variants: [(padding: CGFloat, width: CGFloat)] = [
                    (0.55, 3_500),
                    (0.75, 4_000),
                    (0.95, 4_500),
                ]
                var recognizedVariants: [[String]] = []
                for variant in variants {
                    let crop = rowCrop(for: row, paddingMultiplier: variant.padding)
                    do {
                        let imageData = try pageLoader.highResolutionCrop(
                            from: sourceURL,
                            documentType: documentType,
                            pageIndex: page.pageIndex,
                            normalizedCrop: crop,
                            renderWidth: variant.width
                        )
                        recognizedVariants.append(try await recognizedTexts(in: imageData))
                        provenanceBox = crop
                    } catch {
                        recognizedVariants.append([])
                    }
                }
                valueText = Self.corroboratedSignedEnergyValue(from: recognizedVariants)
            } else {
                let crop = rowCrop(for: row, paddingMultiplier: 0.75)
                provenanceBox = crop
                do {
                    let imageData = try pageLoader.highResolutionCrop(
                        from: sourceURL,
                        documentType: documentType,
                        pageIndex: page.pageIndex,
                        normalizedCrop: crop,
                        renderWidth: 4_000
                    )
                    valueText = try await refinedMonth(in: imageData)
                } catch {
                    valueText = nil
                }
            }
            lines[index] = RecognizedDocumentLine(
                text: lines[index].text,
                normalizedBoundingBox: row,
                rowRefinement: RecognizedRowRefinement(
                    kind: kind,
                    valueText: valueText,
                    normalizedBoundingBox: valueText == nil ? nil : provenanceBox
                )
            )
        }
        return RecognizedDocumentPage(pageIndex: page.pageIndex, lines: lines, warnings: page.warnings)
    }

    func hasPrimaryRowValue(
        at labelIndex: Int,
        among lines: [RecognizedDocumentLine],
        kind: RecognizedRowRefinement.Kind
    ) -> Bool {
        let label = lines[labelIndex]
        let valueIndexes = lines.indices.filter {
            $0 != labelIndex && containsRequiredValue(lines[$0].text, kind: kind)
        }
        let targetMatches = valueIndexes.compactMap { valueIndex -> (Int, PrimaryRowScore)? in
            primaryRowScore(label: label.normalizedBoundingBox,
                            value: lines[valueIndex].normalizedBoundingBox)
                .map { (valueIndex, $0) }
        }.sorted { $0.1 < $1.1 }
        guard let target = targetMatches.first,
              targetMatches.count == 1 || target.1.isClearlyBetter(than: targetMatches[1].1)
        else { return false }

        let labelIndexes = lines.indices.filter { refinementKind(for: lines[$0].text) != nil }
        let possibleOwners = labelIndexes.compactMap { ownerIndex -> (Int, PrimaryRowScore)? in
            primaryRowScore(label: lines[ownerIndex].normalizedBoundingBox,
                            value: lines[target.0].normalizedBoundingBox)
                .map { (ownerIndex, $0) }
        }.sorted { $0.1 < $1.1 }
        guard let owner = possibleOwners.first, owner.0 == labelIndex else { return false }
        return possibleOwners.count == 1 || owner.1.isClearlyBetter(than: possibleOwners[1].1)
    }

    private struct PrimaryRowScore: Comparable {
        let overlapRank: Int
        let centerDistance: CGFloat

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.overlapRank, lhs.centerDistance) < (rhs.overlapRank, rhs.centerDistance)
        }

        func isClearlyBetter(than other: Self) -> Bool {
            overlapRank < other.overlapRank
                || (overlapRank == other.overlapRank
                    && other.centerDistance - centerDistance >= 0.35)
        }
    }

    private func primaryRowScore(label: CGRect, value: CGRect) -> PrimaryRowScore? {
        guard value.midX >= label.midX - 0.02,
              max(0, value.minX - label.maxX) <= 0.35 else { return nil }
        let overlap = max(0, min(label.maxY, value.maxY) - max(label.minY, value.minY))
        let height = max(min(label.height, value.height), 0.0001)
        let distance = abs(label.midY - value.midY) / height
        if overlap > 0 { return PrimaryRowScore(overlapRank: 0, centerDistance: distance) }
        guard distance <= 0.75 else { return nil }
        return PrimaryRowScore(overlapRank: 1, centerDistance: distance)
    }

    private func rowCrop(for row: CGRect, paddingMultiplier: CGFloat) -> CGRect {
        let padding = max(row.height * paddingMultiplier, 0.0025)
        let minX = max(0, row.minX - 0.02)
        let minY = max(0, row.minY - padding)
        return CGRect(
            x: minX,
            y: minY,
            width: min(1 - minX, 0.98 - minX),
            height: min(1 - minY, row.height + 2 * padding)
        )
    }

    private func refinementKind(for text: String) -> RecognizedRowRefinement.Kind? {
        let value = text.lowercased()
        if value.range(of: #"^\s*(?:new\s+)?cumulative\s+credit\b|^\s*net\s+metered\b"#,
                       options: .regularExpression) != nil {
            return .signedEnergy
        }
        if value.range(of: #"^\s*(?:anniversary|settlement|true[\s-]*up)\s+month\b"#,
                       options: .regularExpression) != nil {
            return .settlementMonth
        }
        return nil
    }

    private func containsRequiredValue(
        _ text: String,
        kind: RecognizedRowRefinement.Kind
    ) -> Bool {
        switch kind {
        case .signedEnergy:
            text.range(of: #"[+-]\s*\d[\d,]*(?:\.\d+)?\s*kwh\b"#,
                       options: [.regularExpression, .caseInsensitive]) != nil
        case .settlementMonth:
            text.range(of: #"\b(?:1[0-2]|[1-9])\s*$"#,
                       options: .regularExpression) != nil
        }
    }

    private func recognizedTexts(in imageData: Data) async throws -> [String] {
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.automaticallyDetectLanguage = true
        let observations = try await request.perform(on: imageData)
        return observations.first?.document.text.lines.map(\.transcript) ?? []
    }

    static func corroboratedSignedEnergyValue(from variants: [[String]]) -> String? {
        let signedPattern = #"[+-]\s*\d[\d,]*(?:\.\d+)?\s*kwh\b"#
        let unsignedPattern = #"(?<![+\-•])\b\d[\d,]*(?:\.\d+)?\s*kwh\b"#
        var signed: [String] = []
        var sawUnsigned = false
        for texts in variants {
            let signedTokens = tokens(matching: signedPattern, in: texts)
            let unsignedTokens = tokens(matching: unsignedPattern, in: texts)
            guard signedTokens.count <= 1, unsignedTokens.count <= 1 else { return nil }
            if let token = signedTokens.first {
                signed.append(normalizedEnergyToken(token))
            } else if !unsignedTokens.isEmpty {
                sawUnsigned = true
            }
        }
        guard !sawUnsigned, signed.count >= 2,
              let first = signed.first,
              signed.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    private static func tokens(matching pattern: String, in texts: [String]) -> [String] {
        texts.flatMap { text -> [String] in
            guard !text.contains("$") else { return [] }
            let range = NSRange(text.startIndex..., in: text)
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
                return []
            }
            return regex.matches(in: text, range: range).compactMap {
                Range($0.range, in: text).map { String(text[$0]) }
            }
        }
    }

    private static func normalizedEnergyToken(_ token: String) -> String {
        token.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "kwh", with: " kWh")
    }

    private func refinedMonth(in imageData: Data) async throws -> String? {
        let values = Self.tokens(
            matching: #"\b(?:1[0-2]|[1-9])\b"#,
            in: try await recognizedTexts(in: imageData)
        )
        let distinct = Array(Set(values))
        return distinct.count == 1 ? distinct[0] : nil
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
