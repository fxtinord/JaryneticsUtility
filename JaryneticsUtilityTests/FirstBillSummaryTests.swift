import CoreGraphics
import Foundation
import SwiftData
import Testing
@testable import JaryneticsUtility

@MainActor
struct FirstBillSummaryTests {
    private let assembler = FirstBillSummaryAssembler()
    private let locale = Locale(identifier: "en_US")

    @Test
    func issuerOnlySummaryContainsNoInventedFields() throws {
        let summary = assembler.assemble(from: record(issuer: "North Valley Energy"))

        #expect(summary.billIssuer?.value == "North Valley Energy")
        #expect(summary.statementDate == nil)
        #expect(summary.amountDue == nil)
        #expect(summary.services.isEmpty)
    }

    @Test
    func issuerAndStatementDateRemainBillLevel() throws {
        let date = try sourceDate(year: 2022, month: 7, day: 25)
        let summary = assembler.assemble(from: record(
            issuer: "North Valley Energy",
            statementDate: date
        ))

        #expect(summary.billIssuer?.value == "North Valley Energy")
        #expect(summary.statementDate?.value == date)
        #expect(summary.services.isEmpty)
    }

    @Test
    func amountDueUsesCustomerReadableCurrencyFormatting() {
        let summary = assembler.assemble(from: record(amountDue: Decimal(string: "165.00")!))

        #expect(summary.amountDue?.value == Decimal(string: "165.00")!)
        #expect(FirstBillSummaryFormatting.currency(
            summary.amountDue!.value,
            locale: locale
        ) == "$165.00")
    }

    @Test
    func singleElectricityServiceIsPreserved() {
        let summary = assembler.assemble(from: record(services: [service(.electricity)]))

        #expect(summary.services.map(\.serviceType) == [.electricity])
    }

    @Test
    func singleNaturalGasServiceIsPreserved() {
        let summary = assembler.assemble(from: record(services: [service(.naturalGas)]))

        #expect(summary.services.map(\.serviceType) == [.naturalGas])
    }

    @Test
    func electricityUsageCombinesQuantityAndUnitForPresentation() throws {
        let summary = assembler.assemble(from: record(services: [service(
            .electricity,
            usageQuantity: Decimal(string: "152.041")!,
            usageUnit: "kWh"
        )]))
        let usage = try #require(summary.services.first?.usage)

        #expect(FirstBillSummaryFormatting.usage(
            quantity: usage.quantity.value,
            unit: usage.unit.value,
            locale: locale
        ) == "152.041 kWh")
    }

    @Test
    func gasUsageCombinesQuantityAndUnitForPresentation() throws {
        let summary = assembler.assemble(from: record(services: [service(
            .naturalGas,
            usageQuantity: 36,
            usageUnit: "therms"
        )]))
        let usage = try #require(summary.services.first?.usage)

        #expect(FirstBillSummaryFormatting.usage(
            quantity: usage.quantity.value,
            unit: usage.unit.value,
            locale: locale
        ) == "36 therms")
    }

    @Test
    func billingPeriodRequiresAndCombinesBothDates() throws {
        let start = try sourceDate(year: 2018, month: 10, day: 30)
        let end = try sourceDate(year: 2018, month: 11, day: 29)
        let summary = assembler.assemble(from: record(services: [service(
            .electricity,
            billingStart: start,
            billingEnd: end
        )]))
        let period = try #require(summary.services.first?.billingPeriod)

        #expect(FirstBillSummaryFormatting.billingPeriod(
            start: period.start.value,
            end: period.end.value,
            locale: locale
        ) == "Oct 30, 2018 – Nov 29, 2018")
    }

    @Test
    func billingDaysArePreservedWithoutDateCalculation() {
        let summary = assembler.assemble(from: record(services: [service(
            .electricity,
            billingDays: 31
        )]))

        #expect(summary.services.first?.billingDays?.value == 31)
        #expect(summary.services.first?.billingPeriod == nil)
    }

    @Test
    func currentPeriodChargesUseCurrencyFormatting() throws {
        let summary = assembler.assemble(from: record(services: [service(
            .electricity,
            charges: Decimal(string: "29.30")!
        )]))
        let charges = try #require(summary.services.first?.currentPeriodCharges)

        #expect(FirstBillSummaryFormatting.currency(charges.value, locale: locale) == "$29.30")
    }

    @Test
    func combinedBillKeepsElectricityAndGasIndependent() throws {
        let summary = assembler.assemble(from: record(services: [
            service(
                .electricity,
                usageQuantity: Decimal(string: "152.041")!,
                usageUnit: "kWh",
                charges: Decimal(string: "29.30")!
            ),
            service(
                .naturalGas,
                usageQuantity: 36,
                usageUnit: "therms",
                charges: Decimal(string: "40.22")!
            ),
        ]))

        let electricity = try #require(summary.services.first { $0.serviceType == .electricity })
        let gas = try #require(summary.services.first { $0.serviceType == .naturalGas })
        #expect(electricity.usage?.unit.value == "kWh")
        #expect(electricity.currentPeriodCharges?.value == Decimal(string: "29.30")!)
        #expect(gas.usage?.unit.value == "therms")
        #expect(gas.currentPeriodCharges?.value == Decimal(string: "40.22")!)
    }

    @Test
    func missingOptionalValuesRemainAbsent() {
        let summary = assembler.assemble(from: record(services: [service(
            .electricity,
            usageQuantity: 46
        )]))

        #expect(summary.services.first?.usage == nil)
        #expect(summary.services.first?.billingPeriod == nil)
        #expect(summary.services.first?.billingDays == nil)
        #expect(summary.services.first?.currentPeriodCharges == nil)
    }

    @Test
    func serviceValuesNeverLeakAcrossServices() throws {
        let summary = assembler.assemble(from: record(services: [
            service(.electricity, usageQuantity: 642, usageUnit: "kWh"),
            service(.naturalGas, charges: Decimal(string: "40.22")!),
        ]))

        let electricity = try #require(summary.services.first { $0.serviceType == .electricity })
        let gas = try #require(summary.services.first { $0.serviceType == .naturalGas })
        #expect(electricity.usage?.quantity.value == 642)
        #expect(electricity.currentPeriodCharges == nil)
        #expect(gas.usage == nil)
        #expect(gas.currentPeriodCharges?.value == Decimal(string: "40.22")!)
    }

    @Test
    func acceptedDirectIssuerPassesThroughUnchanged() {
        let direct = statement(.billIssuer, .text("Direct Source Utility"), snippet: "Direct Source Utility")
        let normalized = NormalizedBillRecord(
            billIssuer: direct,
            statementDate: nil,
            totalAmountDue: nil,
            services: [],
            state: .proposedUnverified,
            warnings: []
        )

        #expect(assembler.assemble(from: normalized).billIssuer?.value == "Direct Source Utility")
    }

    @Test
    func emptyNormalizedRecordCreatesNoSummaryValues() {
        let summary = assembler.assemble(from: record())

        #expect(!summary.hasContent)
        #expect(summary.billIssuer == nil)
        #expect(summary.statementDate == nil)
        #expect(summary.amountDue == nil)
        #expect(summary.services.isEmpty)
    }

    @Test
    func provenanceAndNormalizedRecordRemainUnchanged() {
        let proposal = statement(
            .amountDue,
            .decimal(47),
            snippet: "Total Amount Due: $47.00",
            page: 2,
            sequence: 8
        )
        let normalized = NormalizedBillRecord(
            billIssuer: nil,
            statementDate: nil,
            totalAmountDue: proposal,
            services: [],
            state: .proposedUnverified,
            warnings: []
        )
        let snapshot = normalized
        let summary = assembler.assemble(from: normalized)

        #expect(summary.amountDue?.provenance == proposal.provenance)
        #expect(summary.amountDue?.origin == proposal.origin)
        #expect(normalized == snapshot)
    }

    @Test
    func summaryConstructionDoesNotMutateSavedBillOrVerificationState() throws {
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

        _ = assembler.assemble(from: record(amountDue: 99))

        let context = ModelContext(container)
        let stored = try #require(context.fetch(FetchDescriptor<UtilityBill>()).first)
        #expect(stored.amountDue == 77)
        #expect(stored.verificationState == .needsReview)
    }

    private func record(
        issuer: String? = nil,
        statementDate: Date? = nil,
        amountDue: Decimal? = nil,
        services: [NormalizedBillServiceRecord] = []
    ) -> NormalizedBillRecord {
        NormalizedBillRecord(
            billIssuer: issuer.map {
                statement(.billIssuer, .text($0), snippet: $0)
            },
            statementDate: statementDate.map {
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
        billingStart: Date? = nil,
        billingEnd: Date? = nil,
        billingDays: Int? = nil,
        usageQuantity: Decimal? = nil,
        usageUnit: String? = nil,
        charges: Decimal? = nil
    ) -> NormalizedBillServiceRecord {
        NormalizedBillServiceRecord(
            serviceType: type,
            billingPeriodStart: billingStart.map {
                serviceProposal(.billingPeriodStart, .date($0))
            },
            billingPeriodEnd: billingEnd.map {
                serviceProposal(.billingPeriodEnd, .date($0))
            },
            billingDays: billingDays.map { serviceProposal(.billingDays, .integer($0)) },
            currentPeriodCharges: charges.map {
                serviceProposal(.currentPeriodCharges, .decimal($0))
            },
            usageQuantity: usageQuantity.map {
                serviceProposal(.usageQuantity, .decimal($0))
            },
            usageUnit: usageUnit.map { serviceProposal(.usageUnit, .text($0)) },
            distributedEnergy: nil
        )
    }

    private func statement(
        _ field: BillStatementFieldName,
        _ value: BillProposedValue,
        snippet: String,
        page: Int = 0,
        sequence: Int = 0
    ) -> BillStatementFieldProposal {
        .init(
            field: field,
            value: value,
            provenance: provenance(snippet, page: page, sequence: sequence),
            origin: .extracted
        )
    }

    private func serviceProposal(
        _ field: BillServiceFieldName,
        _ value: BillProposedValue
    ) -> BillServiceFieldProposal {
        .init(
            field: field,
            value: value,
            provenance: provenance(field.rawValue),
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

    private func sourceDate(year: Int, month: Int, day: Int) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return try #require(calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day
        )))
    }
}
