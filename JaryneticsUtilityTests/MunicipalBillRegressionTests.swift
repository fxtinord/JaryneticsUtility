import CoreGraphics
import Foundation
import Testing
@testable import JaryneticsUtility

@MainActor
struct MunicipalBillRegressionTests {
    private let resolver = ProviderNeutralBillIdentityResolver()
    private let assembler = NormalizedBillRecordAssembler()
    private var emptyGuided: SemanticGuidedAssociationResult { .init(serviceAssociations: []) }

    @Test func exactAdjustmentVocabularyIsNotAnIssuer() {
        #expect(resolver.resolve(from: recognition(
            line("Adjustments", y: 0.94),
            line("Utility Bill", y: 0.88),
            line("Account Summary", y: 0.82)
        )) == nil)
    }

    @Test(arguments: ["Arustments", "Adjustmens", "ADJUSTM.ENTS"])
    func modestlyCorruptedAdjustmentVocabularyIsNotAnIssuer(_ text: String) {
        #expect(resolver.resolve(from: recognition(
            line(text, y: 0.94),
            line("Utility Bill", y: 0.88),
            line("Account Summary", y: 0.82)
        )) == nil)
    }

    @Test(arguments: [
        "Total Due", "Current Charges", "Payments", "Previous Balance", "Meter Information",
        "Service Address", "Account Number", "Taxes", "Credits", "Delivery",
    ])
    func genericBillingVocabularyIsNotAnIssuer(_ text: String) {
        #expect(resolver.resolve(from: recognition(
            line(text, y: 0.94),
            line("Utility Bill", y: 0.88),
            line("Account Summary", y: 0.82)
        )) == nil)
    }

    @Test func strongSyntheticOrganizationIdentityStillResolves() throws {
        let identity = try #require(resolver.resolve(from: recognition(
            line("North Harbor Municipal Authority", y: 0.94),
            line("Utility Billing Statement", y: 0.88),
            line("Account Summary", y: 0.82)
        )))
        #expect(identity.issuer == "North Harbor Municipal Authority")
    }

    @Test func adjacentSyntheticOrganizationHeaderStillResolves() throws {
        let identity = try #require(resolver.resolve(from: recognition(
            line("NORTH HARBOR", box: box(x: 0.08, y: 0.92, width: 0.32)),
            line("AUTHORITY.", box: box(x: 0.08, y: 0.87, width: 0.24)),
            line("Utility Bill", y: 0.81)
        )))
        #expect(identity.issuer == "NORTH HARBOR AUTHORITY")
    }

    @Test func weakOrganizationLikeWordWithoutCorroborationAbstains() {
        #expect(resolver.resolve(from: recognition(line("Harborview", y: 0.45))) == nil)
    }

    @Test func separatedRolesDoNotDisplaceStrongIssuer() throws {
        let identity = try #require(resolver.resolve(from: recognition(
            line("North Harbor Municipal Authority", y: 0.95),
            line("Utility Bill", y: 0.89),
            line("Account Summary", y: 0.83),
            line("AN EXAMPLE HOLDINGS COMPANY", y: 0.70),
            line("Blue River Energy Company provides your energy", y: 0.60),
            line("Remittance Processor Company", y: 0.54),
            line("Public Service Commission", y: 0.48),
            line("Household Assistance Program", y: 0.42)
        )))
        #expect(identity.issuer == "North Harbor Municipal Authority")
    }

    @Test func directIssuerExtractionRetainsPrecedence() {
        let direct = statement(.billIssuer, .text("Direct Source Utility"))
        let record = assembler.assemble(
            recognition: recognition(
                line("North Harbor Municipal Authority", y: 0.94),
                line("Utility Bill", y: 0.88)
            ),
            extraction: .init(statementProposals: [direct], serviceGroups: []),
            semanticGuided: emptyGuided
        )
        #expect(record.billIssuer == direct)
    }

    @Test func competingStrongIssuerEvidenceStillAbstains() {
        #expect(resolver.resolve(from: recognition(
            line("North Harbor Municipal Authority", y: 0.94),
            line("Blue River Utility District", y: 0.89),
            line("Utility Bill", y: 0.83)
        )) == nil)
    }

    @Test func adjacentHyphenatedBillDateResolvesWithProvenance() throws {
        let recognition = recognition(
            line("Bill Date", box: box(x: 0.08, y: 0.82, width: 0.20)),
            line("June-03-2021", box: box(x: 0.08, y: 0.77, width: 0.25))
        )
        let record = normalized(recognition)
        let proposal = try #require(record.statementDate)
        #expect(dateComponents(proposal.value) == DateComponents(year: 2021, month: 6, day: 3))
        #expect(proposal.provenance.snippet == "Bill Date · June-03-2021")
    }

    @Test func hyphenatedDueAndServiceDatesDoNotBecomeStatementDate() {
        for lines in [
            [line("Due Date", y: 0.82), line("June-03-2021", y: 0.77)],
            [line("Service Period", y: 0.82), line("May-01-2021 - June-01-2021", y: 0.77)],
        ] {
            #expect(normalized(recognition(lines)).statementDate == nil)
        }
    }

    @Test func unrelatedOrMissingDateEvidenceAbstains() {
        #expect(normalized(recognition(
            line("June-03-2021", y: 0.77),
            line("Account Summary", y: 0.70)
        )).statementDate == nil)
        #expect(normalized(recognition(line("Bill Summary", y: 0.82))).statementDate == nil)
    }

    @Test func competingExplicitBillDatesRemainAmbiguous() {
        let record = normalized(recognition(
            line("Bill Date", box: box(x: 0.08, y: 0.86, width: 0.20)),
            line("June-03-2021", box: box(x: 0.08, y: 0.82, width: 0.25)),
            line("Statement Date", box: box(x: 0.08, y: 0.70, width: 0.25)),
            line("June-04-2021", box: box(x: 0.08, y: 0.66, width: 0.25))
        ))
        #expect(record.statementDate == nil)
    }

    @Test func sameLineTotalDueResolvesAmountDue() throws {
        let record = normalized(recognition(line("Total Due $123.45", y: 0.72)))
        let proposal = try #require(record.totalAmountDue)
        #expect(proposal.value == .decimal(Decimal(string: "123.45")!))
        #expect(proposal.provenance.snippet == "Total Due $123.45")
    }

    @Test func splitTotalDueResolvesOnlyAssociatedStandaloneMoney() throws {
        let record = normalized(recognition(
            line("Total Due", box: box(x: 0.08, y: 0.72, width: 0.22)),
            line("$123.45", box: box(x: 0.50, y: 0.72, width: 0.15))
        ))
        let proposal = try #require(record.totalAmountDue)
        #expect(proposal.value == .decimal(Decimal(string: "123.45")!))
        #expect(proposal.provenance.snippet.contains("Total Due"))
        #expect(proposal.provenance.snippet.contains("$123.45"))
    }

    @Test(arguments: ["Total Due", "Total Duo"])
    func physicalRowGeometryResolvesBoundedAmountDueLabelVariant(_ label: String) throws {
        let labelBox = CGRect(x: 0.112500, y: 0.775215, width: 0.091667, height: 0.004466)
        let valueBox = CGRect(x: 0.395833, y: 0.772237, width: 0.075000, height: 0.008932)
        let record = normalized(recognition(
            line(label, box: labelBox),
            line("$155.52", box: valueBox)
        ))
        let proposal = try #require(record.totalAmountDue)

        #expect(proposal.value == .decimal(Decimal(string: "155.52")!))
        #expect(proposal.origin == .extracted)
        #expect(proposal.provenance.pageIndex == 0)
        #expect(proposal.provenance.sequenceIndex == nil)
        #expect(proposal.provenance.snippet == "\(label) | $155.52")
        #expect(proposal.provenance.normalizedBoundingBox == labelBox.union(valueBox))
        #expect(FirstBillSummaryAssembler().assemble(from: record).amountDue?.value
            == Decimal(string: "155.52"))
    }

    @Test func corruptedTotalDueLabelDoesNotBorrowDistantMoney() {
        let record = normalized(recognition(
            line("Total Duo", box: box(x: 0.10, y: 0.80, width: 0.20)),
            line("$155.52", box: box(x: 0.60, y: 0.20, width: 0.15))
        ))
        #expect(record.totalAmountDue == nil)
    }

    @Test func corruptedTotalDueLabelDoesNotBorrowSequenceDistantMoney() {
        let record = normalized(recognition(
            line("Total Duo", box: box(x: 0.10, y: 0.80, width: 0.20)),
            line("Account", box: box(x: 0.10, y: 0.70, width: 0.20)),
            line("Customer", box: box(x: 0.10, y: 0.60, width: 0.20)),
            line("Summary", box: box(x: 0.10, y: 0.50, width: 0.20)),
            line("$155.52", box: box(x: 0.45, y: 0.80, width: 0.15))
        ))
        #expect(record.totalAmountDue == nil)
    }

    @Test func corruptedTotalDueLabelWithCompetingMoneyAbstains() {
        let record = normalized(recognition(
            line("Total Duo", box: box(x: 0.10, y: 0.80, width: 0.20)),
            line("$155.52", box: box(x: 0.45, y: 0.80, width: 0.15)),
            line("$156.52", box: box(x: 0.63, y: 0.80, width: 0.15))
        ))
        #expect(record.totalAmountDue == nil)
    }

    @Test func otherMunicipalAmountsDoNotBecomeTotalDue() {
        let record = normalized(recognition(
            line("Previous Balance $80.00", y: 0.80),
            line("Payments -$20.00", y: 0.74),
            line("Adjustments $5.00", y: 0.68),
            line("Current Water $25.00", y: 0.62),
            line("Current Sewer $18.00", y: 0.56),
            line("Penalty $4.00", y: 0.50),
            line("Amount Enclosed $92.64", y: 0.44)
        ))
        #expect(record.totalAmountDue == nil)
    }

    @Test(arguments: [
        "Previous Balance", "Payments", "Current Water", "Current Sewer", "Amount Enclosed",
    ])
    func nonPayableTotalLabelsDoNotClaimAlignedMoney(_ label: String) {
        let record = normalized(recognition(
            line(label, box: box(x: 0.10, y: 0.70, width: 0.24)),
            line("$92.64", box: box(x: 0.50, y: 0.70, width: 0.15))
        ))
        #expect(record.totalAmountDue == nil)
    }

    @Test func physicalBillingPeriodAndDueDateEvidenceDoNotBecomeStatementDate() {
        let record = normalized(recognition(
            line("June-03-2021", y: 0.90),
            line("Bal Summary for this Metered Account for billina period", y: 0.86),
            line("June-03-2021 thru June-24-2021", y: 0.82),
            line("ACCOUNT NUMBER DUE DATE", y: 0.70),
            line("June-24-2021", y: 0.66)
        ))

        #expect(record.statementDate == nil)
    }

    @Test func unrelatedOrMissingMoneyEvidenceAbstains() {
        #expect(normalized(recognition(
            line("$123.45", y: 0.72),
            line("Bill Summary", y: 0.66)
        )).totalAmountDue == nil)
        #expect(normalized(recognition(line("Total Due", y: 0.72))).totalAmountDue == nil)
    }

    @Test func competingExplicitTotalDueAmountsRemainAmbiguous() {
        let record = normalized(recognition(
            line("Total Due $123.45", y: 0.72),
            line("Total Amount Due $124.45", y: 0.64)
        ))
        #expect(record.totalAmountDue == nil)
    }

    @Test func supportedBillFactsDoNotRequireIssuerOrService() throws {
        let recognition = recognition(
            line("Bill Date", box: box(x: 0.08, y: 0.82, width: 0.20)),
            line("June-03-2021", box: box(x: 0.08, y: 0.78, width: 0.25)),
            line("Total Due $123.45", y: 0.68)
        )
        let record = normalized(recognition)
        let summary = FirstBillSummaryAssembler().assemble(from: record)

        #expect(record.billIssuer == nil)
        #expect(record.services.isEmpty)
        #expect(dateComponents(try #require(record.statementDate).value)
            == DateComponents(year: 2021, month: 6, day: 3))
        #expect(record.statementDate?.origin == .extracted)
        #expect(record.statementDate?.provenance.snippet == "Bill Date · June-03-2021")
        #expect(record.totalAmountDue?.value == .decimal(Decimal(string: "123.45")!))
        #expect(record.totalAmountDue?.origin == .extracted)
        #expect(record.totalAmountDue?.provenance.snippet == "Total Due $123.45")
        #expect(summary.billIssuer == nil)
        #expect(summary.services.isEmpty)
        #expect(summary.statementDate?.provenance == record.statementDate?.provenance)
        #expect(summary.amountDue?.provenance == record.totalAmountDue?.provenance)
    }

    @Test func syntheticMunicipalStructureProducesOnlySupportedBillFacts() throws {
        let recognition = recognition(
            line("North Harbor Municipal Authority", y: 0.96),
            line("Department of Finance - Utility Billing", y: 0.91),
            line("Customer Name", y: 0.86),
            line("Account Number", y: 0.82),
            line("Bill Date", box: box(x: 0.08, y: 0.78, width: 0.18)),
            line("June-03-2021", box: box(x: 0.08, y: 0.74, width: 0.24)),
            line("Due Date June-24-2021", y: 0.70),
            line("Service Address", y: 0.66),
            line("Bill Summary", y: 0.62),
            line("Previous Balance $80.00", y: 0.58),
            line("Arustments $5.00", y: 0.54),
            line("Payments -$20.00", y: 0.50),
            line("Water charge detail $25.00", y: 0.46),
            line("Sewer charge detail $18.00", y: 0.42),
            line("Garbage $9.00", y: 0.38),
            line("Penalty $4.00", y: 0.34),
            line("Total Due", box: box(x: 0.08, y: 0.30, width: 0.20)),
            line("$121.00", box: box(x: 0.50, y: 0.30, width: 0.15)),
            line("Meter Information", y: 0.24)
        )
        let record = normalized(recognition)
        #expect(record.billIssuer?.value == .text("North Harbor Municipal Authority"))
        #expect(dateComponents(try #require(record.statementDate).value)
            == DateComponents(year: 2021, month: 6, day: 3))
        #expect(record.totalAmountDue?.value == .decimal(121))
        #expect(record.services.first { $0.serviceType == .electricity } == nil)
        #expect(record.services.first { $0.serviceType == .naturalGas } == nil)

        let summary = FirstBillSummaryAssembler().assemble(from: record)
        #expect(summary.billIssuer?.value == "North Harbor Municipal Authority")
        #expect(summary.statementDate != nil)
        #expect(summary.amountDue?.value == 121)
        #expect(summary.services.isEmpty)
    }

    @Test func municipalRecordsDoNotFabricateBillChangeServices() throws {
        let earlier = normalized(recognition(
            line("North Harbor Municipal Authority", y: 0.94),
            line("Bill Date May-03-2021", y: 0.84),
            line("Total Due $100.00", y: 0.74)
        ))
        let later = normalized(recognition(
            line("North Harbor Municipal Authority", y: 0.94),
            line("Bill Date June-03-2021", y: 0.84),
            line("Total Due $121.00", y: 0.74)
        ))
        let comparison = NormalizedBillComparisonAssembler().assemble(earlier, later)
        let change = NormalizedBillChangeAssembler().assemble(from: comparison)
        let summary = BillChangeSummaryAssembler().assemble(from: change)
        #expect(summary.services.isEmpty)
        #expect(!summary.hasCalculatedMetric)
    }

    private func normalized(_ recognition: DocumentRecognitionResult) -> NormalizedBillRecord {
        assembler.assemble(
            recognition: recognition,
            extraction: BillFieldExtractor().extract(from: recognition),
            semanticGuided: emptyGuided
        )
    }

    private func recognition(_ lines: RecognizedDocumentLine...) -> DocumentRecognitionResult {
        recognition(lines)
    }

    private func recognition(_ lines: [RecognizedDocumentLine]) -> DocumentRecognitionResult {
        .init(pages: [.init(pageIndex: 0, lines: lines, warnings: [])])
    }

    private func line(
        _ text: String,
        y: CGFloat? = nil,
        box: CGRect? = nil
    ) -> RecognizedDocumentLine {
        .init(
            text: text,
            normalizedBoundingBox: box ?? self.box(x: 0.08, y: y ?? 0.80, width: 0.70)
        )
    }

    private func box(x: CGFloat, y: CGFloat, width: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: width, height: 0.035)
    }

    private func statement(
        _ field: BillStatementFieldName,
        _ value: BillProposedValue
    ) -> BillStatementFieldProposal {
        .init(
            field: field,
            value: value,
            provenance: .init(
                pageIndex: 0,
                snippet: field.rawValue,
                normalizedBoundingBox: box(x: 0.1, y: 0.8, width: 0.5),
                sequenceIndex: 0
            ),
            origin: .extracted
        )
    }

    private func dateComponents(_ value: BillProposedValue) -> DateComponents? {
        guard case .date(let date) = value else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.dateComponents([.year, .month, .day], from: date)
    }
}
