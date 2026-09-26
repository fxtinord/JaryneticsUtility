import Foundation
import SwiftData
import Testing
@testable import JaryneticsUtility

@MainActor
struct SourceDocumentImportTests {
    @Test
    func copiesSyntheticPDFIntoLocalStore() throws {
        let testDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: testDirectory) }
        let sourceURL = try writeSyntheticPDF(in: testDirectory)
        let store = SourceDocumentStore(
            rootDirectoryURL: testDirectory.appendingPathComponent("StoredDocuments")
        )

        let storedDocument = try store.importDocument(from: sourceURL)
        let storedURL = try store.resolve(relativePath: storedDocument.relativePath)

        #expect(storedDocument.documentType == .pdf)
        #expect(storedDocument.originalFilename == "synthetic-bill.pdf")
        #expect(storedURL != sourceURL)
        #expect(FileManager.default.fileExists(atPath: storedURL.path))
        #expect(try Data(contentsOf: storedURL) == Data(contentsOf: sourceURL))
    }

    @Test
    func createsUniqueDestinationsForRepeatedImports() throws {
        let testDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: testDirectory) }
        let sourceURL = try writeSyntheticPDF(in: testDirectory)
        let store = SourceDocumentStore(
            rootDirectoryURL: testDirectory.appendingPathComponent("StoredDocuments")
        )

        let firstImport = try store.importDocument(from: sourceURL)
        let secondImport = try store.importDocument(from: sourceURL)

        #expect(firstImport.id != secondImport.id)
        #expect(firstImport.relativePath != secondImport.relativePath)
        #expect(try store.resolve(relativePath: firstImport.relativePath) !=
            store.resolve(relativePath: secondImport.relativePath))
    }

    @Test
    func persistsSourceMetadataWithDraftBill() throws {
        let testDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: testDirectory) }
        let sourceURL = try writeSyntheticPDF(in: testDirectory)
        let store = SourceDocumentStore(
            rootDirectoryURL: testDirectory.appendingPathComponent("StoredDocuments")
        )
        let container = try makeContainer()

        try BillImportService(documentStore: store).importBill(
            from: sourceURL,
            in: container.mainContext
        )

        let verificationContext = ModelContext(container)
        let bill = try #require(
            verificationContext.fetch(FetchDescriptor<UtilityBill>()).first
        )
        let sourceDocument = try #require(bill.sourceDocument)
        #expect(bill.verificationState == .draft)
        #expect(bill.serviceDetails.isEmpty)
        #expect(sourceDocument.originalFilename == "synthetic-bill.pdf")
        #expect(sourceDocument.documentType == .pdf)
        #expect(!sourceDocument.relativePath.isEmpty)
    }

    @Test
    func resolvesAndReopensStoredLocalSource() throws {
        let testDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: testDirectory) }
        let sourceURL = try writeSyntheticPDF(in: testDirectory)
        let expectedData = try Data(contentsOf: sourceURL)
        let store = SourceDocumentStore(
            rootDirectoryURL: testDirectory.appendingPathComponent("StoredDocuments")
        )
        let storedDocument = try store.importDocument(from: sourceURL)

        try FileManager.default.removeItem(at: sourceURL)
        let reopenedURL = try store.resolve(relativePath: storedDocument.relativePath)

        #expect(try Data(contentsOf: reopenedURL) == expectedData)
    }

    @Test
    func failedImportDoesNotPersistBillOrSourceAssociation() throws {
        let testDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: testDirectory) }
        let missingSourceURL = testDirectory.appendingPathComponent("missing.pdf")
        let store = SourceDocumentStore(
            rootDirectoryURL: testDirectory.appendingPathComponent("StoredDocuments")
        )
        let container = try makeContainer()
        var didFail = false

        do {
            try BillImportService(documentStore: store).importBill(
                from: missingSourceURL,
                in: container.mainContext
            )
        } catch {
            didFail = true
        }

        #expect(didFail)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<UtilityBill>()) == 0)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<SourceDocument>()) == 0)
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

    private func writeSyntheticPDF(in directoryURL: URL) throws -> URL {
        let sourceURL = directoryURL.appendingPathComponent("synthetic-bill.pdf")
        let data = Data("%PDF-1.4\nSynthetic test bill\n%%EOF".utf8)
        try data.write(to: sourceURL)
        return sourceURL
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Household.self,
            UtilityService.self,
            UtilityBill.self,
            UtilityBillServiceDetail.self,
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

}
