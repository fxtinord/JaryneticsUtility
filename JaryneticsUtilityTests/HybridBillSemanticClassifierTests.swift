import CoreGraphics
import Foundation
import SwiftData
import Testing
@testable import JaryneticsUtility

@MainActor
struct HybridBillSemanticClassifierTests {
    private let classifier = HybridBillSemanticClassifier(
        similarity: UnavailableSimilarity()
    )

    @Test
    func normalizerHandlesCasePunctuationWhitespaceAndOCRLetterFragmentation() {
        let normalizer = BillLanguageNormalizer()
        let normalized = normalizer.normalize("  YOUR—E L E C T R I C I T Y   BILL  ")

        #expect(normalized.tokens.contains("electricity"))
        #expect(normalized.tokens.contains("bill"))
        #expect(normalized.text == "your electricity bill")
    }

    @Test
    func electricityLanguageVariantsMapConsistently() {
        for phrase in [
            "Electric Service",
            "Your electricity bill",
            "new charges for electricity",
            "Your Electricity Breakdown",
            "Electric Meter Detail",
        ] {
            #expect(classify(phrase).candidate(for: .electricityService) != nil)
        }
        #expect(classify("Electric Meter Detail").candidate(for: .meterInformation) != nil)
    }

    @Test
    func naturalGasLanguageVariantsMapConsistently() {
        for phrase in [
            "Natural Gas Service",
            "Residential Gas Service",
            "Current Charges - Gas Service",
            "Gas Meter Detail",
        ] {
            #expect(classify(phrase).candidate(for: .naturalGasService) != nil)
        }
        #expect(classify("Gas Meter Detail").candidate(for: .meterInformation) != nil)
    }

    @Test
    func usageAndSupportedUnitsEstablishContextButNoQuantity() throws {
        for phrase in ["TOTAL USAGE (kWh)", "Electric usage", "Usage 36 therms", "Consumption 2 DTH"] {
            let classification = classify(phrase)
            #expect(classification.candidate(for: .currentUsage) != nil)
        }
        let candidate = try #require(classify("Usage 36 therms").candidate(for: .naturalGasUsage))
        #expect(Mirror(reflecting: candidate).children.compactMap(\.label).contains("value") == false)
        #expect(candidate.supportingEvidence.first?.sourceText == "Usage 36 therms")
    }

    @Test
    func chargeStructureVariantsClassifyProviderNeutrally() {
        #expect(classify("Your Supply Charges").candidate(for: .supplyCharges) != nil)
        #expect(classify("Your Delivery Charges").candidate(for: .deliveryCharges) != nil)
        #expect(classify("Distribution Charges").candidate(for: .deliveryCharges) != nil)
        #expect(classify("Taxes, Fees & Other Credits")
            .candidate(for: .taxesFeesAndOtherCredits) != nil)
    }

    @Test
    func electricityAndGasRemainDistinctInOneDocument() {
        let classification = classify(
            "Your Electricity Breakdown",
            "Your Gas Breakdown",
            "Electric Meter Detail",
            "Gas Meter Detail"
        )

        #expect(classification.candidate(for: .electricityService) != nil)
        #expect(classification.candidate(for: .naturalGasService) != nil)
    }

    @Test
    func arbitraryCompanyNamesDoNotChangeRoleClassification() {
        let first = classify("Example Utility delivers electricity to your home")
        let second = classify("Another Company delivers electricity to your home")

        #expect(first.candidates.map(\.concept) == second.candidates.map(\.concept))
        #expect(first.candidate(for: .deliveryUtility) != nil)
    }

    @Test
    func negativeContextsAbstainBeforeScoringOrSimilarity() {
        for phrase in [
            "GAS EMERGENCIES",
            "OUTAGE AND ELECTRIC EMERGENCIES",
            "Payment assistance for your electric bill",
            "Energy efficiency tips for gas heating",
            "Electric service means energy delivered to a home",
            "Solar Choice renewable energy enrollment",
            "Green-energy program",
        ] {
            #expect(classify(phrase).candidates.isEmpty)
        }
    }

    @Test
    func explanatoryAndAssistanceContextsDoNotBecomeBillEvidence() {
        #expect(classify("Understanding Your Gas Bill").candidate(for: .naturalGasService) == nil)
        #expect(classify("Definition: Electric Service is energy delivered to a premise")
            .candidate(for: .electricityService) == nil)
        #expect(classify("Payment help is available if your electricity is at risk")
            .candidate(for: .electricityService) == nil)
    }

    @Test
    func glossaryContextSuppressesFollowingOperationalVocabulary() {
        let classification = classify(
            "Glossary / Definitions",
            "Basic Service Fee includes meter reading and billing"
        )

        #expect(classification.candidate(for: .meterInformation) == nil)
        #expect(classification.candidate(for: .electricityService) == nil)
        #expect(classification.candidate(for: .naturalGasService) == nil)
    }

    @Test
    func directCurrentBillEvidenceRemainsValid() {
        #expect(classify("Your electricity bill").candidate(for: .electricityService) != nil)
        #expect(classify("Current Charges - Gas Service")
            .candidate(for: .naturalGasService) != nil)
        #expect(classify("Residential Gas Service")
            .candidate(for: .naturalGasService) != nil)
    }

    @Test
    func explanatorySectionCanBeFollowedByIndependentCurrentBillEvidence() {
        let classification = classify(
            "Understanding Your Gas Bill",
            "Gas service means the delivery of fuel",
            "Your electricity bill"
        )

        #expect(classification.candidate(for: .naturalGasService) == nil)
        #expect(classification.candidate(for: .electricityService) != nil)
    }

    @Test
    func multiServiceUsageKeepsServiceSpecificConceptsWithoutGenericMerge() {
        let classification = classify(
            "Electric usage 120 kWh",
            "Gas usage 4 therms"
        )

        #expect(classification.candidate(for: .electricityUsage) != nil)
        #expect(classification.candidate(for: .naturalGasUsage) != nil)
        #expect(classification.candidate(for: .currentUsage) == nil)
    }

    @Test
    func incompatibleServiceEvidenceOnOneLineAbstains() {
        let classification = classify("Electric and gas service information")

        #expect(classification.candidate(for: .electricityService) == nil)
        #expect(classification.candidate(for: .naturalGasService) == nil)
    }

    @Test
    func boundedSimilarityRequiresThresholdAndClearSeparation() {
        let clear = HybridBillSemanticClassifier(similarity: FixedSimilarity(distances: [
            "electricity service bill": 0.20,
            "natural gas service bill": 0.48,
        ]))
        let ambiguous = HybridBillSemanticClassifier(similarity: FixedSimilarity(distances: [
            "electricity service bill": 0.20,
            "natural gas service bill": 0.24,
        ]))

        #expect(clear.classify(evidence("power service bill overview"))
            .candidate(for: .electricityService) != nil)
        #expect(ambiguous.classify(evidence("power service bill overview")).candidates.isEmpty)
        #expect(clear.classify(evidence("Example Energy Company")).candidates.isEmpty)
    }

    @Test
    func semanticInterpretationDoesNotChangeExtraction() {
        let recognition = recognition(
            "Your electricity bill",
            "Your Supply Charges",
            "TOTAL USAGE (kWh)"
        )
        let extractor = BillFieldExtractor()
        let before = extractor.extract(from: recognition)

        _ = classifier.classify(recognition)

        #expect(extractor.extract(from: recognition) == before)
    }

    @Test
    func semanticInterpretationDoesNotMutatePersistenceOrVerification() throws {
        let schema = Schema([
            Household.self, UtilityService.self, UtilityBill.self,
            UtilityBillServiceDetail.self, DistributedEnergyDetail.self, SourceDocument.self,
        ])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let household = Household(name: "Synthetic Household")
        let service = UtilityService(
            serviceType: .electricity,
            providerName: "Synthetic Provider",
            household: household
        )
        let bill = UtilityBill(amountDue: Decimal(42), verificationState: .needsReview)
        let detail = UtilityBillServiceDetail(
            utilityBill: bill,
            utilityService: service,
            usageQuantity: Decimal(100),
            usageUnit: "kWh"
        )
        container.mainContext.insert(bill)
        container.mainContext.insert(detail)
        try container.mainContext.save()

        _ = classifier.classify(recognition("Your electricity bill", "Electric usage 100 kWh"))

        let context = ModelContext(container)
        let storedBill = try #require(context.fetch(FetchDescriptor<UtilityBill>()).first)
        let storedService = try #require(context.fetch(FetchDescriptor<UtilityService>()).first)
        let storedDetail = try #require(
            context.fetch(FetchDescriptor<UtilityBillServiceDetail>()).first
        )
        #expect(storedBill.amountDue == Decimal(42))
        #expect(storedBill.verificationState == .needsReview)
        #expect(storedService.providerName == "Synthetic Provider")
        #expect(storedDetail.usageQuantity == Decimal(100))
        #expect(storedDetail.usageUnit == "kWh")
        #expect(storedDetail.distributedEnergyDetail == nil)
    }

    private func classify(_ texts: String...) -> BillSemanticClassification {
        classifier.classify(recognition(texts))
    }

    private func recognition(_ texts: String...) -> DocumentRecognitionResult {
        recognition(texts)
    }

    private func recognition(_ texts: [String]) -> DocumentRecognitionResult {
        DocumentRecognitionResult(pages: [
            RecognizedDocumentPage(
                pageIndex: 0,
                lines: texts.map {
                    RecognizedDocumentLine(
                        text: $0,
                        normalizedBoundingBox: CGRect(x: 0.1, y: 0.8, width: 0.7, height: 0.05)
                    )
                },
                warnings: []
            ),
        ])
    }

    private func evidence(_ text: String) -> [BillSemanticEvidence] {
        BillSemanticEvidenceAdapter().evidence(from: recognition(text))
    }
}

private struct UnavailableSimilarity: BillSemanticSimilarityProviding {
    func distance(between source: String, and canonicalDescription: String) -> Double? { nil }
}

private struct FixedSimilarity: BillSemanticSimilarityProviding {
    let distances: [String: Double]

    func distance(between source: String, and canonicalDescription: String) -> Double? {
        distances[canonicalDescription] ?? 0.80
    }
}
