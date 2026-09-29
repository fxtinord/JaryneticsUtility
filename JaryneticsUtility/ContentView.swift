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
#if DEBUG
    @State private var previousNormalizedBillRecord: NormalizedBillRecord?
#endif

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
#if DEBUG
                RecognitionResultView(
                    result: presentation.result,
                    extraction: presentation.extraction,
                    changeSummary: presentation.changeSummary
                )
#else
                RecognitionResultView(
                    result: presentation.result,
                    extraction: presentation.extraction
                )
#endif
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
#if DEBUG
                let semantics = HybridBillSemanticClassifier().classify(result)
                let guided = SemanticGuidedBillValueAssociator().associate(
                    recognition: result,
                    semantics: semantics
                )
                let normalized = NormalizedBillRecordAssembler().assemble(
                    recognition: result,
                    extraction: extraction,
                    semanticGuided: guided
                )
                let changeSummary = previousNormalizedBillRecord.map { previous in
                    let comparison = NormalizedBillComparisonAssembler().assemble(previous, normalized)
                    let change = NormalizedBillChangeAssembler().assemble(from: comparison)
                    return BillChangeSummaryAssembler().assemble(from: change)
                }
                previousNormalizedBillRecord = normalized
                recognitionPresentation = RecognitionPresentation(
                    id: bill.id,
                    result: result,
                    extraction: extraction,
                    changeSummary: changeSummary
                )
#else
                recognitionPresentation = RecognitionPresentation(
                    id: bill.id,
                    result: result,
                    extraction: extraction
                )
#endif
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
#if DEBUG
    let changeSummary: BillChangeSummary?
#endif
}

private struct RecognitionResultView: View {
    @Environment(\.dismiss) private var dismiss
    let result: DocumentRecognitionResult
    let extraction: BillExtractionResult
#if DEBUG
    let changeSummary: BillChangeSummary?
#endif

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
                RecognitionEvidenceDiagnosticSection(
                    diagnostic: RecognitionEvidenceDiagnosticAssembler().assemble(from: result)
                )
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
                let summary = FirstBillSummaryAssembler().assemble(from: normalized)
                if summary.hasContent {
                    FirstBillSummarySection(summary: summary)
                }
                if let changeSummary {
                    BillChangeSummarySection(summary: changeSummary)
                }
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
private struct RecognitionEvidenceDiagnosticSection: View {
    let diagnostic: RecognitionEvidenceDiagnostic

    var body: some View {
        Section {
            if diagnostic.candidateWindows.isEmpty {
                Text("No bill-date or amount-due label candidates were discovered.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(diagnostic.candidateWindows) { window in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Candidate window · Page \(window.pageIndex + 1) · Observation \(window.sequenceIndex)")
                            .font(.subheadline.weight(.semibold))
                        ForEach(window.observations) { observation in
                            diagnosticObservation(observation)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Page 1 early observations")
                    .font(.subheadline.weight(.semibold))
                if diagnostic.earlyPageObservations.isEmpty {
                    Text("No early-page OCR observations are available.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(diagnostic.earlyPageObservations) { observation in
                        diagnosticObservation(observation)
                    }
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("DEVELOPMENT / RECOGNITION EVIDENCE DIAGNOSTIC")
        } footer: {
            Text("Diagnostic OCR observations only. These values have not been accepted as bill data.")
        }
    }

    private func diagnosticObservation(
        _ observation: RecognitionEvidenceDiagnosticObservation
    ) -> some View {
        let box = observation.normalizedBoundingBox
        let boxDescription = "Box: x \(coordinate(box.minX)) · y \(coordinate(box.minY)) · "
            + "w \(coordinate(box.width)) · h \(coordinate(box.height))"
        return VStack(alignment: .leading, spacing: 2) {
            Text("Page \(observation.pageIndex + 1) (index \(observation.pageIndex)) · Observation \(observation.sequenceIndex)")
                .font(.caption.weight(.semibold))
            Text("Role: \(observation.role.rawValue)")
                .font(.caption)
            Text("Text: \(observation.text)")
                .font(.caption)
            Text(boxDescription)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
    }

    private func coordinate(_ value: CGFloat) -> String {
        String(format: "%.6f", value)
    }
}

private struct BillChangeSummarySection: View {
    let summary: BillChangeSummary

    var body: some View {
        Section {
            Text("Utility Bill Change Summary")
                .font(.headline)
            if let utilityName = summary.utilityName {
                LabeledContent("Utility", value: utilityName)
            }
            if summary.services.isEmpty {
                Text("These records do not contain enough comparable information for a bill-change summary.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("DEVELOPMENT / BILL CHANGE SUMMARY")
        } footer: {
            Text("Calculated from recognized bill information. Review before use.")
        }

        ForEach(summary.services) { service in
            BillChangeServiceSummarySection(service: service)
        }
    }

}

private struct BillChangeServiceSummarySection: View {
    let service: BillChangeServiceSummary

    var body: some View {
        Section(BillChangeSummaryFormatting.serviceName(service.serviceType)) {
            periodRows
            if let usage = service.usage {
                metricRows(title: "Usage", metric: usage)
            }
            if let charges = service.currentPeriodCharges {
                metricRows(title: "Current-period charges", metric: charges)
            }
            if !service.hasCalculatedMetric {
                Text("A reliable usage or charge comparison is not available for these bills.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var periodRows: some View {
        if let period = service.earlierPeriod,
           let value = BillChangeSummaryFormatting.period(period) {
            LabeledContent("Earlier period", value: value)
        }
        if let days = service.earlierBillingDays,
           let value = BillChangeSummaryFormatting.billingDays(days) {
            LabeledContent("Earlier billing days", value: value)
        }
        if let period = service.laterPeriod,
           let value = BillChangeSummaryFormatting.period(period) {
            LabeledContent("Later period", value: value)
        }
        if let days = service.laterBillingDays,
           let value = BillChangeSummaryFormatting.billingDays(days) {
            LabeledContent("Later billing days", value: value)
        }
    }

    @ViewBuilder
    private func metricRows(title: String, metric: BillChangeSummaryMetric) -> some View {
        let calculation = metric.calculation
        Text(BillChangeSummaryFormatting.direction(calculation.direction, metricName: title))
            .font(.subheadline.weight(.semibold))
        LabeledContent(
            "Earlier",
            value: BillChangeSummaryFormatting.sourceValue(
                calculation.earlierValue,
                unit: metric.unit
            )
        )
        LabeledContent(
            "Later",
            value: BillChangeSummaryFormatting.sourceValue(
                calculation.laterValue,
                unit: metric.unit
            )
        )
        LabeledContent(
            "Change",
            value: BillChangeSummaryFormatting.signedChange(
                calculation.delta,
                unit: metric.unit
            )
        )
        if let percentage = BillChangeSummaryFormatting.percentage(calculation.percentageChange) {
            LabeledContent("Percentage change", value: percentage)
        } else {
            LabeledContent("Percentage change", value: "Not available")
        }
    }
}

private struct FirstBillSummarySection: View {
    let summary: FirstBillSummary

    var body: some View {
        Section {
            Text("Utility Bill Summary")
                .font(.headline)
            if let issuer = summary.billIssuer {
                LabeledContent("Utility", value: issuer.value)
            }
            if let statementDate = summary.statementDate {
                LabeledContent(
                    "Statement date",
                    value: BillDateOnlyPresentation.string(from: statementDate.value)
                )
            }
            if let amountDue = summary.amountDue {
                LabeledContent(
                    "Amount due",
                    value: FirstBillSummaryFormatting.currency(amountDue.value)
                )
            }
        } header: {
            Text("DEVELOPMENT / FIRST-BILL SUMMARY")
        } footer: {
            Text("Proposed from recognized bill information. Review before use.")
        }

        ForEach(summary.services) { service in
            FirstBillSummaryServiceSection(service: service)
        }
    }
}

private struct FirstBillSummaryServiceSection: View {
    let service: FirstBillServiceSummary

    var body: some View {
        Section(serviceName) {
            if let period = service.billingPeriod {
                LabeledContent(
                    "Billing period",
                    value: FirstBillSummaryFormatting.billingPeriod(
                        start: period.start.value,
                        end: period.end.value
                    )
                )
            }
            if let billingDays = service.billingDays {
                LabeledContent("Billing days", value: billingDays.value.formatted())
            }
            if let usage = service.usage {
                LabeledContent(
                    "Usage",
                    value: FirstBillSummaryFormatting.usage(
                        quantity: usage.quantity.value,
                        unit: usage.unit.value
                    )
                )
            }
            if let charges = service.currentPeriodCharges {
                LabeledContent(
                    "Current-period charges",
                    value: FirstBillSummaryFormatting.currency(charges.value)
                )
            }
        }
    }

    private var serviceName: String {
        switch service.serviceType {
        case .electricity: String(localized: "Electricity")
        case .naturalGas: String(localized: "Natural Gas")
        case .waterWastewater: String(localized: "Water / Wastewater")
        }
    }
}

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
