import CoreGraphics
import Foundation
import SwiftData
import Testing
@testable import JaryneticsUtility

@MainActor
struct NormalizedBillComparisonTests {
    private let assembler = NormalizedBillComparisonAssembler()

    @Test
    func chronologicalOrderingUsesStatementDates() throws {
        let august = record(date: try sourceDate(2025, 8, 15), issuer: "North Valley Energy")
        let september = record(date: try sourceDate(2025, 9, 15), issuer: "North Valley Energy")
        let comparison = assembler.assemble(september, august)

        #expect(comparison.chronology == .ordered)
        #expect(comparison.earlierBill == august)
        #expect(comparison.laterBill == september)
        #expect(comparison.billLevel?.issuer.earlier == august.billIssuer)
        #expect(comparison.billLevel?.issuer.later == september.billIssuer)
    }

    @Test
    func reversedInputsProduceSameSemanticOrdering() throws {
        let earlier = record(date: try sourceDate(2025, 1, 1), amountDue: 40)
        let later = record(date: try sourceDate(2025, 2, 1), amountDue: 55)
        let forward = assembler.assemble(earlier, later)
        let reversed = assembler.assemble(later, earlier)

        #expect(forward.earlierBill == reversed.earlierBill)
        #expect(forward.laterBill == reversed.laterBill)
        #expect(forward.billLevel == reversed.billLevel)
        #expect(forward.servicePairs == reversed.servicePairs)
    }

    @Test
    func missingFirstStatementDateAbstains() throws {
        let comparison = assembler.assemble(
            record(date: nil),
            record(date: try sourceDate(2025, 2, 1))
        )

        #expect(comparison.chronology == .unresolved(.missingStatementDate(input: .first)))
        #expect(comparison.readiness == .notComparable)
        #expect(comparison.earlierBill == nil)
        #expect(comparison.servicePairs.isEmpty)
    }

    @Test
    func missingSecondStatementDateAbstains() throws {
        let comparison = assembler.assemble(
            record(date: try sourceDate(2025, 1, 1)),
            record(date: nil)
        )

        #expect(comparison.chronology == .unresolved(.missingStatementDate(input: .second)))
        #expect(comparison.readiness == .notComparable)
        #expect(comparison.laterBill == nil)
    }

    @Test
    func equalStatementDatesAbstain() throws {
        let date = try sourceDate(2025, 1, 1)
        let comparison = assembler.assemble(record(date: date), record(date: date))

        #expect(comparison.chronology == .unresolved(.equalStatementDates))
        #expect(comparison.reasons == [.equalStatementDates])
        #expect(comparison.billLevel == nil)
    }

    @Test
    func electricityPairsOnlyWithElectricity() throws {
        let comparison = try comparison(
            earlierServices: [service(.electricity, quantity: 100, unit: "kWh")],
            laterServices: [service(.electricity, quantity: 120, unit: "kWh")]
        )

        let pair = try #require(comparison.servicePairs.first)
        #expect(pair.serviceType == .electricity)
        #expect(decimal(pair.usageQuantity.earlier) == 100)
        #expect(decimal(pair.usageQuantity.later) == 120)
        #expect(comparison.readiness == .comparable)
    }

    @Test
    func naturalGasPairsOnlyWithNaturalGas() throws {
        let comparison = try comparison(
            earlierServices: [service(.naturalGas, quantity: 30, unit: "therms")],
            laterServices: [service(.naturalGas, quantity: 36, unit: "therms")]
        )

        #expect(comparison.servicePairs.map(\.serviceType) == [.naturalGas])
        #expect(comparison.servicePairs.first?.usageUnitCompatibility
            == .compatible(unit: "therms"))
    }

    @Test
    func combinedServicesRemainSeparate() throws {
        let comparison = try comparison(
            earlierServices: [
                service(.electricity, quantity: 100, unit: "kWh"),
                service(.naturalGas, quantity: 30, unit: "therms"),
            ],
            laterServices: [
                service(.electricity, quantity: 120, unit: "kWh"),
                service(.naturalGas, quantity: 36, unit: "therms"),
            ]
        )

        #expect(comparison.servicePairs.map(\.serviceType) == [.electricity, .naturalGas])
        #expect(comparison.servicePairs[0].later.serviceType == .electricity)
        #expect(comparison.servicePairs[1].later.serviceType == .naturalGas)
        #expect(comparison.unmatchedServices.isEmpty)
    }

    @Test
    func partialOverlapPairsCommonServiceAndPreservesUnmatchedGas() throws {
        let comparison = try comparison(
            earlierServices: [service(.electricity), service(.naturalGas)],
            laterServices: [service(.electricity)]
        )

        #expect(comparison.servicePairs.map(\.serviceType) == [.electricity])
        #expect(comparison.unmatchedServices.count == 1)
        #expect(comparison.unmatchedServices.first?.side == .earlier)
        #expect(comparison.unmatchedServices.first?.service.serviceType == .naturalGas)
        #expect(comparison.readiness == .partiallyComparable)
    }

    @Test
    func noCommonServicesDoesNotInventEquivalence() throws {
        let comparison = try comparison(
            earlierServices: [service(.electricity)],
            laterServices: [service(.naturalGas)]
        )

        #expect(comparison.servicePairs.isEmpty)
        #expect(comparison.unmatchedServices.count == 2)
        #expect(comparison.reasons.contains(.noCommonServices))
        #expect(comparison.readiness == .notComparable)
    }

    @Test
    func duplicateServiceTypeIsAmbiguousAndNeverFirstMatched() throws {
        let comparison = try comparison(
            earlierServices: [service(.electricity), service(.electricity)],
            laterServices: [service(.electricity)]
        )

        #expect(comparison.servicePairs.isEmpty)
        #expect(comparison.unmatchedServices.count == 3)
        #expect(comparison.reasons.contains(.ambiguousDuplicateServiceType(.electricity)))
        #expect(comparison.readiness == .notComparable)
    }

    @Test
    func matchingKilowattHourUnitsRetainCompatibleEvidence() throws {
        let comparison = try comparison(
            earlierServices: [service(.electricity, quantity: 90, unit: "kWh")],
            laterServices: [service(.electricity, quantity: 100, unit: "kWh")]
        )
        let pair = try #require(comparison.servicePairs.first)

        #expect(pair.usageUnitCompatibility == .compatible(unit: "kWh"))
        #expect(text(pair.usageUnit.earlier) == "kWh")
        #expect(text(pair.usageUnit.later) == "kWh")
    }

    @Test
    func matchingThermUnitsRetainCompatibleEvidence() throws {
        let comparison = try comparison(
            earlierServices: [service(.naturalGas, quantity: 20, unit: "therms")],
            laterServices: [service(.naturalGas, quantity: 25, unit: "therms")]
        )

        #expect(comparison.servicePairs.first?.usageUnitCompatibility
            == .compatible(unit: "therms"))
    }

    @Test
    func incompatibleUsageUnitsRemainSourceFactsButAreNotComparable() throws {
        let comparison = try comparison(
            earlierServices: [service(.electricity, quantity: 100, unit: "kWh")],
            laterServices: [service(.electricity, quantity: 100, unit: "therms")]
        )
        let pair = try #require(comparison.servicePairs.first)

        #expect(pair.usageUnitCompatibility
            == .incompatible(earlierUnit: "kWh", laterUnit: "therms"))
        #expect(text(pair.usageUnit.earlier) == "kWh")
        #expect(text(pair.usageUnit.later) == "therms")
        #expect(comparison.readiness == .partiallyComparable)
    }

    @Test
    func missingUsageAndChargesRemainNilInsteadOfZero() throws {
        let comparison = try comparison(
            earlierServices: [service(.electricity, quantity: 100, unit: "kWh")],
            laterServices: [service(
                .electricity,
                quantity: nil,
                unit: nil,
                charges: Decimal(string: "29.30")!
            )]
        )
        let pair = try #require(comparison.servicePairs.first)

        #expect(pair.usageQuantity.later == nil)
        #expect(pair.usageUnit.later == nil)
        #expect(pair.currentPeriodCharges.earlier == nil)
        #expect(decimal(pair.currentPeriodCharges.later) == Decimal(string: "29.30")!)
        #expect(comparison.reasons.contains(.missingServiceValue(
            side: .later,
            serviceType: .electricity,
            field: .usageQuantity
        )))
    }

    @Test
    func sourceProvenanceAndOriginsSurvivePairing() throws {
        let earlierUsage = serviceProposal(
            .usageQuantity,
            .decimal(100),
            snippet: "Earlier usage 100 kWh",
            page: 2,
            sequence: 8,
            origin: .extracted
        )
        let laterUsage = serviceProposal(
            .usageQuantity,
            .decimal(120),
            snippet: "Later usage 120 kWh",
            page: 3,
            sequence: 12,
            origin: .derived
        )
        let earlierService = service(.electricity, quantity: nil, unit: nil,
                                     usageProposal: earlierUsage)
        let laterService = service(.electricity, quantity: nil, unit: nil,
                                   usageProposal: laterUsage)
        let comparison = try comparison(
            earlierServices: [earlierService],
            laterServices: [laterService]
        )
        let pair = try #require(comparison.servicePairs.first)

        #expect(pair.usageQuantity.earlier?.provenance == earlierUsage.provenance)
        #expect(pair.usageQuantity.later?.provenance == laterUsage.provenance)
        #expect(pair.usageQuantity.earlier?.origin == .extracted)
        #expect(pair.usageQuantity.later?.origin == .derived)
    }

    @Test
    func comparisonAssemblyDoesNotMutateSourceRecords() throws {
        let earlier = record(
            date: try sourceDate(2025, 1, 1),
            services: [service(.electricity, quantity: 100, unit: "kWh")]
        )
        let later = record(
            date: try sourceDate(2025, 2, 1),
            services: [service(.electricity, quantity: 120, unit: "kWh")]
        )
        let earlierSnapshot = earlier
        let laterSnapshot = later

        _ = assembler.assemble(earlier, later)

        #expect(earlier == earlierSnapshot)
        #expect(later == laterSnapshot)
    }

    @Test
    func comparisonDoesNotMutatePersistenceVerificationOrSourceDocument() throws {
        let schema = Schema([
            Household.self, UtilityService.self, UtilityBill.self,
            UtilityBillServiceDetail.self, DistributedEnergyDetail.self, SourceDocument.self,
        ])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let document = SourceDocument(
            relativePath: "synthetic.pdf",
            originalFilename: "synthetic.pdf",
            documentType: .pdf
        )
        let bill = UtilityBill(
            amountDue: 77,
            verificationState: .needsReview,
            sourceDocument: document
        )
        container.mainContext.insert(bill)
        try container.mainContext.save()

        _ = try comparison(earlierServices: [], laterServices: [])

        let context = ModelContext(container)
        let stored = try #require(context.fetch(FetchDescriptor<UtilityBill>()).first)
        #expect(stored.amountDue == 77)
        #expect(stored.verificationState == .needsReview)
        #expect(stored.sourceDocument?.relativePath == "synthetic.pdf")
        #expect(stored.sourceDocument?.originalFilename == "synthetic.pdf")
    }

    private func comparison(
        earlierServices: [NormalizedBillServiceRecord],
        laterServices: [NormalizedBillServiceRecord]
    ) throws -> NormalizedBillComparison {
        assembler.assemble(
            record(date: try sourceDate(2025, 1, 1), services: earlierServices),
            record(date: try sourceDate(2025, 2, 1), services: laterServices)
        )
    }

    private func record(
        date: Date?,
        issuer: String? = nil,
        amountDue: Decimal? = nil,
        services: [NormalizedBillServiceRecord] = []
    ) -> NormalizedBillRecord {
        NormalizedBillRecord(
            billIssuer: issuer.map { statement(.billIssuer, .text($0), snippet: $0) },
            statementDate: date.map {
                statement(.statementDate, .date($0), snippet: "Statement date")
            },
            totalAmountDue: amountDue.map {
                statement(.amountDue, .decimal($0), snippet: "Amount due")
            },
            services: services,
            state: .proposedUnverified,
            warnings: []
        )
    }

    private func service(
        _ type: UtilityServiceType,
        quantity: Decimal? = nil,
        unit: String? = nil,
        charges: Decimal? = nil,
        usageProposal: BillServiceFieldProposal? = nil
    ) -> NormalizedBillServiceRecord {
        NormalizedBillServiceRecord(
            serviceType: type,
            billingPeriodStart: nil,
            billingPeriodEnd: nil,
            billingDays: nil,
            currentPeriodCharges: charges.map {
                serviceProposal(.currentPeriodCharges, .decimal($0))
            },
            usageQuantity: usageProposal ?? quantity.map {
                serviceProposal(.usageQuantity, .decimal($0))
            },
            usageUnit: unit.map { serviceProposal(.usageUnit, .text($0)) },
            distributedEnergy: nil
        )
    }

    private func statement(
        _ field: BillStatementFieldName,
        _ value: BillProposedValue,
        snippet: String
    ) -> BillStatementFieldProposal {
        .init(
            field: field,
            value: value,
            provenance: provenance(snippet),
            origin: .extracted
        )
    }

    private func serviceProposal(
        _ field: BillServiceFieldName,
        _ value: BillProposedValue,
        snippet: String? = nil,
        page: Int = 0,
        sequence: Int = 0,
        origin: BillProposalOrigin = .extracted
    ) -> BillServiceFieldProposal {
        .init(
            field: field,
            value: value,
            provenance: provenance(
                snippet ?? field.rawValue,
                page: page,
                sequence: sequence
            ),
            origin: origin
        )
    }

    private func provenance(
        _ snippet: String,
        page: Int = 0,
        sequence: Int = 0
    ) -> BillSourceProvenance {
        .init(
            pageIndex: page,
            snippet: snippet,
            normalizedBoundingBox: CGRect(x: 0.1, y: 0.8, width: 0.5, height: 0.04),
            sequenceIndex: sequence
        )
    }

    private func sourceDate(_ year: Int, _ month: Int, _ day: Int) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return try #require(calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day
        )))
    }

    private func decimal(_ proposal: BillServiceFieldProposal?) -> Decimal? {
        guard case .decimal(let value) = proposal?.value else { return nil }
        return value
    }

    private func text(_ proposal: BillServiceFieldProposal?) -> String? {
        guard case .text(let value) = proposal?.value else { return nil }
        return value
    }
}
