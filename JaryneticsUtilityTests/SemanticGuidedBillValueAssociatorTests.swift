import CoreGraphics
import Foundation
import SwiftData
import Testing
@testable import JaryneticsUtility

@MainActor
struct SemanticGuidedBillValueAssociatorTests {
    private let classifier = HybridBillSemanticClassifier(similarity: NoSimilarity())
    private let associator = SemanticGuidedBillValueAssociator()

    @Test
    func associatesUniqueElectricityUsageWithExactProvenance() throws {
        let valueBox = box(x: 0.55, y: 0.80)
        let result = associate(
            line("TOTAL USAGE (kWh)", box: box(x: 0.10, y: 0.80)),
            line("642 kWh", box: valueBox)
        )
        let group = try #require(result.serviceAssociation(for: .electricity))
        let quantity = try #require(group.proposal(for: .usageQuantity))

        #expect(quantity.value == .decimal(642))
        #expect(group.proposal(for: .usageUnit)?.value == .text("kWh"))
        #expect(quantity.provenance.pageIndex == 0)
        #expect(quantity.provenance.sequenceIndex == 1)
        #expect(quantity.provenance.normalizedBoundingBox == valueBox)
        #expect(quantity.provenance.snippet == "TOTAL USAGE (kWh) · 642 kWh")
        #expect(quantity.origin == .extracted)
    }

    @Test
    func associatesUniqueNaturalGasUsage() {
        let result = associate(
            line("Gas Usage", box: box(x: 0.10, y: 0.70)),
            line("36 therms", box: box(x: 0.55, y: 0.70))
        )

        #expect(result.serviceAssociation(for: .naturalGas)?
            .proposal(for: .usageQuantity)?.value == .decimal(36))
        #expect(result.serviceAssociation(for: .naturalGas)?
            .proposal(for: .usageUnit)?.value == .text("therms"))
    }

    @Test
    func crossPageSemanticElectricityContextFindsExplicitCurrentUsageRow() throws {
        let result = associate(pages: [
            [line("Electric usage rate information", box: box(x: 0.10, y: 0.80))],
            [
                line("Total Usage", box: box(x: 0.10, y: 0.70)),
                line("152.041000 kWh", box: box(x: 0.55, y: 0.70)),
            ],
        ])
        let proposal = try #require(result.serviceAssociation(for: .electricity)?
            .proposal(for: .usageQuantity))

        #expect(proposal.value == .decimal(Decimal(string: "152.041000")!))
        #expect(proposal.provenance.pageIndex == 1)
        #expect(proposal.provenance.sequenceIndex == 1)
        #expect(proposal.provenance.snippet == "Total Usage · 152.041000 kWh")
    }

    @Test
    func explanatoryUsageEvidenceIsNeverTheNumericSource() throws {
        let explanatoryBox = box(x: 0.10, y: 0.80)
        let valueBox = box(x: 0.55, y: 0.70)
        let result = associate(pages: [
            [line("Electric usage rate information", box: explanatoryBox)],
            [
                line("Total Usage", box: box(x: 0.10, y: 0.70)),
                line("152.041000 kWh", box: valueBox),
            ],
        ])
        let proposal = try #require(result.serviceAssociation(for: .electricity)?
            .proposal(for: .usageQuantity))

        #expect(proposal.provenance.pageIndex == 1)
        #expect(proposal.provenance.normalizedBoundingBox == valueBox)
        #expect(proposal.provenance.normalizedBoundingBox != explanatoryBox)
    }

    @Test
    func historicalAndAverageDailyUsageAreExcludedFromStructuralSearch() {
        let result = associate(pages: [
            [line("Your electricity bill", box: box(x: 0.10, y: 0.90))],
            [
                line("Total Usage", box: box(x: 0.10, y: 0.70)),
                line("Average Daily Usage 5 kWh", box: box(x: 0.55, y: 0.71)),
                line("Previous Usage 600 kWh", box: box(x: 0.55, y: 0.69)),
                line("152.041000 kWh", box: box(x: 0.55, y: 0.70)),
            ],
        ])

        #expect(result.serviceAssociation(for: .electricity)?
            .proposal(for: .usageQuantity)?.value == .decimal(Decimal(string: "152.041000")!))
    }

    @Test
    func ambiguousElectricityUsageAbstains() {
        let result = associate(
            line("Electric Usage", box: box(x: 0.10, y: 0.80)),
            line("642 kWh", box: box(x: 0.55, y: 0.81)),
            line("700 kWh", box: box(x: 0.55, y: 0.79))
        )

        #expect(result.serviceAssociation(for: .electricity) == nil)
    }

    @Test
    func incompatibleUnitsCannotCrossServiceOwnership() {
        let electricity = associate(
            line("Electric Usage", box: box(x: 0.10, y: 0.80)),
            line("36 therms", box: box(x: 0.55, y: 0.80))
        )
        let gas = associate(
            line("Gas Usage", box: box(x: 0.10, y: 0.80)),
            line("642 kWh", box: box(x: 0.55, y: 0.80))
        )

        #expect(electricity.serviceAssociations.isEmpty)
        #expect(gas.serviceAssociations.isEmpty)
    }

    @Test
    func combinedBillKeepsElectricityAndGasUsageSeparate() {
        let result = associate(
            line("Electric Usage", box: box(x: 0.10, y: 0.85)),
            line("642 kWh", box: box(x: 0.55, y: 0.85)),
            line("Gas Usage", box: box(x: 0.10, y: 0.55)),
            line("36 therms", box: box(x: 0.55, y: 0.55))
        )

        #expect(result.serviceAssociation(for: .electricity)?
            .proposal(for: .usageQuantity)?.value == .decimal(642))
        #expect(result.serviceAssociation(for: .naturalGas)?
            .proposal(for: .usageQuantity)?.value == .decimal(36))
    }

    @Test
    func associatesElectricityCurrentPeriodCharge() {
        let result = associate(
            line("Current Charges - Electric Service", box: box(x: 0.10, y: 0.80)),
            line("$71.25", box: box(x: 0.65, y: 0.80))
        )

        #expect(result.serviceAssociation(for: .electricity)?
            .proposal(for: .currentPeriodCharges)?.value == .decimal(Decimal(string: "71.25")!))
    }

    @Test
    func associatesNaturalGasCurrentPeriodCharge() {
        let result = associate(
            line("Current Charges - Gas Service", box: box(x: 0.10, y: 0.70)),
            line("$40.22", box: box(x: 0.65, y: 0.70))
        )

        #expect(result.serviceAssociation(for: .naturalGas)?
            .proposal(for: .currentPeriodCharges)?.value == .decimal(Decimal(string: "40.22")!))
    }

    @Test
    func crossPageExplicitElectricServiceTotalAssociatesCharge() {
        let result = associate(pages: [
            [line("Your electricity bill", box: box(x: 0.10, y: 0.90))],
            [
                line("Total Electric Charges", box: box(x: 0.10, y: 0.70)),
                line("$29.30", box: box(x: 0.65, y: 0.70)),
            ],
        ])

        #expect(result.serviceAssociation(for: .electricity)?
            .proposal(for: .currentPeriodCharges)?.value
            == .decimal(Decimal(string: "29.30")!))
    }

    @Test
    func crossPageExplicitGasServiceTotalAssociatesCharge() {
        let result = associate(pages: [
            [line("Residential Gas Service", box: box(x: 0.10, y: 0.90))],
            [
                line("Total Gas Charges", box: box(x: 0.10, y: 0.70)),
                line("$40.22", box: box(x: 0.65, y: 0.70)),
            ],
        ])

        #expect(result.serviceAssociation(for: .naturalGas)?
            .proposal(for: .currentPeriodCharges)?.value
            == .decimal(Decimal(string: "40.22")!))
    }

    @Test
    func gasChargeUsesVisualRowWhenOCRSequenceIsSeparated() throws {
        let valueBox = CGRect(x: 0.66, y: 0.680, width: 0.18, height: 0.010)
        let result = associate(
            line(
                "Total Gas Charges",
                box: CGRect(x: 0.10, y: 0.700, width: 0.32, height: 0.010)
            ),
            line("Unrelated column heading", box: box(x: 0.10, y: 0.60)),
            line("Unrelated detail", box: box(x: 0.10, y: 0.55)),
            line("Another OCR observation", box: box(x: 0.10, y: 0.50)),
            line("$40.22", box: valueBox)
        )
        let proposal = try #require(result.serviceAssociation(for: .naturalGas)?
            .proposal(for: .currentPeriodCharges))

        #expect(proposal.value == .decimal(Decimal(string: "40.22")!))
        #expect(proposal.provenance.sequenceIndex == 4)
        #expect(proposal.provenance.normalizedBoundingBox == valueBox)
    }

    @Test
    func statementAmountDueCannotBecomeServiceCharge() {
        let result = associate(
            line("Electric Service", box: box(x: 0.10, y: 0.85)),
            line("CURRENT CHARGES SUMMARY", box: box(x: 0.10, y: 0.75)),
            line("TOTAL AMOUNT DUE $200.00", box: box(x: 0.55, y: 0.75))
        )

        #expect(result.serviceAssociation(for: .electricity) == nil)
    }

    @Test
    func chargeComponentsAreNeverSummedIntoCurrentCharge() {
        let result = associate(
            line("Current Charges - Electric Service", box: box(x: 0.10, y: 0.80)),
            line("$10.00", box: box(x: 0.55, y: 0.81)),
            line("$20.00", box: box(x: 0.55, y: 0.79))
        )

        #expect(result.serviceAssociation(for: .electricity) == nil)
    }

    @Test
    func conflictingGeometryAndServiceOwnershipAbstains() {
        let result = associate(
            line("Current Charges - Electric Service", box: box(x: 0.10, y: 0.80)),
            line("Current Charges - Gas Service", box: box(x: 0.10, y: 0.80)),
            line("$50.00", box: box(x: 0.65, y: 0.80))
        )

        #expect(result.serviceAssociations.isEmpty)
    }

    @Test
    func semanticContextWithoutNumericCandidateCreatesNoProposal() {
        let result = associate(line("TOTAL USAGE (kWh)", box: box(x: 0.10, y: 0.80)))

        #expect(result.serviceAssociations.isEmpty)
    }

    @Test
    func ambiguousCrossPageCurrentUsageCandidatesCauseAbstention() {
        let result = associate(pages: [
            [line("Your electricity bill", box: box(x: 0.10, y: 0.90))],
            [
                line("Total Usage", box: box(x: 0.10, y: 0.70)),
                line("152 kWh", box: box(x: 0.55, y: 0.71)),
                line("153 kWh", box: box(x: 0.55, y: 0.69)),
            ],
        ])

        #expect(result.serviceAssociation(for: .electricity) == nil)
    }

    @Test
    func associationDoesNotMutatePersistenceOrVerificationState() throws {
        let schema = Schema([
            Household.self, UtilityService.self, UtilityBill.self,
            UtilityBillServiceDetail.self, DistributedEnergyDetail.self, SourceDocument.self,
        ])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let bill = UtilityBill(amountDue: Decimal(88), verificationState: .needsReview)
        let household = Household(name: "Synthetic Household")
        let service = UtilityService(
            serviceType: .electricity,
            providerName: "Synthetic",
            household: household
        )
        let detail = UtilityBillServiceDetail(
            utilityBill: bill,
            utilityService: service,
            currentPeriodCharges: Decimal(12),
            usageQuantity: Decimal(10),
            usageUnit: "kWh"
        )
        container.mainContext.insert(bill)
        container.mainContext.insert(detail)
        try container.mainContext.save()

        _ = associate(
            line("Electric Usage", box: box(x: 0.10, y: 0.80)),
            line("642 kWh", box: box(x: 0.55, y: 0.80))
        )

        let context = ModelContext(container)
        let storedBill = try #require(context.fetch(FetchDescriptor<UtilityBill>()).first)
        let storedDetail = try #require(
            context.fetch(FetchDescriptor<UtilityBillServiceDetail>()).first
        )
        #expect(storedBill.amountDue == Decimal(88))
        #expect(storedBill.verificationState == .needsReview)
        #expect(storedDetail.currentPeriodCharges == Decimal(12))
        #expect(storedDetail.usageQuantity == Decimal(10))
        #expect(storedDetail.usageUnit == "kWh")
        #expect(storedDetail.distributedEnergyDetail == nil)
    }

    private func associate(_ lines: RecognizedDocumentLine...) -> SemanticGuidedAssociationResult {
        associate(pages: [lines])
    }

    private func associate(
        pages: [[RecognizedDocumentLine]]
    ) -> SemanticGuidedAssociationResult {
        let recognition = DocumentRecognitionResult(pages: pages.enumerated().map {
            RecognizedDocumentPage(pageIndex: $0.offset, lines: $0.element, warnings: [])
        })
        return associator.associate(
            recognition: recognition,
            semantics: classifier.classify(recognition)
        )
    }

    private func line(_ text: String, box: CGRect) -> RecognizedDocumentLine {
        RecognizedDocumentLine(text: text, normalizedBoundingBox: box)
    }

    private func box(x: CGFloat, y: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: 0.28, height: 0.04)
    }
}

private struct NoSimilarity: BillSemanticSimilarityProviding {
    func distance(between source: String, and canonicalDescription: String) -> Double? { nil }
}
