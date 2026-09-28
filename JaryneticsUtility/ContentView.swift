import Foundation
import QuickLook
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \UtilityBill.createdAt, order: .reverse)
    private var bills: [UtilityBill]
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
                RecognitionResultView(
                    result: presentation.result,
                    extraction: presentation.extraction
                )
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
            let documentStore = try SourceDocumentStore.applicationSupport()
            let importService = BillImportService(documentStore: documentStore)
            try importService.importBill(
                from: selectedURL,
                in: modelContext
            )
        } catch {
            present(error)
        }
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
                let extraction = BillFieldExtractor().extract(from: result)
                recognitionPresentation = RecognitionPresentation(
                    id: bill.id,
                    result: result,
                    extraction: extraction
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
            .buttonStyle(.borderless)
        Button(action: onRecognize) {
            if isRecognizing {
                ProgressView()
                    .accessibilityLabel("Recognizing Text")
            } else {
                Text("Recognize Text")
            }
        }
        .buttonStyle(.borderless)
        .disabled(isRecognizing)
    }
}

private struct RecognitionPresentation: Identifiable {
    let id: UUID
    let result: DocumentRecognitionResult
    let extraction: BillExtractionResult
}

private struct RecognitionResultView: View {
    @Environment(\.dismiss) private var dismiss
    let result: DocumentRecognitionResult
    let extraction: BillExtractionResult

    var body: some View {
        NavigationStack {
            List {
                RecognitionSummarySection(
                    pageCount: result.pages.count,
                    lineCount: result.lineCount,
                    warningCount: result.warnings.count
                )
                ProposedDataSection(extraction: extraction)
#if DEBUG
                let semantics = HybridBillSemanticClassifier().classify(result)
                if !semantics.candidates.isEmpty {
                    SemanticInterpretationSection(classification: semantics)
                }
                let guided = SemanticGuidedBillValueAssociator().associate(
                    recognition: result,
                    semantics: semantics
                )
                if !guided.serviceAssociations.isEmpty {
                    SemanticGuidedProposalSection(result: guided)
                }
                let normalized = NormalizedBillRecordAssembler().assemble(
                    recognition: result,
                    extraction: extraction,
                    semanticGuided: guided
                )
                NormalizedBillRecordSection(record: normalized)
#endif
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

#if DEBUG
private struct NormalizedBillRecordSection: View {
    let record: NormalizedBillRecord

    var body: some View {
        Section {
            proposalRow(record.billIssuer)
            proposalRow(record.statementDate)
            proposalRow(record.totalAmountDue)
            ForEach(Array(record.warnings.enumerated()), id: \.offset) { _, warning in
                Text(warningLabel(warning))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if record.billIssuer == nil,
               record.statementDate == nil,
               record.totalAmountDue == nil {
                Text("No bill-level fields identified.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("DEVELOPMENT / NORMALIZED FIRST-BILL RECORD")
        } footer: {
            Text("This normalized record is proposed, unverified, transient, and has not changed the saved bill.")
        }

        ForEach(record.services) { service in
            Section {
                serviceRow(service.billingPeriodStart)
                serviceRow(service.billingPeriodEnd)
                serviceRow(service.billingDays)
                serviceRow(service.usageQuantity)
                serviceRow(service.usageUnit)
                serviceRow(service.currentPeriodCharges)
                if let distributedEnergy = service.distributedEnergy {
                    ForEach(distributedEnergy.proposals) { proposal in
                        ProposedFieldRow(
                            label: proposal.field.rawValue,
                            value: proposal.value,
                            provenance: proposal.provenance,
                            origin: proposal.origin
                        )
                    }
                }
            } header: {
                Text(serviceName(service.serviceType))
            }
        }
    }

    @ViewBuilder
    private func proposalRow(_ proposal: BillStatementFieldProposal?) -> some View {
        if let proposal {
            ProposedFieldRow(
                label: proposal.field.rawValue,
                value: proposal.value,
                provenance: proposal.provenance,
                origin: proposal.origin
            )
        }
    }

    @ViewBuilder
    private func serviceRow(_ proposal: BillServiceFieldProposal?) -> some View {
        if let proposal {
            ProposedFieldRow(
                label: proposal.field.rawValue,
                value: proposal.value,
                provenance: proposal.provenance,
                origin: proposal.origin
            )
        }
    }

    private func serviceName(_ serviceType: UtilityServiceType) -> String {
        switch serviceType {
        case .electricity: String(localized: "Electricity")
        case .naturalGas: String(localized: "Natural Gas")
        case .waterWastewater: String(localized: "Water / Wastewater")
        }
    }

    private func warningLabel(_ warning: NormalizedBillRecordWarning) -> String {
        switch warning {
        case .conflictingIssuerEvidence(let direct, let providerNeutral):
            "Issuer evidence conflict: retained direct “\(direct)” over provider-neutral “\(providerNeutral)”."
        }
    }
}

private struct SemanticGuidedProposalSection: View {
    let result: SemanticGuidedAssociationResult

    var body: some View {
        ForEach(result.serviceAssociations) { association in
            Section {
                ForEach(association.proposals) { proposal in
                    ProposedFieldRow(
                        label: proposal.field.rawValue,
                        value: proposal.value,
                        provenance: proposal.provenance,
                        origin: proposal.origin
                    )
                }
            } header: {
                Text("DEVELOPMENT / SEMANTIC-GUIDED PROPOSED SERVICE — \(serviceName(association.serviceType))")
            } footer: {
                Text("Semantic-guided proposals are unverified, transient, and have not changed the saved bill.")
            }
        }
    }

    private func serviceName(_ serviceType: UtilityServiceType) -> String {
        switch serviceType {
        case .electricity: String(localized: "Electricity")
        case .naturalGas: String(localized: "Natural Gas")
        case .waterWastewater: String(localized: "Water / Wastewater")
        }
    }
}

private struct SemanticInterpretationSection: View {
    let classification: BillSemanticClassification

    var body: some View {
        Section {
            ForEach(classification.candidates, id: \.concept) { candidate in
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent(
                        semanticLabel(candidate.concept),
                        value: confidenceLabel(candidate.confidence)
                    )
                    Text(candidate.reasons.map(reasonLabel).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(
                        Array(candidate.supportingEvidence.enumerated()),
                        id: \.offset
                    ) { _, evidence in
                        Text(provenanceLabel(evidence))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(evidence.sourceText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        } header: {
            Text("DEVELOPMENT / SEMANTIC INTERPRETATION")
        } footer: {
            Text("Semantic classifications are transient, unverified interpretations of source evidence. They are not extracted or customer-approved bill values.")
        }
    }

    private func semanticLabel(_ concept: BillSemanticConcept) -> String {
        concept.rawValue
            .replacingOccurrences(
                of: #"([a-z])([A-Z])"#,
                with: "$1 $2",
                options: .regularExpression
            )
            .capitalized
    }

    private func confidenceLabel(_ confidence: BillSemanticConfidence) -> String {
        switch confidence {
        case .strong: String(localized: "Strong evidence")
        case .moderate: String(localized: "Moderate evidence")
        case .weak: String(localized: "Weak evidence")
        }
    }

    private func reasonLabel(_ reason: BillSemanticReason) -> String {
        reason.rawValue
            .replacingOccurrences(
                of: #"([a-z])([A-Z])"#,
                with: "$1 $2",
                options: .regularExpression
            )
            .lowercased()
    }

    private func provenanceLabel(_ evidence: BillSemanticEvidence) -> String {
        if let sequenceIndex = evidence.sequenceIndex {
            return "Page \(evidence.pageIndex + 1) · Line \(sequenceIndex + 1)"
        }
        return "Page \(evidence.pageIndex + 1)"
    }
}
#endif

private struct ProposedDataSection: View {
    let extraction: BillExtractionResult

    var body: some View {
        Section {
            if extraction.statementProposals.isEmpty {
                Text("No supported statement fields were proposed.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(extraction.statementProposals) { proposal in
                    ProposedFieldRow(
                        label: proposal.field.rawValue,
                        value: proposal.value,
                        provenance: proposal.provenance,
                        origin: proposal.origin
                    )
                }
            }
        } header: {
            Text("DEVELOPMENT / PROPOSED STATEMENT DATA")
        } footer: {
            Text("Statement proposals are unverified and transient.")
        }

        ForEach(extraction.serviceGroups) { group in
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Proposed service", value: serviceName(group.serviceType))
                    Text("Page \(group.serviceIdentityProvenance.pageIndex + 1) · Extracted directly")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(group.serviceIdentityProvenance.snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if group.proposals.isEmpty {
                    Text("No supported service fields were proposed.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(group.proposals) { proposal in
                        ProposedFieldRow(
                            label: proposal.field.rawValue,
                            value: proposal.value,
                            provenance: proposal.provenance,
                            origin: proposal.origin
                        )
                    }
                }
            } header: {
                Text("DEVELOPMENT / PROPOSED SERVICE — \(serviceName(group.serviceType))")
            } footer: {
                Text("Service proposals are unverified, transient, and have not changed the saved bill.")
            }

            if let distributedEnergy = group.distributedEnergy {
                DistributedEnergyProposalSection(group: distributedEnergy)
            }
        }
    }

    private func serviceName(_ serviceType: UtilityServiceType) -> String {
        switch serviceType {
        case .electricity:
            String(localized: "Electricity")
        case .naturalGas:
            String(localized: "Natural gas")
        case .waterWastewater:
            String(localized: "Water/wastewater")
        }
    }
}

private struct DistributedEnergyProposalSection: View {
    let group: BillDistributedEnergyProposalGroup

    var body: some View {
        Section {
            ForEach(group.proposals) { proposal in
                ProposedFieldRow(
                    label: proposal.field.rawValue,
                    value: proposal.value,
                    provenance: proposal.provenance,
                    origin: proposal.origin
                )
            }
        } header: {
            Text("DEVELOPMENT / PROPOSED DISTRIBUTED ENERGY — Electricity")
        } footer: {
            Text("Distributed-energy proposals are unverified, transient, and have not changed the saved bill.")
        }
    }
}

private struct ProposedFieldRow: View {
    let label: String
    let value: BillProposedValue
    let provenance: BillSourceProvenance
    let origin: BillProposalOrigin

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(label, value: displayValue(value))
            Text("Page \(provenance.pageIndex + 1) · \(originLabel(origin))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(provenance.snippet)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func displayValue(_ value: BillProposedValue) -> String {
        switch value {
        case .boolean(let boolean):
            boolean ? String(localized: "Yes") : String(localized: "No")
        case .date(let date):
            BillDateOnlyPresentation.string(from: date)
        case .decimal(let decimal):
            decimal.formatted()
        case .integer(let integer):
            integer.formatted()
        case .text(let text):
            text
        }
    }

    private func originLabel(_ origin: BillProposalOrigin) -> String {
        switch origin {
        case .extracted:
            String(localized: "Extracted directly")
        case .derived:
            String(localized: "Deterministically derived")
        }
    }
}

enum BillDateOnlyPresentation {
    static func string(
        from date: Date,
        locale: Locale = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = locale
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
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
                UtilityBillServiceDetail.self,
                DistributedEnergyDetail.self,
                SourceDocument.self,
            ],
            inMemory: true
        )
}
