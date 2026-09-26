import Foundation
import SwiftData
import Testing
import UIKit
@testable import JaryneticsUtility

@MainActor
struct DocumentRecognitionTests {
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
