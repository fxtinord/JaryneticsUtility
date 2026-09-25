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
    @State private var recognizingBillIDs: Set<UUID> = []
    @State private var recognitionPresentation: RecognitionPresentation?

    var body: some View {
        NavigationStack {
            List {
                ImportActionSection {
                    isShowingFileImporter = true
                }
                ImportedBillsSection(
                    bills: bills,
                    recognizingBillIDs: recognizingBillIDs,
                    onPreview: preview,
                    onRecognize: recognize
                )
            }
            .navigationTitle("Utility Bills")
            .fileImporter(
                isPresented: $isShowingFileImporter,
                allowedContentTypes: [.pdf, .image]
            ) { result in
                importSelectedDocument(result)
            }
            .quickLookPreview($previewURL)
            .sheet(item: $recognitionPresentation) { presentation in
                RecognitionResultView(result: presentation.result)
            }
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

    private func recognize(_ bill: UtilityBill) {
        guard let sourceDocument = bill.sourceDocument else {
            present(DocumentRecognitionError.unsupportedDocumentType)
            return
        }

        recognizingBillIDs.insert(bill.id)
        Task {
            defer { recognizingBillIDs.remove(bill.id) }
            do {
                let documentStore = try SourceDocumentStore.applicationSupport()
                let sourceURL = try documentStore.resolve(
                    relativePath: sourceDocument.relativePath
                )
                let result = try await DocumentRecognitionService().recognize(
                    sourceURL: sourceURL,
                    documentType: sourceDocument.documentType
                )
                recognitionPresentation = RecognitionPresentation(
                    id: bill.id,
                    result: result
                )
            } catch {
                present(error)
            }
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
    let recognizingBillIDs: Set<UUID>
    let onPreview: (SourceDocument) -> Void
    let onRecognize: (UtilityBill) -> Void

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
                            importedAt: sourceDocument.importedAt,
                            isRecognizing: recognizingBillIDs.contains(bill.id),
                            onPreview: { onPreview(sourceDocument) },
                            onRecognize: { onRecognize(bill) }
                        )
                    }
                }
            }
        }
    }
}

private struct ImportedBillRow: View {
    let filename: String?
    let importedAt: Date
    let isRecognizing: Bool
    let onPreview: () -> Void
    let onRecognize: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(filename ?? String(localized: "Imported Bill"))
                .font(.headline)
            Text(importedAt, format: .dateTime.month().day().year())
                .font(.caption)
                .foregroundStyle(.secondary)

            ViewThatFits {
                HStack {
                    actionButtons
                }
                VStack(alignment: .leading) {
                    actionButtons
                }
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        Button("Preview", action: onPreview)
        Button(action: onRecognize) {
            if isRecognizing {
                ProgressView()
                    .accessibilityLabel("Recognizing Text")
            } else {
                Text("Recognize Text")
            }
        }
        .disabled(isRecognizing)
    }
}

private struct RecognitionPresentation: Identifiable {
    let id: UUID
    let result: DocumentRecognitionResult
}

private struct RecognitionResultView: View {
    @Environment(\.dismiss) private var dismiss
    let result: DocumentRecognitionResult

    var body: some View {
        NavigationStack {
            List {
                RecognitionSummarySection(
                    pageCount: result.pages.count,
                    lineCount: result.lineCount,
                    warningCount: result.warnings.count
                )
                RecognitionTextSection(text: result.text)
            }
            .navigationTitle("Recognition Result")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct RecognitionSummarySection: View {
    let pageCount: Int
    let lineCount: Int
    let warningCount: Int

    var body: some View {
        Section("Status") {
            LabeledContent("Pages", value: pageCount.formatted())
            LabeledContent("Recognized Lines", value: lineCount.formatted())
            if warningCount > 0 {
                LabeledContent("Warnings", value: warningCount.formatted())
            }
        }
    }
}

private struct RecognitionTextSection: View {
    let text: String

    var body: some View {
        Section("Recognized Text") {
            if text.isEmpty {
                Text("No text was detected.")
                    .foregroundStyle(.secondary)
            } else {
                Text(text)
                    .textSelection(.enabled)
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
