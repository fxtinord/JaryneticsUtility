import Foundation
import SwiftData
import Testing
import UIKit
@testable import JaryneticsUtility

@MainActor
struct DocumentRecognitionTests {
    @Test
    func ordinaryPageUsesSingleFullRecognitionRegion() {
        let regions = RecognitionRegionPlanner().regions(for: CGSize(width: 612, height: 792))
        let sourceBox = CGRect(x: 0.12, y: 0.34, width: 0.45, height: 0.06)

        #expect(regions == [RecognitionPageInput.fullPageRegion])
        #expect(DocumentRecognitionService.remap(sourceBox, from: regions[0]) == sourceBox)
    }

    @Test
    func extremePortraitPageUsesOverlappingRecognitionRegions() {
        let regions = RecognitionRegionPlanner().regions(for: CGSize(width: 902, height: 3821))

        #expect(regions.count > 1)
        #expect(regions.allSatisfy { $0.width == 1 && $0.height < 1 })
        #expect(zip(regions, regions.dropFirst()).allSatisfy { previous, next in
            previous.maxY > next.minY
        })
    }

    @Test
    func segmentCoordinatesMapBackToPhysicalPageCoordinates() {
        let local = CGRect(x: 0.20, y: 0.25, width: 0.30, height: 0.10)
        let lower = DocumentRecognitionService.remap(
            local,
            from: CGRect(x: 0, y: 0, width: 1, height: 0.40)
        )
        let middle = DocumentRecognitionService.remap(
            local,
            from: CGRect(x: 0, y: 0.30, width: 1, height: 0.40)
        )
        let upper = DocumentRecognitionService.remap(
            local,
            from: CGRect(x: 0, y: 0.60, width: 1, height: 0.40)
        )

        expectBox(lower, equals: CGRect(x: 0.20, y: 0.10, width: 0.30, height: 0.04))
        expectBox(middle, equals: CGRect(x: 0.20, y: 0.40, width: 0.30, height: 0.04))
        expectBox(upper, equals: CGRect(x: 0.20, y: 0.70, width: 0.30, height: 0.04))
    }

    @Test
    func mergedSegmentLinesUseStableTopToBottomReadingOrder() {
        let lines = DocumentRecognitionService.mergedLines([
            recognizedLine("LOWER", x: 0.1, y: 0.10),
            recognizedLine("UPPER RIGHT", x: 0.6, y: 0.80),
            recognizedLine("MIDDLE", x: 0.1, y: 0.45),
            recognizedLine("UPPER LEFT", x: 0.1, y: 0.80),
        ])

        #expect(lines.map(\.text) == ["UPPER LEFT", "UPPER RIGHT", "MIDDLE", "LOWER"])
    }

    @Test
    func overlapDuplicateIsRemovedButDistantRepeatedTextIsPreserved() {
        let lines = DocumentRecognitionService.mergedLines([
            recognizedLine("CURRENT CHARGES", x: 0.10, y: 0.70),
            recognizedLine("CURRENT   CHARGES", x: 0.105, y: 0.702),
            recognizedLine("CURRENT CHARGES", x: 0.10, y: 0.20),
        ])

        #expect(lines.count == 2)
        #expect(lines.map(\.normalizedBoundingBox.midY).sorted().first! < 0.3)
        #expect(lines.map(\.normalizedBoundingBox.midY).sorted().last! > 0.7)
    }

    @Test
    func extremePhysicalPDFPageKeepsOnePageIdentityAcrossRegions() throws {
        let testDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: testDirectory) }
        let pdfURL = try writeExtremeSyntheticPDF(in: testDirectory)

        let regions = try SourceDocumentPageLoader().pages(from: pdfURL, documentType: .pdf)

        #expect(regions.count > 1)
        #expect(regions.allSatisfy { $0.pageIndex == 0 })
        #expect(regions.allSatisfy { $0.normalizedRegion.height < 1 })
        #expect(regions.allSatisfy { input in
            guard let image = UIImage(data: input.imageData), let cgImage = image.cgImage else {
                return false
            }
            return max(cgImage.width, cgImage.height) <= 4_100
        })
    }

    @Test
    func recognizesStableTokensFromSyntheticImageWithoutVerifyingBill() async throws {
        let testDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: testDirectory) }
        let imageURL = try writeSyntheticImage(in: testDirectory)
        let container = try makeContainer()
        let bill = try insertBill(
            sourceURL: imageURL,
            documentType: .image,
            verificationState: .draft,
            in: container.mainContext
        )

        let result = try await DocumentRecognitionService().recognize(
            sourceURL: imageURL,
            documentType: .image
        )
        let recognizedText = result.text.uppercased()

        #expect(recognizedText.contains("SYNTHETIC"))
        #expect(recognizedText.contains("ENERGY"))
        #expect(result.pages.count == 1)
        #expect(result.lineCount > 0)
        #expect(bill.verificationState == .draft)
    }

    @Test
    func recognizesEveryPageOfSyntheticPDF() async throws {
        let testDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: testDirectory) }
        let pdfURL = try writeSyntheticPDF(in: testDirectory)

        let result = try await DocumentRecognitionService().recognize(
            sourceURL: pdfURL,
            documentType: .pdf
        )

        #expect(result.pages.map(\.pageIndex) == [0, 1])
        #expect(result.pages[0].text.uppercased().contains("ALPHA"))
        #expect(result.pages[1].text.uppercased().contains("BETA"))
    }

    @Test
    func pageLoaderPreservesMultiPagePDFOrder() throws {
        let testDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: testDirectory) }
        let pdfURL = try writeSyntheticPDF(in: testDirectory)

        let pages = try SourceDocumentPageLoader().pages(
            from: pdfURL,
            documentType: .pdf
        )

        #expect(pages.map(\.pageIndex) == [0, 1])
        #expect(pages.allSatisfy { !$0.imageData.isEmpty })
    }

    @Test
    func rejectsCorruptImageAndPDFSources() async throws {
        let testDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: testDirectory) }
        let corruptImageURL = testDirectory.appendingPathComponent("corrupt.png")
        let corruptPDFURL = testDirectory.appendingPathComponent("corrupt.pdf")
        try Data("not an image".utf8).write(to: corruptImageURL)
        try Data("not a pdf".utf8).write(to: corruptPDFURL)

        var imageError: DocumentRecognitionError?
        do {
            _ = try await DocumentRecognitionService().recognize(
                sourceURL: corruptImageURL,
                documentType: .image
            )
        } catch let error as DocumentRecognitionError {
            imageError = error
        }

        var pdfError: DocumentRecognitionError?
        do {
            _ = try await DocumentRecognitionService().recognize(
                sourceURL: corruptPDFURL,
                documentType: .pdf
            )
        } catch let error as DocumentRecognitionError {
            pdfError = error
        }

        #expect(imageError == .unreadableImage)
        #expect(pdfError == .corruptPDF)
    }

    @Test
    func recognitionFailureLeavesPersistedBillAndSourceUnchanged() async throws {
        let testDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: testDirectory) }
        let corruptImageURL = testDirectory.appendingPathComponent("preserved.png")
        let sourceData = Data("synthetic corrupt image".utf8)
        try sourceData.write(to: corruptImageURL)
        let container = try makeContainer()
        let bill = try insertBill(
            sourceURL: corruptImageURL,
            documentType: .image,
            verificationState: .needsReview,
            in: container.mainContext
        )
        let billID = bill.id
        let sourceID = try #require(bill.sourceDocument?.id)
        let relativePath = try #require(bill.sourceDocument?.relativePath)

        do {
            _ = try await DocumentRecognitionService().recognize(
                sourceURL: corruptImageURL,
                documentType: .image
            )
        } catch {
            // Expected: the assertions below verify recognition has no side effects.
        }

        let verificationContext = ModelContext(container)
        let storedBill = try #require(
            verificationContext.fetch(FetchDescriptor<UtilityBill>()).first
        )
        let storedSource = try #require(storedBill.sourceDocument)
        #expect(storedBill.id == billID)
        #expect(storedBill.verificationState == .needsReview)
        #expect(storedSource.id == sourceID)
        #expect(storedSource.relativePath == relativePath)
        #expect(try Data(contentsOf: corruptImageURL) == sourceData)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        return directoryURL
    }

    private func writeSyntheticImage(in directoryURL: URL) throws -> URL {
        let imageURL = directoryURL.appendingPathComponent("synthetic.png")
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1_600, height: 600))
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1_600, height: 600))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 112, weight: .bold),
                .foregroundColor: UIColor.black,
            ]
            NSString(string: "SYNTHETIC ENERGY 42").draw(
                in: CGRect(x: 70, y: 210, width: 1_460, height: 180),
                withAttributes: attributes
            )
        }
        let imageData = try #require(image.pngData())
        try imageData.write(to: imageURL)
        return imageURL
    }

    private func writeSyntheticPDF(in directoryURL: URL) throws -> URL {
        let pdfURL = directoryURL.appendingPathComponent("synthetic.pdf")
        let pageBounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: pageBounds)
        try renderer.writePDF(to: pdfURL) { context in
            drawPDFPage(text: "ALPHA PAGE", in: context, bounds: pageBounds)
            drawPDFPage(text: "BETA PAGE", in: context, bounds: pageBounds)
        }
        return pdfURL
    }

    private func writeExtremeSyntheticPDF(in directoryURL: URL) throws -> URL {
        let pdfURL = directoryURL.appendingPathComponent("extreme-synthetic.pdf")
        let pageBounds = CGRect(x: 0, y: 0, width: 902, height: 3821)
        let renderer = UIGraphicsPDFRenderer(bounds: pageBounds)
        try renderer.writePDF(to: pdfURL) { context in
            context.beginPage()
            UIColor.white.setFill()
            context.fill(pageBounds)
            NSString(string: "SYNTHETIC EXTREME PAGE").draw(
                in: CGRect(x: 60, y: 100, width: 700, height: 50),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 24, weight: .bold),
                    .foregroundColor: UIColor.black,
                ]
            )
        }
        return pdfURL
    }

    private func recognizedLine(
        _ text: String,
        x: CGFloat,
        y: CGFloat
    ) -> RecognizedDocumentLine {
        RecognizedDocumentLine(
            text: text,
            normalizedBoundingBox: CGRect(x: x, y: y, width: 0.30, height: 0.04)
        )
    }

    private func expectBox(_ actual: CGRect, equals expected: CGRect) {
        let tolerance = 0.000_000_1
        #expect(abs(actual.minX - expected.minX) < tolerance)
        #expect(abs(actual.minY - expected.minY) < tolerance)
        #expect(abs(actual.width - expected.width) < tolerance)
        #expect(abs(actual.height - expected.height) < tolerance)
    }

    private func drawPDFPage(
        text: String,
        in context: UIGraphicsPDFRendererContext,
        bounds: CGRect
    ) {
        context.beginPage()
        UIColor.white.setFill()
        context.fill(bounds)
        NSString(string: text).draw(
            in: CGRect(x: 60, y: 330, width: 492, height: 100),
            withAttributes: [
                .font: UIFont.systemFont(ofSize: 52, weight: .bold),
                .foregroundColor: UIColor.black,
            ]
        )
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Household.self,
            UtilityService.self,
            UtilityBill.self,
            UtilityBillServiceDetail.self,
            DistributedEnergyDetail.self,
            SourceDocument.self,
        ])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
    }

    private func insertBill(
        sourceURL: URL,
        documentType: SourceDocumentType,
        verificationState: BillVerificationState,
        in modelContext: ModelContext
    ) throws -> UtilityBill {
        let sourceDocument = SourceDocument(
            relativePath: sourceURL.lastPathComponent,
            originalFilename: sourceURL.lastPathComponent,
            documentType: documentType
        )
        let bill = UtilityBill(
            verificationState: verificationState,
            sourceDocument: sourceDocument
        )
        modelContext.insert(bill)
        try modelContext.save()
        return bill
    }
}
