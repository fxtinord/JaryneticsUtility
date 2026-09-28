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
    let normalizedRegion: CGRect

    init(pageIndex: Int, imageData: Data, normalizedRegion: CGRect = Self.fullPageRegion) {
        self.pageIndex = pageIndex
        self.imageData = imageData
        self.normalizedRegion = normalizedRegion
    }

    static let fullPageRegion = CGRect(x: 0, y: 0, width: 1, height: 1)
}

/// Plans internal OCR windows while preserving the source PDF's physical page.
/// Ordinary pages remain a single region. Extreme portrait pages are bounded by
/// raster height; extreme landscape pages are bounded by source-region aspect.
struct RecognitionRegionPlanner {
    let renderWidth: CGFloat
    let maximumRegionPixelDimension: CGFloat
    let maximumRegionAspectRatio: CGFloat
    let overlapFraction: CGFloat

    init(
        renderWidth: CGFloat = 2_000,
        maximumRegionPixelDimension: CGFloat = 4_096,
        maximumRegionAspectRatio: CGFloat = 2.0,
        overlapFraction: CGFloat = 0.08
    ) {
        self.renderWidth = renderWidth
        self.maximumRegionPixelDimension = maximumRegionPixelDimension
        self.maximumRegionAspectRatio = maximumRegionAspectRatio
        self.overlapFraction = overlapFraction
    }

    func regions(for pageSize: CGSize) -> [CGRect] {
        guard pageSize.width > 0, pageSize.height > 0 else { return [] }
        let fullRasterHeight = renderWidth * pageSize.height / pageSize.width
        if fullRasterHeight > maximumRegionPixelDimension {
            return windows(
                along: .vertical,
                normalizedLength: maximumRegionPixelDimension / fullRasterHeight
            )
        }
        let landscapeAspect = pageSize.width / pageSize.height
        if landscapeAspect > maximumRegionAspectRatio {
            return windows(
                along: .horizontal,
                normalizedLength: maximumRegionAspectRatio / landscapeAspect
            )
        }
        return [RecognitionPageInput.fullPageRegion]
    }

    private enum Axis { case horizontal, vertical }

    private func windows(along axis: Axis, normalizedLength: CGFloat) -> [CGRect] {
        let length = min(max(normalizedLength, 0.1), 1)
        let step = length * (1 - overlapFraction)
        var starts: [CGFloat] = [0]
        while let last = starts.last, last + length < 1 {
            let next = min(last + step, 1 - length)
            guard next > last else { break }
            starts.append(next)
        }
        return starts.map { start in
            switch axis {
            case .horizontal:
                CGRect(x: start, y: 0, width: length, height: 1)
            case .vertical:
                CGRect(x: 0, y: start, width: 1, height: length)
            }
        }
    }
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
    private let regionPlanner: RecognitionRegionPlanner

    init(
        pdfRenderWidth: CGFloat = 2_000,
        regionPlanner: RecognitionRegionPlanner? = nil
    ) {
        self.pdfRenderWidth = pdfRenderWidth
        self.regionPlanner = regionPlanner ?? RecognitionRegionPlanner(renderWidth: pdfRenderWidth)
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

        return try (0..<document.pageCount).flatMap { pageIndex in
            guard let page = document.page(at: pageIndex) else {
                throw DocumentRecognitionError.pageRenderingFailed(pageIndex: pageIndex)
            }
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.width > 0, bounds.height > 0 else {
                throw DocumentRecognitionError.pageRenderingFailed(pageIndex: pageIndex)
            }
            let regions = regionPlanner.regions(for: bounds.size)
            return try regions.map { region in
                let imageData: Data
                if region == RecognitionPageInput.fullPageRegion {
                    let targetSize = CGSize(
                        width: pdfRenderWidth,
                        height: pdfRenderWidth * bounds.height / bounds.width
                    )
                    let image = page.thumbnail(of: targetSize, for: .mediaBox)
                    guard let data = image.pngData() else {
                        throw DocumentRecognitionError.pageRenderingFailed(pageIndex: pageIndex)
                    }
                    imageData = data
                } else {
                    imageData = try render(
                        page: page,
                        bounds: bounds,
                        normalizedRegion: region,
                        pageIndex: pageIndex
                    )
                }
                return RecognitionPageInput(
                    pageIndex: pageIndex,
                    imageData: imageData,
                    normalizedRegion: region
                )
            }
        }
    }

    private func render(
        page: PDFPage,
        bounds: CGRect,
        normalizedRegion: CGRect,
        pageIndex: Int
    ) throws -> Data {
        let sourceRegion = CGRect(
            x: bounds.minX + normalizedRegion.minX * bounds.width,
            y: bounds.minY + normalizedRegion.minY * bounds.height,
            width: normalizedRegion.width * bounds.width,
            height: normalizedRegion.height * bounds.height
        )
        let pixelWidth = Int(pdfRenderWidth.rounded(.up))
        let scale = pdfRenderWidth / sourceRegion.width
        let pixelHeight = Int((sourceRegion.height * scale).rounded(.up))
        guard pixelWidth > 0, pixelHeight > 0,
              let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw DocumentRecognitionError.pageRenderingFailed(pageIndex: pageIndex)
        }
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -sourceRegion.minX, y: -sourceRegion.minY)
        page.draw(with: .mediaBox, to: context)
        guard let image = context.makeImage(),
              let data = UIImage(cgImage: image).pngData() else {
            throw DocumentRecognitionError.pageRenderingFailed(pageIndex: pageIndex)
        }
        return data
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
        let physicalPageIndexes = pageInputs.map(\.pageIndex).reduce(into: [Int]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        pages.reserveCapacity(physicalPageIndexes.count)

        for pageIndex in physicalPageIndexes {
            let regions = pageInputs.filter { $0.pageIndex == pageIndex }
            var regionLines: [RecognizedDocumentLine] = []
            for region in regions {
                regionLines += try await recognize(region)
            }
            let mergedLines = Self.mergedLines(regionLines)
            let page = RecognizedDocumentPage(
                pageIndex: pageIndex,
                lines: mergedLines,
                warnings: mergedLines.isEmpty
                    ? [RecognitionWarning(pageIndex: pageIndex, kind: .noTextDetected)]
                    : []
            )
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
    ) async throws -> [RecognizedDocumentLine] {
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.automaticallyDetectLanguage = true
        let observations = try await request.perform(on: pageInput.imageData)

        guard let document = observations.first?.document else {
            return []
        }

        return document.text.lines.map { line in
            RecognizedDocumentLine(
                text: line.transcript,
                normalizedBoundingBox: Self.remap(
                    line.boundingRegion.boundingBox.cgRect,
                    from: pageInput.normalizedRegion
                )
            )
        }
    }

    nonisolated static func remap(_ localBox: CGRect, from region: CGRect) -> CGRect {
        CGRect(
            x: region.minX + localBox.minX * region.width,
            y: region.minY + localBox.minY * region.height,
            width: localBox.width * region.width,
            height: localBox.height * region.height
        )
    }

    nonisolated static func mergedLines(_ lines: [RecognizedDocumentLine]) -> [RecognizedDocumentLine] {
        let ordered = lines.sorted(by: readingOrder)
        return ordered.reduce(into: [RecognizedDocumentLine]()) { result, candidate in
            guard !result.contains(where: { isOverlapDuplicate($0, candidate) }) else { return }
            result.append(candidate)
        }
    }

    nonisolated private static func readingOrder(
        _ lhs: RecognizedDocumentLine,
        _ rhs: RecognizedDocumentLine
    ) -> Bool {
        let rowTolerance = max(lhs.normalizedBoundingBox.height, rhs.normalizedBoundingBox.height) * 0.5
        if abs(lhs.normalizedBoundingBox.midY - rhs.normalizedBoundingBox.midY) <= rowTolerance {
            return lhs.normalizedBoundingBox.minX < rhs.normalizedBoundingBox.minX
        }
        return lhs.normalizedBoundingBox.midY > rhs.normalizedBoundingBox.midY
    }

    nonisolated private static func isOverlapDuplicate(
        _ lhs: RecognizedDocumentLine,
        _ rhs: RecognizedDocumentLine
    ) -> Bool {
        let intersection = lhs.normalizedBoundingBox.intersection(rhs.normalizedBoundingBox)
        guard !intersection.isNull else { return false }
        let smallerArea = min(
            lhs.normalizedBoundingBox.width * lhs.normalizedBoundingBox.height,
            rhs.normalizedBoundingBox.width * rhs.normalizedBoundingBox.height
        )
        guard smallerArea > 0 else { return false }
        let overlapFraction = intersection.width * intersection.height / smallerArea
        if normalizedText(lhs.text) == normalizedText(rhs.text) {
            return overlapFraction >= 0.5
        }
        let rowHeight = max(lhs.normalizedBoundingBox.height, rhs.normalizedBoundingBox.height)
        return overlapFraction >= 0.8
            && abs(lhs.normalizedBoundingBox.midY - rhs.normalizedBoundingBox.midY)
                <= rowHeight * 0.5
    }

    nonisolated private static func normalizedText(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(
                of: #"[^\p{L}\p{N}]+"#,
                with: " ",
                options: .regularExpression
            )
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
