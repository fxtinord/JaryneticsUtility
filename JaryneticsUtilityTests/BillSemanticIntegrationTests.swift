import CoreGraphics
import Testing
@testable import JaryneticsUtility

struct BillSemanticIntegrationTests {
    private let adapter = BillSemanticEvidenceAdapter()
    private let classifier = DeterministicBillSemanticClassifier()

    @Test
    func adapterPreservesRecognitionPageOrderTextAndGeometry() throws {
        let firstBox = CGRect(x: 0.10, y: 0.80, width: 0.30, height: 0.04)
        let secondBox = CGRect(x: 0.12, y: 0.70, width: 0.42, height: 0.05)
        let evidence = adapter.evidence(from: DocumentRecognitionResult(pages: [
            page(2, [
                line("SUPPLY", box: firstBox),
                line("Example Supplier provides your energy", box: secondBox),
            ]),
        ]))

        #expect(evidence.count == 2)
        #expect(evidence[0].pageIndex == 2)
        #expect(evidence[0].sequenceIndex == 0)
        #expect(evidence[0].sourceText == "SUPPLY")
        #expect(evidence[0].region?.normalizedBoundingBox == firstBox)
        #expect(evidence[1].sequenceIndex == 1)
        #expect(evidence[1].sourceText == "Example Supplier provides your energy")
        #expect(evidence[1].region?.normalizedBoundingBox == secondBox)
    }

    @Test
    func arbitraryCompanyNamesClassifyEquivalentlyForElectricDelivery() {
        let first = classify("DELIVERY", "Example Utility delivers electricity to your home")
        let second = classify("DELIVERY", "Another Company delivers electricity to your home")

        let expected: Set<BillSemanticConcept> = [
            .electricityService, .deliveryCharges, .deliveryUtility,
        ]
        #expect(expected.isSubset(of: Set(first.candidates.map(\.concept))))
        #expect(first.candidates.map(\.concept) == second.candidates.map(\.concept))
    }

    @Test
    func usageHeadingClassifiesContextWithoutCreatingQuantity() throws {
        let classification = classify("TOTAL USAGE (kWh)")
        let usage = try #require(classification.candidate(for: .electricityUsage))

        #expect(classification.candidate(for: .currentUsage) != nil)
        #expect(usage.supportingEvidence.map(\.sourceText) == ["TOTAL USAGE (kWh)"])
        #expect(Mirror(reflecting: usage).children.compactMap(\.label).contains("value") == false)
    }

    @Test
    func nearbySupplyHeadingAndRoleLanguageProvideGroupedEvidence() throws {
        let classification = classify(
            "SUPPLY",
            "Example Supplier provides your energy"
        )
        let supplier = try #require(classification.candidate(for: .energySupplier))
        let supply = try #require(classification.candidate(for: .supplyCharges))

        #expect(supplier.confidence == .strong)
        #expect(supplier.supportingEvidence.map(\.sourceText) == [
            "Example Supplier provides your energy", "SUPPLY",
        ])
        #expect(supply.supportingEvidence.count == 2)
    }

    @Test
    func conventionalBillLanguageMapsToProviderNeutralContexts() {
        let classification = classify(
            "SERVICE FROM 12/8/25 THROUGH 1/9/26",
            "CURRENT CHARGES SUMMARY",
            "TAXES, FEES & OTHER CREDITS",
            "METER INFORMATION",
            "Budget Billing Details"
        )

        #expect(classification.candidate(for: .billingPeriod) != nil)
        #expect(classification.candidate(for: .currentCharges) != nil)
        #expect(classification.candidate(for: .taxesFeesAndOtherCredits) != nil)
        #expect(classification.candidate(for: .meterInformation) != nil)
        #expect(classification.candidate(for: .budgetBilling) != nil)
    }

    @Test
    func periodClassificationDoesNotAssertTrustedDates() throws {
        let candidate = try #require(
            classify("SERVICE FROM 12/8/25 THROUGH 1/9/26")
                .candidate(for: .billingPeriod)
        )

        #expect(candidate.supportingEvidence.first?.sourceText
            == "SERVICE FROM 12/8/25 THROUGH 1/9/26")
        #expect(Mirror(reflecting: candidate).children.compactMap(\.label).contains("value") == false)
    }

    @Test
    func emergencyRenewableAndCompanyNamesAloneCreateNoForbiddenMeaning() {
        let classification = classify(
            "GAS EMERGENCIES",
            "OUTAGE AND ELECTRIC EMERGENCIES",
            "Emergency telephone 555-0100",
            "Electric Service means the delivery of electrical energy",
            "Solar Choice",
            "Renewable energy enrollment",
            "Example Utility",
            "Another Supplier"
        )

        #expect(classification.candidate(for: .electricityService) == nil)
        #expect(classification.candidate(for: .naturalGasService) == nil)
        #expect(classification.candidate(for: .netMetering) == nil)
        #expect(classification.candidate(for: .energySupplier) == nil)
        #expect(classification.candidate(for: .deliveryUtility) == nil)
    }

    @Test
    func parallelSemanticInterpretationDoesNotChangeProductionExtraction() {
        let recognition = DocumentRecognitionResult(pages: [page(0, [
            line("DELIVERY"),
            line("Example Utility delivers electricity to your home"),
            line("TOTAL USAGE (kWh)"),
        ])])
        let extractor = BillFieldExtractor()
        let before = extractor.extract(from: recognition)

        _ = classifier.classify(adapter.evidence(from: recognition))

        #expect(extractor.extract(from: recognition) == before)
    }

    private func classify(_ texts: String...) -> BillSemanticClassification {
        let recognition = DocumentRecognitionResult(pages: [page(0, texts.map { line($0) })])
        return classifier.classify(adapter.evidence(from: recognition))
    }

    private func page(
        _ index: Int,
        _ lines: [RecognizedDocumentLine]
    ) -> RecognizedDocumentPage {
        RecognizedDocumentPage(pageIndex: index, lines: lines, warnings: [])
    }

    private func line(
        _ text: String,
        box: CGRect = CGRect(x: 0.1, y: 0.8, width: 0.7, height: 0.05)
    ) -> RecognizedDocumentLine {
        RecognizedDocumentLine(text: text, normalizedBoundingBox: box)
    }
}
