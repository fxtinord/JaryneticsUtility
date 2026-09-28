import CoreGraphics
import Foundation
import SwiftData
import Testing
@testable import JaryneticsUtility

@MainActor
struct NormalizedBillChangeTests {
    private let comparisonAssembler = NormalizedBillComparisonAssembler()
    private let changeAssembler = NormalizedBillChangeAssembler()

    @Test
    func usageIncreaseCalculatesDeltaDirectionAndPercentage() throws {
        let change = try serviceChange(
            earlier: service(.electricity, usage: 100, unit: "kWh"),
            later: service(.electricity, usage: 125, unit: "kWh")
        )
        let calculation = try #require(change.usage.calculation)

        #expect(calculation.delta == 25)
        #expect(calculation.direction == .increased)
        #expect(calculation.percentageChange == .calculated(25))
        #expect(change.usage.unit == .usage("kWh"))
    }

    @Test
    func usageDecreaseCalculatesNegativeDeltaAndPercentage() throws {
        let calculation = try #require(try serviceChange(
            earlier: service(.electricity, usage: 200, unit: "kWh"),
            later: service(.electricity, usage: 150, unit: "kWh")
        ).usage.calculation)

        #expect(calculation.delta == -50)
        #expect(calculation.direction == .decreased)
        #expect(calculation.percentageChange == .calculated(-25))
    }

    @Test
    func unchangedGasUsageHasZeroDelta() throws {
        let calculation = try #require(try serviceChange(
            earlier: service(.naturalGas, usage: 80, unit: "therms"),
            later: service(.naturalGas, usage: 80, unit: "therms")
        ).usage.calculation)

        #expect(calculation.delta == 0)
        #expect(calculation.direction == .unchanged)
        #expect(calculation.percentageChange == .calculated(0))
    }

    @Test
    func chargeIncreaseUsesServiceCurrentPeriodCharges() throws {
        let calculation = try #require(try serviceChange(
            earlier: service(.electricity, charge: Decimal(string: "50.00")!),
            later: service(.electricity, charge: Decimal(string: "62.50")!)
        ).currentPeriodCharges.calculation)

        #expect(calculation.delta == Decimal(string: "12.50")!)
        #expect(calculation.direction == .increased)
        #expect(calculation.percentageChange == .calculated(25))
    }

    @Test
    func chargeDecreaseCalculatesNegativeDelta() throws {
        let calculation = try #require(try serviceChange(
            earlier: service(.electricity, charge: 100),
            later: service(.electricity, charge: 75)
        ).currentPeriodCharges.calculation)

        #expect(calculation.delta == -25)
        #expect(calculation.direction == .decreased)
        #expect(calculation.percentageChange == .calculated(-25))
    }

    @Test
    func zeroEarlierValueKeepsAbsoluteChangeButAbstainsFromPercentage() throws {
        let calculation = try #require(try serviceChange(
            earlier: service(.electricity, usage: 0, unit: "kWh"),
            later: service(.electricity, usage: 25, unit: "kWh")
        ).usage.calculation)

        #expect(calculation.delta == 25)
        #expect(calculation.direction == .increased)
        #expect(calculation.percentageChange == .unavailableZeroBaseline)
    }

    @Test
    func bothZeroValuesAreUnchangedButPercentageRemainsUnavailable() throws {
        let calculation = try #require(try serviceChange(
            earlier: service(.naturalGas, usage: 0, unit: "therms"),
            later: service(.naturalGas, usage: 0, unit: "therms")
        ).usage.calculation)

        #expect(calculation.delta == 0)
        #expect(calculation.direction == .unchanged)
        #expect(calculation.percentageChange == .unavailableZeroBaseline)
    }

    @Test
    func missingEarlierValueDoesNotFabricateZero() throws {
        let usage = try serviceChange(
            earlier: service(.electricity, usage: nil, unit: nil),
            later: service(.electricity, usage: 25, unit: "kWh")
        ).usage

        #expect(usage.sourceValues.earlier == nil)
        #expect(usage.calculation == nil)
        #expect(usage.abstentionReason == .missingEarlierValue)
    }

    @Test
    func missingLaterValueDoesNotFabricateZero() throws {
        let charges = try serviceChange(
            earlier: service(.electricity, charge: 50),
            later: service(.electricity, charge: nil)
        ).currentPeriodCharges

        #expect(charges.sourceValues.later == nil)
        #expect(charges.calculation == nil)
        #expect(charges.abstentionReason == .missingLaterValue)
    }

    @Test
    func incompatibleUsageUnitsPreventCalculation() throws {
        let usage = try serviceChange(
            earlier: service(.electricity, usage: 100, unit: "kWh"),
            later: service(.electricity, usage: 20, unit: "therms")
        ).usage

        #expect(usage.calculation == nil)
        #expect(usage.abstentionReason == .incompatibleUsageUnit)
        #expect(usage.sourceValues.earlier != nil)
        #expect(usage.sourceValues.later != nil)
    }

    @Test
    func combinedServicesCalculateIndependently() throws {
        let change = try assembledChange(
            earlierServices: [
                service(.electricity, usage: 100, unit: "kWh", charge: 40),
                service(.naturalGas, usage: 50, unit: "therms", charge: 60),
            ],
            laterServices: [
                service(.electricity, usage: 125, unit: "kWh", charge: 45),
                service(.naturalGas, usage: 40, unit: "therms", charge: 55),
            ]
        )

        let electricity = try #require(change.serviceChanges.first {
            $0.serviceType == .electricity
        })
        let gas = try #require(change.serviceChanges.first { $0.serviceType == .naturalGas })
        #expect(electricity.usage.calculation?.delta == 25)
        #expect(gas.usage.calculation?.delta == -10)
        #expect(electricity.currentPeriodCharges.calculation?.delta == 5)
        #expect(gas.currentPeriodCharges.calculation?.delta == -5)
    }

    @Test
    func reversedInputStillCalculatesLaterMinusEarlier() throws {
        let earlier = record(
            date: try sourceDate(2025, 1, 1),
            services: [service(.electricity, usage: 100, unit: "kWh")]
        )
        let later = record(
            date: try sourceDate(2025, 2, 1),
            services: [service(.electricity, usage: 125, unit: "kWh")]
        )
        let comparison = comparisonAssembler.assemble(later, earlier)
        let change = changeAssembler.assemble(from: comparison)

        #expect(change.serviceChanges.first?.usage.calculation?.delta == 25)
        #expect(change.serviceChanges.first?.usage.calculation?.earlierValue == 100)
        #expect(change.serviceChanges.first?.usage.calculation?.laterValue == 125)
    }

    @Test
    func unresolvedChronologyPreventsAllCalculations() throws {
        let date = try sourceDate(2025, 1, 1)
        let comparison = comparisonAssembler.assemble(
            record(date: date, services: [service(.electricity, usage: 100, unit: "kWh")]),
            record(date: date, services: [service(.electricity, usage: 125, unit: "kWh")])
        )
        let change = changeAssembler.assemble(from: comparison)

        #expect(change.serviceChanges.isEmpty)
        #expect(change.readiness == .unavailable)
        #expect(change.abstentionReason == .comparisonNotOrdered)
    }

    @Test
    func comparableUsageCanSucceedWhenChargesAreUnavailable() throws {
        let change = try assembledChange(
            earlierServices: [service(.electricity, usage: 100, unit: "kWh")],
            laterServices: [service(.electricity, usage: 110, unit: "kWh")]
        )
        let service = try #require(change.serviceChanges.first)

        #expect(service.usage.calculation?.delta == 10)
        #expect(service.currentPeriodCharges.calculation == nil)
        #expect(service.currentPeriodCharges.abstentionReason == .missingEarlierValue)
        #expect(change.readiness == .partiallyCalculated)
    }

    @Test
    func decimalMonetaryArithmeticPreservesExactPrecision() throws {
        let calculation = try #require(try serviceChange(
            earlier: service(.electricity, charge: Decimal(string: "10.10")!),
            later: service(.electricity, charge: Decimal(string: "10.20")!)
        ).currentPeriodCharges.calculation)

        #expect(calculation.delta == Decimal(string: "0.10")!)
        #expect(calculation.earlierValue == Decimal(string: "10.10")!)
        #expect(calculation.laterValue == Decimal(string: "10.20")!)
    }

    @Test
    func negativeValuesUseAbsoluteEarlierMagnitudeForPercentage() throws {
        let calculation = try #require(try serviceChange(
            earlier: service(.electricity, charge: -50),
            later: service(.electricity, charge: -25)
        ).currentPeriodCharges.calculation)

        #expect(calculation.delta == 25)
        #expect(calculation.direction == .increased)
        #expect(calculation.percentageChange == .calculated(50))
    }

    @Test
    func sourceProvenanceIsRetainedAndCalculationIsDerived() throws {
        let earlier = proposal(
            .usageQuantity,
            .decimal(100),
            snippet: "Earlier usage 100 kWh",
            page: 1,
            sequence: 4,
            origin: .extracted
        )
        let later = proposal(
            .usageQuantity,
            .decimal(125),
            snippet: "Later usage 125 kWh",
            page: 2,
            sequence: 9,
            origin: .derived
        )
        let change = try serviceChange(
            earlier: service(.electricity, usage: nil, unit: "kWh", usageProposal: earlier),
            later: service(.electricity, usage: nil, unit: "kWh", usageProposal: later)
        )

        #expect(change.usage.sourceValues.earlier?.provenance == earlier.provenance)
        #expect(change.usage.sourceValues.later?.provenance == later.provenance)
        #expect(change.usage.sourceValues.earlier?.origin == .extracted)
        #expect(change.usage.sourceValues.later?.origin == .derived)
        #expect(change.usage.calculation?.origin == .derived)
    }

    @Test
    func calculationDoesNotMutateNormalizedInputsAndIsDeterministic() throws {
        let earlier = record(
            date: try sourceDate(2025, 1, 1),
            services: [service(.electricity, usage: 100, unit: "kWh", charge: 20)]
        )
        let later = record(
            date: try sourceDate(2025, 2, 1),
            services: [service(.electricity, usage: 125, unit: "kWh", charge: 25)]
        )
        let earlierSnapshot = earlier
        let laterSnapshot = later
        let comparison = comparisonAssembler.assemble(earlier, later)

        let first = changeAssembler.assemble(from: comparison)
        let second = changeAssembler.assemble(from: comparison)

        #expect(first == second)
        #expect(earlier == earlierSnapshot)
        #expect(later == laterSnapshot)
    }

    @Test
    func calculationDoesNotMutateSavedBillOrVerificationState() throws {
        let schema = Schema([
            Household.self, UtilityService.self, UtilityBill.self,
            UtilityBillServiceDetail.self, DistributedEnergyDetail.self, SourceDocument.self,
        ])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let bill = UtilityBill(amountDue: 77, verificationState: .needsReview)
        container.mainContext.insert(bill)
        try container.mainContext.save()

        _ = try assembledChange(
            earlierServices: [service(.electricity, usage: 100, unit: "kWh")],
            laterServices: [service(.electricity, usage: 125, unit: "kWh")]
        )

        let context = ModelContext(container)
        let stored = try #require(context.fetch(FetchDescriptor<UtilityBill>()).first)
        #expect(stored.amountDue == 77)
        #expect(stored.verificationState == .needsReview)
    }

    private func serviceChange(
        earlier: NormalizedBillServiceRecord,
        later: NormalizedBillServiceRecord
    ) throws -> NormalizedBillServiceChange {
        try #require(try assembledChange(
            earlierServices: [earlier],
            laterServices: [later]
        ).serviceChanges.first)
    }

    private func assembledChange(
        earlierServices: [NormalizedBillServiceRecord],
        laterServices: [NormalizedBillServiceRecord]
    ) throws -> NormalizedBillChange {
        let comparison = comparisonAssembler.assemble(
            record(date: try sourceDate(2025, 1, 1), services: earlierServices),
            record(date: try sourceDate(2025, 2, 1), services: laterServices)
        )
        return changeAssembler.assemble(from: comparison)
    }

    private func record(
        date: Date,
        services: [NormalizedBillServiceRecord]
    ) -> NormalizedBillRecord {
        NormalizedBillRecord(
            billIssuer: nil,
            statementDate: BillStatementFieldProposal(
                field: .statementDate,
                value: .date(date),
                provenance: provenance("Statement date"),
                origin: .extracted
            ),
            totalAmountDue: nil,
            services: services,
            state: .proposedUnverified,
            warnings: []
        )
    }

    private func service(
        _ type: UtilityServiceType,
        usage: Decimal? = nil,
        unit: String? = nil,
        charge: Decimal? = nil,
        usageProposal: BillServiceFieldProposal? = nil
    ) -> NormalizedBillServiceRecord {
        NormalizedBillServiceRecord(
            serviceType: type,
            billingPeriodStart: nil,
            billingPeriodEnd: nil,
            billingDays: nil,
            currentPeriodCharges: charge.map {
                proposal(.currentPeriodCharges, .decimal($0))
            },
            usageQuantity: usageProposal ?? usage.map {
                proposal(.usageQuantity, .decimal($0))
            },
            usageUnit: unit.map { proposal(.usageUnit, .text($0)) },
            distributedEnergy: nil
        )
    }

    private func proposal(
        _ field: BillServiceFieldName,
        _ value: BillProposedValue,
        snippet: String? = nil,
        page: Int = 0,
        sequence: Int = 0,
        origin: BillProposalOrigin = .extracted
    ) -> BillServiceFieldProposal {
        BillServiceFieldProposal(
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
}
