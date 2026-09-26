import Foundation
import SwiftData

struct BillImportService {
    let documentStore: SourceDocumentStore

    @discardableResult
    func importBill(
        from sourceURL: URL,
        in modelContext: ModelContext
    ) throws -> UtilityBill {
        let storedDocument = try documentStore.importDocument(from: sourceURL)
        let sourceDocument = SourceDocument(
            id: storedDocument.id,
            relativePath: storedDocument.relativePath,
            originalFilename: storedDocument.originalFilename,
            documentType: storedDocument.documentType,
            importedAt: storedDocument.importedAt
        )
        let bill = UtilityBill(
            verificationState: .draft,
            sourceDocument: sourceDocument
        )

        modelContext.insert(bill)
        do {
            try modelContext.save()
            return bill
        } catch {
            modelContext.rollback()
            try? documentStore.remove(relativePath: storedDocument.relativePath)
            throw error
        }
    }
}
