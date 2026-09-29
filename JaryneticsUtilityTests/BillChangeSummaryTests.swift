import CoreGraphics
import Foundation
import SwiftData
import Testing
@testable import JaryneticsUtility

@MainActor
struct BillChangeSummaryTests {
    private let locale = Locale(identifier: "en_US")

    @Test func usageIncreaseIsProjected() throws {
        let metric = try #require(try serviceSummary(
            earlier: service(.electricity, usage: 100, unit: "kWh"),
            later: service(.electricity, usage: 125, unit: "kWh")
        ).usage)
        #expect(metric.calculation.delta == 25)
        #expect(metric.calculation.direction == .increased)
    }

    @Test func usageDecreaseIsProjected() throws {
        let metric = try #require(try serviceSummary(
            earlier: service(.electricity, usage: 200, unit: "kWh"),
            later: service(.electricity, usage: 150, unit: "kWh")
        ).usage)
        #expect(metric.calculation.delta == -50)
        #expect(metric.calculation.direction == .decreased)
    }

    @Test func usageUnchangedIsProjected() throws {
        let metric = try #require(try serviceSummary(
            earlier: service(.naturalGas, usage: 80, unit: "therms"),
            later: service(.naturalGas, usage: 80, unit: "therms")
        ).usage)
        #expect(metric.calculation.delta == 0)
        #expect(metric.calculation.direction == .unchanged)
    }

    @Test func chargeIncreaseIsProjected() throws {
        let metric = try #require(try serviceSummary(
            earlier: service(.electricity, charge: 50),
            later: service(.electricity, charge: Decimal(string: "62.50")!)
        ).currentPeriodCharges)
        #expect(metric.calculation.delta == Decimal(string: "12.50")!)
        #expect(metric.calculation.direction == .increased)
    }

    @Test func chargeDecreaseIsProjected() throws {
        let metric = try #require(try serviceSummary(
            earlier: service(.electricity, charge: 100),
            later: service(.electricity, charge: 75)
        ).currentPeriodCharges)
        #expect(metric.calculation.delta == -25)
        #expect(metric.calculation.direction == .decreased)
    }

    @Test func chargeUnchangedIsProjected() throws {
        let metric = try #require(try serviceSummary(
            earlier: service(.naturalGas, charge: 40),
            later: service(.naturalGas, charge: 40)
        ).currentPeriodCharges)
        #expect(metric.calculation.delta == 0)
        #expect(metric.calculation.direction == .unchanged)
    }

    @Test func positiveUsageChangeHasExplicitSign() {
        #expect(BillChangeSummaryFormatting.signedChange(
            18, unit: .usage("kWh"), locale: locale
        ) == "+18 kWh")
    }

    @Test func negativeUsageChangeHasExplicitSign() {
        #expect(BillChangeSummaryFormatting.signedChange(
            -23, unit: .usage("kWh"), locale: locale
        ) == "-23 kWh")
    }

    @Test func zeroChangeHasNoMisleadingSign() {
        #expect(BillChangeSummaryFormatting.signedChange(
            0, unit: .usage("therms"), locale: locale
        ) == "0 therms")
        #expect(BillChangeSummaryFormatting.signedChange(
            0, unit: .usd, locale: locale
        ) == "$0.00")
    }

    @Test func calculatedPercentageIsFormatted() {
        #expect(BillChangeSummaryFormatting.percentage(
            .calculated(Decimal(string: "19.34")!), locale: locale
        ) == "+19.3%")
    }

    @Test func zeroBaselinePercentageIsUnavailable() {
        #expect(BillChangeSummaryFormatting.percentage(
            .unavailableZeroBaseline, locale: locale
        ) == nil)
    }

    @Test func electricityOnlyComparisonRemainsElectricity() throws {
        let summary = try summary(
            earlierServices: [service(.electricity, usage: 10, unit: "kWh")],
            laterServices: [service(.electricity, usage: 20, unit: "kWh")]
        )
        #expect(summary.services.map(\.serviceType) == [.electricity])
    }

    @Test func naturalGasOnlyComparisonRemainsNaturalGas() throws {
        let summary = try summary(
            earlierServices: [service(.naturalGas, usage: 30, unit: "therms")],
            laterServices: [service(.naturalGas, usage: 20, unit: "therms")]
        )
        #expect(summary.services.map(\.serviceType) == [.naturalGas])
    }

    @Test func combinedServicesRemainIndependent() throws {
        let summary = try summary(
            earlierServices: [
                service(.electricity, usage: 100, unit: "kWh", charge: 30),
                service(.naturalGas, usage: 40, unit: "therms", charge: 50),
            ],
            laterServices: [
                service(.electricity, usage: 120, unit: "kWh", charge: 35),
                service(.naturalGas, usage: 30, unit: "therms", charge: 45),
            ]
        )
        let electricity = try #require(summary.services.first { $0.serviceType == .electricity })
        let gas = try #require(summary.services.first { $0.serviceType == .naturalGas })
        #expect(electricity.usage?.calculation.delta == 20)
        #expect(gas.usage?.calculation.delta == -10)
        #expect(electricity.currentPeriodCharges?.calculation.delta == 5)
        #expect(gas.currentPeriodCharges?.calculation.delta == -5)
    }

    @Test func incompatibleServicesProduceNoSyntheticSummaryService() throws {
        let summary = try summary(
            earlierServices: [service(.electricity, usage: 100, unit: "kWh")],
            laterServices: [service(.naturalGas, usage: 20, unit: "therms")]
        )
        #expect(summary.services.isEmpty)
        #expect(!summary.hasCalculatedMetric)
    }

    @Test func incompatibleUnitsAbstainFromUsagePresentation() throws {
        let service = try serviceSummary(
            earlier: service(.electricity, usage: 100, unit: "kWh"),
            later: service(.electricity, usage: 20, unit: "therms")
        )
        #expect(service.usage == nil)
        #expect(!service.hasCalculatedMetric)
    }

    @Test func missingUsageCreatesNoUsageMetric() throws {
        let service = try serviceSummary(
            earlier: service(.electricity, charge: 20),
            later: service(.electricity, charge: 25)
        )
        #expect(service.usage == nil)
        #expect(service.currentPeriodCharges != nil)
    }

    @Test func missingChargesCreateNoChargeMetric() throws {
        let service = try serviceSummary(
            earlier: service(.electricity, usage: 10, unit: "kWh"),
            later: service(.electricity, usage: 20, unit: "kWh")
        )
        #expect(service.currentPeriodCharges == nil)
        #expect(service.usage != nil)
    }

    @Test func partialComparabilityShowsOnlySupportedMetric() throws {
        let summary = try summary(
            earlierServices: [service(.electricity, usage: 10, unit: "kWh")],
            laterServices: [service(.electricity, usage: 15, unit: "kWh", charge: 25)]
        )
        let service = try #require(summary.services.first)
        #expect(service.usage?.calculation.delta == 5)
        #expect(service.currentPeriodCharges == nil)
        #expect(summary.hasCalculatedMetric)
    }

    @Test func unresolvedChronologyProducesUnavailableSummary() throws {
        let date = try sourceDate(2025, 1, 1)
        let first = record(date: date, services: [service(.electricity, usage: 10, unit: "kWh")])
        let second = record(date: date, services: [service(.electricity, usage: 20, unit: "kWh")])
        let summary = assembledSummary(first, second)
        #expect(summary.services.isEmpty)
        #expect(summary.sourceChange.readiness == .unavailable)
        #expect(!summary.hasCalculatedMetric)
    }

    @Test func chronologyUsesStatementDates() throws {
        let earlier = record(
            date: try sourceDate(2025, 1, 1),
            services: [service(.electricity, usage: 10, unit: "kWh")]
        )
        let later = record(
            date: try sourceDate(2025, 2, 1),
            services: [service(.electricity, usage: 20, unit: "kWh")]
        )
        let metric = try #require(assembledSummary(earlier, later).services.first?.usage)
        #expect(metric.calculation.earlierValue == 10)
        #expect(metric.calculation.laterValue == 20)
    }

    @Test func reversedInputsKeepCustomerChronology() throws {
        let earlier = record(
            date: try sourceDate(2025, 1, 1),
            services: [service(.electricity, usage: 10, unit: "kWh")]
        )
        let later = record(
            date: try sourceDate(2025, 2, 1),
            services: [service(.electricity, usage: 20, unit: "kWh")]
        )
        let forward = assembledSummary(earlier, later)
        let reversed = assembledSummary(later, earlier)
        #expect(reversed.services == forward.services)
        #expect(reversed.sourceChange.sourceComparison.earlierBill == earlier)
        #expect(reversed.sourceChange.sourceComparison.laterBill == later)
    }

    @Test func billingPeriodsAreComposedFromNormalizedDates() throws {
        let earlierStart = try sourceDate(2024, 12, 1)
        let earlierEnd = try sourceDate(2024, 12, 31)
        let laterStart = try sourceDate(2025, 1, 1)
        let laterEnd = try sourceDate(2025, 1, 31)
        let service = try serviceSummary(
            earlier: self.service(
                .electricity, start: earlierStart, end: earlierEnd,
                usage: 10, unit: "kWh"
            ),
            later: self.service(
                .electricity, start: laterStart, end: laterEnd,
                usage: 20, unit: "kWh"
            )
        )
        #expect(BillChangeSummaryFormatting.period(
            try #require(service.earlierPeriod), locale: locale
        ) == "Dec 1, 2024 – Dec 31, 2024")
        #expect(BillChangeSummaryFormatting.period(
            try #require(service.laterPeriod), locale: locale
        ) == "Jan 1, 2025 – Jan 31, 2025")
    }

    @Test func billingDaysArePreservedWithoutNormalization() throws {
        let service = try serviceSummary(
            earlier: self.service(.electricity, days: 31, usage: 10, unit: "kWh"),
            later: self.service(.electricity, days: 30, usage: 20, unit: "kWh")
        )
        #expect(BillChangeSummaryFormatting.billingDays(
            try #require(service.earlierBillingDays)
        ) == "31 days")
        #expect(BillChangeSummaryFormatting.billingDays(
            try #require(service.laterBillingDays)
        ) == "30 days")
    }

    @Test func currencyFormattingUsesUSDPresentation() {
        #expect(BillChangeSummaryFormatting.sourceValue(
            Decimal(string: "29.30")!, unit: .usd, locale: locale
        ) == "$29.30")
        #expect(BillChangeSummaryFormatting.signedChange(
            Decimal(string: "5.45")!, unit: .usd, locale: locale
        ) == "+$5.45")
    }

    @Test func kWhFormattingPreservesSourcePrecision() {
        #expect(BillChangeSummaryFormatting.sourceValue(
            Decimal(string: "152.041")!, unit: .usage("kWh"), locale: locale
        ) == "152.041 kWh")
    }

    @Test func thermFormattingPreservesUnit() {
        #expect(BillChangeSummaryFormatting.sourceValue(
            36, unit: .usage("therms"), locale: locale
        ) == "36 therms")
    }

    @Test func provenanceAndDerivedOriginRemainDistinct() throws {
        let earlierUsage = proposal(
            .usageQuantity, .decimal(10), snippet: "Earlier 10 kWh", page: 1, sequence: 4
        )
        let laterUsage = proposal(
            .usageQuantity, .decimal(20), snippet: "Later 20 kWh", page: 2, sequence: 9
        )
        let service = try serviceSummary(
            earlier: self.service(.electricity, unit: "kWh", usageProposal: earlierUsage),
            later: self.service(.electricity, unit: "kWh", usageProposal: laterUsage)
        )
        let metric = try #require(service.usage)
        #expect(metric.sourceValues.earlier?.provenance == earlierUsage.provenance)
        #expect(metric.sourceValues.later?.provenance == laterUsage.provenance)
        #expect(metric.sourceValues.earlier?.origin == .extracted)
        #expect(metric.calculation.origin == .derived)
    }

    @Test func summaryAssemblyDoesNotMutateNormalizedRecords() throws {
        let earlier = record(
            date: try sourceDate(2025, 1, 1),
            services: [service(.electricity, usage: 10, unit: "kWh")]
        )
        let later = record(
            date: try sourceDate(2025, 2, 1),
            services: [service(.electricity, usage: 20, unit: "kWh")]
        )
        let earlierSnapshot = earlier
        let laterSnapshot = later
        _ = assembledSummary(earlier, later)
        #expect(earlier == earlierSnapshot)
        #expect(later == laterSnapshot)
    }

    @Test func missingEvidenceNeverCreatesSyntheticValues() throws {
        let service = try serviceSummary(
            earlier: self.service(.electricity),
            later: self.service(.electricity)
        )
        #expect(service.usage == nil)
        #expect(service.currentPeriodCharges == nil)
        #expect(service.earlierPeriod == nil)
        #expect(service.laterPeriod == nil)
        #expect(service.earlierBillingDays == nil)
        #expect(service.laterBillingDays == nil)
    }

    @Test func summaryAssemblyDoesNotMutateSavedBill() throws {
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
        _ = try summary(
            earlierServices: [service(.electricity, usage: 10, unit: "kWh")],
            laterServices: [service(.electricity, usage: 20, unit: "kWh")]
        )
        let context = ModelContext(container)
        let stored = try #require(context.fetch(FetchDescriptor<UtilityBill>()).first)
        #expect(stored.amountDue == 77)
        #expect(stored.verificationState == .needsReview)
    }

    private func serviceSummary(
        earlier: NormalizedBillServiceRecord,
        later: NormalizedBillServiceRecord
    ) throws -> BillChangeServiceSummary {
        try #require(try summary(
            earlierServices: [earlier], laterServices: [later]
        ).services.first)
    }

    private func summary(
        earlierServices: [NormalizedBillServiceRecord],
        laterServices: [NormalizedBillServiceRecord]
    ) throws -> BillChangeSummary {
        assembledSummary(
            record(date: try sourceDate(2025, 1, 1), services: earlierServices),
            record(date: try sourceDate(2025, 2, 1), services: laterServices)
        )
    }

    private func assembledSummary(
        _ first: NormalizedBillRecord,
        _ second: NormalizedBillRecord
    ) -> BillChangeSummary {
        let comparison = NormalizedBillComparisonAssembler().assemble(first, second)
        let change = NormalizedBillChangeAssembler().assemble(from: comparison)
        return BillChangeSummaryAssembler().assemble(from: change)
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
        start: Date? = nil,
        end: Date? = nil,
        days: Int? = nil,
        usage: Decimal? = nil,
        unit: String? = nil,
        charge: Decimal? = nil,
        usageProposal: BillServiceFieldProposal? = nil
    ) -> NormalizedBillServiceRecord {
        NormalizedBillServiceRecord(
            serviceType: type,
            billingPeriodStart: start.map { proposal(.billingPeriodStart, .date($0)) },
            billingPeriodEnd: end.map { proposal(.billingPeriodEnd, .date($0)) },
            billingDays: days.map { proposal(.billingDays, .integer($0)) },
            currentPeriodCharges: charge.map { proposal(.currentPeriodCharges, .decimal($0)) },
            usageQuantity: usageProposal ?? usage.map { proposal(.usageQuantity, .decimal($0)) },
            usageUnit: unit.map { proposal(.usageUnit, .text($0)) },
            distributedEnergy: nil
        )
    }

    private func proposal(
        _ field: BillServiceFieldName,
        _ value: BillProposedValue,
        snippet: String? = nil,
        page: Int = 0,
        sequence: Int = 0
    ) -> BillServiceFieldProposal {
        BillServiceFieldProposal(
            field: field,
            value: value,
            provenance: provenance(snippet ?? field.rawValue, page: page, sequence: sequence),
            origin: .extracted
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
            year: year, month: month, day: day
        )))
    }
}
