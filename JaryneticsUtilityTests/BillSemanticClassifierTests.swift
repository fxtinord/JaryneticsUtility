import CoreGraphics
import Foundation
import SwiftData
import Testing
@testable import JaryneticsUtility

@MainActor
struct BillSemanticClassifierTests {
    private let classifier = DeterministicBillSemanticClassifier()

    @Test
    func multiplePhrasingsClassifyToCanonicalElectricityService() throws {
        for phrase in [
            "Electric Service",
            "Electricity Service",
            "Example Utility delivers electricity to your home",
        ] {
            let candidate = try #require(
                classifier.classify(recognition(phrase)).candidate(for: .electricityService)
            )
            #expect(candidate.confidence == .strong)
        }

        let usage = classifier.classify(recognition("TOTAL USAGE (kWh)"))
        #expect(usage.candidate(for: .electricityUsage)?.confidence == .strong)
    }

    @Test
    func providerNameIsIrrelevantToServiceDescriptionRule() {
        let first = classifier.classify(recognition(
            "Example Utility delivers electricity to your home"
        ))
        let second = classifier.classify(recognition(
            "Another Company delivers electricity to your home"
        ))

        #expect(first.candidates.map(\.concept) == second.candidates.map(\.concept))
        #expect(first.candidate(for: .electricityService) != nil)
    }

    @Test
    func sourcePageSequenceTextAndGeometryArePreserved() throws {
        let box = CGRect(x: 0.12, y: 0.48, width: 0.42, height: 0.05)
        let classification = classifier.classify(DocumentRecognitionResult(pages: [
            page(4, [
                line("Unrelated heading"),
                line("Natural Gas Service", box: box),
            ]),
        ]))
        let evidence = try #require(
            classification.candidate(for: .naturalGasService)?.supportingEvidence.first
        )

        #expect(evidence.pageIndex == 4)
        #expect(evidence.sequenceIndex == 1)
        #expect(evidence.sourceText == "Natural Gas Service")
        #expect(evidence.region?.normalizedBoundingBox == box)
    }

    @Test
    func multipleLinesCanSupportOneSemanticCandidate() throws {
        let classification = classifier.classify(recognition(
            "Electric Service",
            "Example Utility delivers electricity to your home"
        ))
        let candidate = try #require(classification.candidate(for: .electricityService))

        #expect(candidate.supportingEvidence.count == 2)
        #expect(candidate.reasons == [.explicitServiceLabel, .serviceDescription])
    }

    @Test
    func gasUsageAndChargeHeadingsMapToCanonicalConcepts() {
        let classification = classifier.classify(recognition(
            "Natural Gas Service",
            "Gas Usage This Period: 36 therms",
            "SUPPLY",
            "DELIVERY",
            "DISTRIBUTION",
            "TAXES, FEES & OTHER CREDITS"
        ))

        #expect(classification.candidate(for: .naturalGasService) != nil)
        #expect(classification.candidate(for: .naturalGasUsage) != nil)
        #expect(classification.candidate(for: .supplyCharges) != nil)
        #expect(classification.candidate(for: .deliveryCharges) != nil)
        #expect(classification.candidate(for: .distributionCharges) != nil)
        #expect(classification.candidate(for: .taxesFeesAndOtherCredits) != nil)
    }

    @Test
    func emergencySafetyAndCustomerServiceTextDoNotEstablishService() {
        let classification = classifier.classify(recognition(
            "GAS EMERGENCIES",
            "OUTAGE AND ELECTRIC EMERGENCIES",
            "For customer-service telephone assistance call 555-0100"
        ))

        #expect(classification.candidate(for: .electricityService) == nil)
        #expect(classification.candidate(for: .naturalGasService) == nil)
    }

    @Test
    func renewableProgramWordingDoesNotEstablishNetMetering() {
        let classification = classifier.classify(recognition(
            "Solar Choice",
            "Renewable energy program"
        ))

        #expect(classification.candidate(for: .netMetering) == nil)
    }

    @Test
    func semanticCandidateClassifiesMeaningWithoutTrustedNumericValue() throws {
        let candidate = try #require(
            classifier.classify(recognition(
                "Gas Usage This Period: 36 therms"
            )).candidate(for: .naturalGasUsage)
        )

        #expect(candidate.concept == .naturalGasUsage)
        #expect(candidate.supportingEvidence.first?.sourceText == "Gas Usage This Period: 36 therms")
        #expect(Set(Mirror(reflecting: candidate).children.compactMap(\.label)) == [
            "concept", "confidence", "supportingEvidence", "reasons",
        ])
    }

    @Test
    func semanticClassificationDoesNotChangeExtractionResult() {
        let input = recognition(
            "Electric Service",
            "Total Usage: 123 kWh",
            "Current Electric Charges: $45.67"
        )
        let extractor = BillFieldExtractor()
        let before = extractor.extract(from: input)

        _ = classifier.classify(input)

        #expect(extractor.extract(from: input) == before)
    }

    @Test
    func semanticClassificationDoesNotMutatePersistedModels() throws {
        let container = try makeContainer()
        let household = Household(name: "Synthetic Household")
        let service = UtilityService(
            serviceType: .electricity,
            providerName: "Synthetic Provider",
            household: household
        )
        let bill = UtilityBill(
            amountDue: Decimal(string: "55.01"),
            verificationState: .needsReview
        )
        let detail = UtilityBillServiceDetail(
            utilityBill: bill,
            utilityService: service,
            usageQuantity: Decimal(123),
            usageUnit: "kWh"
        )
        container.mainContext.insert(bill)
        container.mainContext.insert(detail)
        try container.mainContext.save()

        _ = classifier.classify(recognition("Electric Service", "TOTAL USAGE (kWh)"))

        let verificationContext = ModelContext(container)
        let storedBill = try #require(
            verificationContext.fetch(FetchDescriptor<UtilityBill>()).first
        )
        let storedDetail = try #require(
            verificationContext.fetch(FetchDescriptor<UtilityBillServiceDetail>()).first
        )
        #expect(storedBill.amountDue == Decimal(string: "55.01"))
        #expect(storedBill.verificationState == .needsReview)
        #expect(storedDetail.usageQuantity == Decimal(123))
        #expect(storedDetail.usageUnit == "kWh")
    }

    private func recognition(_ texts: String...) -> DocumentRecognitionResult {
        DocumentRecognitionResult(pages: [page(0, texts.map { line($0) })])
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

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Household.self,
            UtilityService.self,
            UtilityBill.self,
            UtilityBillServiceDetail.self,
            DistributedEnergyDetail.self,
            SourceDocument.self,
        ])
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
    }
}
