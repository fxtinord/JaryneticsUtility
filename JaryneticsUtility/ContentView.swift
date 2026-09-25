import QuickLook
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \UtilityBill.createdAt, order: .reverse)
    private var bills: [UtilityBill]
    @Query private var utilityServices: [UtilityService]

    @State private var isShowingFileImporter = false
    @State private var isShowingError = false
    @State private var errorMessage = ""
    @State private var previewURL: URL?

    var body: some View {
        NavigationStack {
            List {
                ImportActionSection {
                    isShowingFileImporter = true
                }
                ImportedBillsSection(bills: bills) { sourceDocument in
                    preview(sourceDocument)
                }
            }
            .navigationTitle("Utility Bills")
            .fileImporter(
                isPresented: $isShowingFileImporter,
                allowedContentTypes: [.pdf, .image]
            ) { result in
                importSelectedDocument(result)
            }
            .quickLookPreview($previewURL)
            .alert("Document Error", isPresented: $isShowingError) {
                Button("OK") {}
            } message: {
                Text(errorMessage)
            }
        }
    }

    private func importSelectedDocument(_ result: Result<URL, Error>) {
        do {
            let selectedURL = try result.get()
            let service = try utilityServiceForImport()
            let documentStore = try SourceDocumentStore.applicationSupport()
            let importService = BillImportService(documentStore: documentStore)
            try importService.importBill(
                from: selectedURL,
                for: service,
                in: modelContext
            )
        } catch {
            present(error)
        }
    }

    private func utilityServiceForImport() throws -> UtilityService {
        if let utilityService = utilityServices.first {
            return utilityService
        }

        let household = Household(name: "My Household")
        let utilityService = UtilityService(
            serviceType: .electricity,
            providerName: "Utility Provider",
            household: household
        )
        modelContext.insert(household)
        try modelContext.save()
        return utilityService
    }

    private func preview(_ sourceDocument: SourceDocument) {
        do {
            let documentStore = try SourceDocumentStore.applicationSupport()
            previewURL = try documentStore.resolve(
                relativePath: sourceDocument.relativePath
            )
        } catch {
            present(error)
        }
    }

    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
        isShowingError = true
    }
}

private struct ImportActionSection: View {
    let onImport: () -> Void

    var body: some View {
        Section {
            Button(action: onImport) {
                Label("Import Bill Document", systemImage: "square.and.arrow.down")
            }
        } footer: {
            Text("Choose one PDF or image. The app keeps a private local copy.")
        }
    }
}

private struct ImportedBillsSection: View {
    let bills: [UtilityBill]
    let onPreview: (SourceDocument) -> Void

    var body: some View {
        Section("Imported Bills") {
            if bills.isEmpty {
                ContentUnavailableView(
                    "No Imported Bills",
                    systemImage: "doc",
                    description: Text("Import a PDF or image to create a draft bill.")
                )
            } else {
                ForEach(bills) { bill in
                    if let sourceDocument = bill.sourceDocument {
                        ImportedBillRow(
                            filename: sourceDocument.originalFilename,
                            importedAt: sourceDocument.importedAt
                        ) {
                            onPreview(sourceDocument)
                        }
                    }
                }
            }
        }
    }
}

private struct ImportedBillRow: View {
    let filename: String?
    let importedAt: Date
    let onPreview: () -> Void

    var body: some View {
        Button(action: onPreview) {
            VStack(alignment: .leading, spacing: 4) {
                Text(filename ?? String(localized: "Imported Bill"))
                    .font(.headline)
                Text(importedAt, format: .dateTime.month().day().year())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(
            for: [
                Household.self,
                UtilityService.self,
                UtilityBill.self,
                SourceDocument.self,
            ],
            inMemory: true
        )
}
