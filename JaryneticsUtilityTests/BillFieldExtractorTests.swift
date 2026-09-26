import CoreGraphics
import Foundation
import Testing
@testable import JaryneticsUtility

struct BillFieldExtractorTests {
    private let extractor = BillFieldExtractor()

    @Test
    func extractsStatementLevelFieldsWithoutServiceContext() throws {
        let result = extractor.extract(from: recognition(
            "Statement Date: 02/07/2026",
            "Total Amount Due: $1,234.56",
            "Due Date: February 28, 2026"
        ))

        #expect(try statementDate(result, .statementDate) == utcDate(2026, 2, 7))
        #expect(try statementDecimal(result, .amountDue) == Decimal(string: "1234.56"))
        #expect(try statementDate(result, .dueDate) == utcDate(2026, 2, 28))
        #expect(result.serviceGroups.isEmpty)
    }

    @Test
    func extractsSeparateElectricAndGasDetailsFromCombinedStatement() throws {
        let result = extractor.extract(from: recognition(
            "Statement Date: 02/01/2026",
            "Total Amount Due: $155.00",
            "Electricity",
            "Billing Period: 01/01/2026 - 01/31/2026",
            "Billing Days: 31",
            "Current Period Charges: $100.00",
            "Usage: 750 kWh",
            "Natural Gas",
            "Billing Period: 01/05/2026 - 02/01/2026",
            "Billing Days: 27",
            "Current Period Charges: $55.00",
            "Usage: 42 therms"
        ))
        let electric = try #require(result.serviceGroup(for: .electricity))
        let gas = try #require(result.serviceGroup(for: .naturalGas))

        #expect(try statementDecimal(result, .amountDue) == Decimal(155))
        #expect(try serviceDate(electric, .billingPeriodStart) == utcDate(2026, 1, 1))
        #expect(try serviceDate(electric, .billingPeriodEnd) == utcDate(2026, 1, 31))
        #expect(try serviceInteger(electric, .billingDays) == 31)
        #expect(try serviceDecimal(electric, .currentPeriodCharges) == Decimal(100))
        #expect(try serviceDecimal(electric, .usageQuantity) == Decimal(750))
        #expect(try serviceText(electric, .usageUnit) == "kWh")
        #expect(try serviceDate(gas, .billingPeriodStart) == utcDate(2026, 1, 5))
        #expect(try serviceDate(gas, .billingPeriodEnd) == utcDate(2026, 2, 1))
        #expect(try serviceInteger(gas, .billingDays) == 27)
        #expect(try serviceDecimal(gas, .currentPeriodCharges) == Decimal(55))
        #expect(try serviceDecimal(gas, .usageQuantity) == Decimal(42))
        #expect(try serviceText(gas, .usageUnit) == "therms")
    }

    @Test
    func doesNotCalculateStatementAmountFromServiceCharges() {
        let result = extractor.extract(from: recognition(
            "Electricity",
            "Current Charges: $100.00",
            "Natural Gas",
            "Current Charges: $55.00"
        ))

        #expect(result.statementProposal(for: .amountDue) == nil)
    }

    @Test
    func preservesSingleServiceExtraction() throws {
        let result = extractor.extract(from: recognition(
            "Billing Period: January 1, 2026 - January 31, 2026",
            "Current Period Charges: $74.28",
            "Electricity Usage: 842.6 kwh"
        ))
        let electric = try #require(result.serviceGroup(for: .electricity))

        #expect(result.serviceGroups.count == 1)
        #expect(try serviceDate(electric, .billingPeriodStart) == utcDate(2026, 1, 1))
        #expect(try serviceDate(electric, .billingPeriodEnd) == utcDate(2026, 1, 31))
        #expect(try serviceDecimal(electric, .currentPeriodCharges) == Decimal(string: "74.28"))
        #expect(try serviceDecimal(electric, .usageQuantity) == Decimal(string: "842.6"))
        #expect(try serviceText(electric, .usageUnit) == "kWh")
    }

    @Test
    func extractsWaterWastewaterServiceDetails() throws {
        let result = extractor.extract(from: recognition(
            "Water/Wastewater Service",
            "Service Period: 03/01/2026 - 03/31/2026",
            "Current Charges: $48.20",
            "Water Usage: 14 water units"
        ))
        let water = try #require(result.serviceGroup(for: .waterWastewater))

        #expect(try serviceDecimal(water, .currentPeriodCharges) == Decimal(string: "48.20"))
        #expect(try serviceDecimal(water, .usageQuantity) == Decimal(14))
        #expect(try serviceText(water, .usageUnit) == "water units")
    }

    @Test
    func ambiguousServiceIdentityProducesNoServiceProposal() {
        let result = extractor.extract(from: recognition(
            "Electricity and Natural Gas Usage: 650 kWh",
            "Current Charges: $80.00"
        ))

        #expect(result.serviceGroups.isEmpty)
    }

    @Test
    func unlabeledServiceValuesProduceNoServiceProposal() {
        let result = extractor.extract(from: recognition(
            "Billing Period: 01/01/2026 - 01/31/2026",
            "Current Charges: $80.00",
            "Usage: 650 kWh"
        ))

        #expect(result.serviceGroups.isEmpty)
    }

    @Test
    func priorBalancesAndPaymentsAreNotCurrentCharges() throws {
        let result = extractor.extract(from: recognition(
            "Electricity",
            "Prior Balance: $91.10",
            "Payment Received: $91.10",
            "Current Period Charges: $74.28"
        ))
        let electric = try #require(result.serviceGroup(for: .electricity))

        #expect(try serviceDecimal(electric, .currentPeriodCharges) == Decimal(string: "74.28"))
    }

    @Test
    func historicalStatementAndServiceValuesAreExcluded() throws {
        let result = extractor.extract(from: recognition(
            "Previous Amount Due: $91.10",
            "Past Due Date: 01/15/2026",
            "Previous Billing Period: 12/01/2025 - 12/31/2025",
            "Average Daily Usage: 24 kWh",
            "Previous Usage: 650 kWh"
        ))

        #expect(result.statementProposals.isEmpty)
        #expect(result.serviceGroups.isEmpty)
    }

    @Test
    func validCurrentValuesAlongsideHistoryRemainAvailable() throws {
        let result = extractor.extract(from: recognition(
            "Previous Amount Due: $91.10",
            "Amount Due: $74.28",
            "Electricity",
            "Previous Usage: 650 kWh",
            "Usage: 700 kWh"
        ))
        let electric = try #require(result.serviceGroup(for: .electricity))

        #expect(try statementDecimal(result, .amountDue) == Decimal(string: "74.28"))
        #expect(try serviceDecimal(electric, .usageQuantity) == Decimal(700))
    }

    @Test
    func conflictingStatementValuesProduceNoProposal() {
        let result = extractor.extract(from: recognition(
            "Amount Due: $40.00",
            "Amount Due: $41.00"
        ))

        #expect(result.statementProposal(for: .amountDue) == nil)
    }

    @Test
    func derivesServiceBillingDaysAndMarksOrigin() throws {
        let result = extractor.extract(from: recognition(
            "Natural Gas",
            "Billing Period: 01/01/2026 - 01/31/2026"
        ))
        let gas = try #require(result.serviceGroup(for: .naturalGas))
        let days = try #require(gas.proposal(for: .billingDays))

        #expect(days.value == .integer(30))
        #expect(days.origin == .derived)
    }

    @Test
    func explicitServiceBillingDaysRemainExtracted() throws {
        let result = extractor.extract(from: recognition(
            "Natural Gas",
            "Billing Period: 01/01/2026 - 01/31/2026",
            "Billing Days: 31"
        ))
        let gas = try #require(result.serviceGroup(for: .naturalGas))
        let days = try #require(gas.proposal(for: .billingDays))

        #expect(days.value == .integer(31))
        #expect(days.origin == .extracted)
        #expect(days.provenance.snippet == "Billing Days: 31")
    }

    @Test
    func preservesStatementServiceAndFieldProvenance() throws {
        let statementBox = CGRect(x: 0.1, y: 0.8, width: 0.5, height: 0.05)
        let serviceBox = CGRect(x: 0.1, y: 0.7, width: 0.4, height: 0.05)
        let usageBox = CGRect(x: 0.1, y: 0.6, width: 0.6, height: 0.05)
        let result = extractor.extract(from: recognition(pages: [
            page(2, lines: [line("Amount Due: $77.19", box: statementBox)]),
            page(3, lines: [
                line("Electricity", box: serviceBox),
                line("Usage: 500 kWh", box: usageBox),
            ]),
        ]))
        let amount = try #require(result.statementProposal(for: .amountDue))
        let electric = try #require(result.serviceGroup(for: .electricity))
        let usage = try #require(electric.proposal(for: .usageQuantity))

        #expect(amount.provenance.pageIndex == 2)
        #expect(amount.provenance.normalizedBoundingBox == statementBox)
        #expect(electric.serviceIdentityProvenance.pageIndex == 3)
        #expect(electric.serviceIdentityProvenance.normalizedBoundingBox == serviceBox)
        #expect(usage.provenance.snippet == "Usage: 500 kWh")
        #expect(usage.provenance.normalizedBoundingBox == usageBox)
    }

    @Test @MainActor
    func extractionDoesNotModifyTrustedStatementDetailsOrVerificationState() {
        let household = Household(name: "Synthetic Household")
        let service = UtilityService(
            serviceType: .electricity,
            providerName: "Synthetic Provider",
            household: household
        )
        let bill = UtilityBill(
            amountDue: Decimal(10),
            verificationState: .verified
        )
        let detail = UtilityBillServiceDetail(
            utilityBill: bill,
            utilityService: service,
            currentPeriodCharges: Decimal(8),
            usageQuantity: Decimal(100),
            usageUnit: "kWh"
        )

        _ = extractor.extract(from: recognition(
            "Amount Due: $99.00",
            "Electricity",
            "Current Charges: $90.00",
            "Usage: 900 kWh"
        ))

        #expect(bill.amountDue == Decimal(10))
        #expect(bill.statementDate == nil)
        #expect(bill.dueDate == nil)
        #expect(bill.verificationState == .verified)
        #expect(bill.serviceDetails.isEmpty)
        #expect(detail.currentPeriodCharges == Decimal(8))
        #expect(detail.usageQuantity == Decimal(100))
        #expect(detail.usageUnit == "kWh")
    }

    @Test
    func repeatedCombinedExtractionIsDeterministic() {
        let input = recognition(
            "Statement Date: 01/31/2026",
            "Total Amount Due: $155.00",
            "Electricity",
            "Current Charges: $100.00",
            "Usage: 650 kWh",
            "Natural Gas",
            "Current Charges: $55.00",
            "Usage: 40 therms"
        )

        #expect(extractor.extract(from: input) == extractor.extract(from: input))
    }

    @Test
    func extractsClearlyLabeledAmountDueWithCurrencyFormatting() throws {
        let result = extractor.extract(from: recognition("Amount Due: $1,234.56"))

        #expect(try statementDecimal(result, .amountDue) == Decimal(string: "1234.56"))
    }

    @Test
    func extractsCurrentChargesWithoutUsingPriorBalanceOrPayment() throws {
        let result = extractor.extract(from: recognition(
            "Electricity",
            "Prior Balance: $91.10",
            "Payment Received: $91.10",
            "Current Period Charges: $74.28"
        ))
        let electric = try #require(result.serviceGroup(for: .electricity))

        #expect(try serviceDecimal(electric, .currentPeriodCharges) == Decimal(string: "74.28"))
    }

    @Test
    func extractsStatementDateFromSupportedUSFormats() throws {
        let numeric = extractor.extract(from: recognition("Statement Date: 02/07/2026"))
        let abbreviated = extractor.extract(from: recognition("Statement Date: Feb 7, 2026"))

        #expect(try statementDate(numeric, .statementDate) == utcDate(2026, 2, 7))
        #expect(try statementDate(abbreviated, .statementDate) == utcDate(2026, 2, 7))
    }

    @Test
    func extractsBillingPeriodStartAndEnd() throws {
        let result = extractor.extract(from: recognition(
            "Electricity",
            "Billing Period: January 1, 2026 - January 31, 2026"
        ))
        let electric = try #require(result.serviceGroup(for: .electricity))

        #expect(try serviceDate(electric, .billingPeriodStart) == utcDate(2026, 1, 1))
        #expect(try serviceDate(electric, .billingPeriodEnd) == utcDate(2026, 1, 31))
    }

    @Test
    func extractsDueDateWithoutTreatingOtherDatesAsDueDate() throws {
        let result = extractor.extract(from: recognition(
            "Statement Date: 1/31/26",
            "Due Date: 02/20/2026"
        ))

        #expect(try statementDate(result, .dueDate) == utcDate(2026, 2, 20))
    }

    @Test
    func extractsElectricityUsageAndNormalizesKWhCapitalization() throws {
        let result = extractor.extract(from: recognition("Electricity Usage: 842.6 kwh"))
        let electric = try #require(result.serviceGroup(for: .electricity))

        #expect(try serviceDecimal(electric, .usageQuantity) == Decimal(string: "842.6"))
        #expect(try serviceText(electric, .usageUnit) == "kWh")
    }

    @Test
    func extractsNaturalGasUsageAndUnit() throws {
        let result = extractor.extract(from: recognition("Natural Gas Usage: 82 therms"))
        let gas = try #require(result.serviceGroup(for: .naturalGas))

        #expect(try serviceDecimal(gas, .usageQuantity) == Decimal(82))
        #expect(try serviceText(gas, .usageUnit) == "therms")
    }

    @Test
    func extractsWaterUsageAndProviderReportedUnit() throws {
        let result = extractor.extract(from: recognition("Water Usage: 14 water units"))
        let water = try #require(result.serviceGroup(for: .waterWastewater))

        #expect(try serviceDecimal(water, .usageQuantity) == Decimal(14))
        #expect(try serviceText(water, .usageUnit) == "water units")
    }

    @Test
    func omitsAbsentAndConflictingCandidates() {
        let unrelated = extractor.extract(from: recognition(
            "Previous Amount: $52.00",
            "Read Date: 01/20/2026",
            "Meter total: 900"
        ))
        let conflicting = extractor.extract(from: recognition(
            "Amount Due: $40.00",
            "Amount Due: $41.00"
        ))

        #expect(unrelated.statementProposals.isEmpty)
        #expect(unrelated.serviceGroups.isEmpty)
        #expect(conflicting.statementProposal(for: .amountDue) == nil)
    }

    @Test
    func previousAmountDueDoesNotProduceCurrentAmountDue() {
        let result = extractor.extract(from: recognition("Previous Amount Due: $91.10"))

        #expect(result.statementProposal(for: .amountDue) == nil)
    }

    @Test
    func pastDueDateDoesNotProduceCurrentDueDate() {
        let result = extractor.extract(from: recognition("Past Due Date: 01/15/2026"))

        #expect(result.statementProposal(for: .dueDate) == nil)
    }

    @Test
    func previousBillingPeriodDoesNotProduceCurrentPeriod() {
        let result = extractor.extract(from: recognition(
            "Electricity",
            "Previous Billing Period: 12/01/2025 - 12/31/2025"
        ))
        let electric = result.serviceGroup(for: .electricity)

        #expect(electric?.proposal(for: .billingPeriodStart) == nil)
        #expect(electric?.proposal(for: .billingPeriodEnd) == nil)
        #expect(electric?.proposal(for: .billingDays) == nil)
    }

    @Test
    func averageDailyUsageDoesNotProduceCurrentUsage() {
        let result = extractor.extract(from: recognition("Average Daily Usage: 24 kWh"))

        #expect(result.serviceGroups.isEmpty)
    }

    @Test
    func previousUsageDoesNotProduceCurrentUsage() {
        let result = extractor.extract(from: recognition("Previous Usage: 650 kWh"))

        #expect(result.serviceGroups.isEmpty)
    }

    @Test
    func validCurrentLabelAlongsideExcludedHistoryProducesCurrentProposal() throws {
        let result = extractor.extract(from: recognition(
            "Previous Amount Due: $91.10",
            "Amount Due: $74.28"
        ))

        #expect(try statementDecimal(result, .amountDue) == Decimal(string: "74.28"))
        #expect(result.statementProposal(for: .amountDue)?.provenance.snippet == "Amount Due: $74.28")
    }

    @Test
    func rejectsOtherPriorHistoricalAndComparisonUsageContexts() {
        let result = extractor.extract(from: recognition(
            "Electricity",
            "Prior Usage: 610 kWh",
            "Historical Usage: 590 kWh",
            "Usage Comparison: 600 kWh"
        ))
        let electric = result.serviceGroup(for: .electricity)

        #expect(electric?.proposal(for: .usageQuantity) == nil)
        #expect(electric?.proposal(for: .usageUnit) == nil)
    }

    @Test
    func preservesExpectedPageSnippetAndGeometry() throws {
        let box = CGRect(x: 0.12, y: 0.34, width: 0.5, height: 0.06)
        let result = extractor.extract(from: recognition(pages: [
            page(0, lines: [line("Summary", box: .zero)]),
            page(2, lines: [line("Amount Due: $77.19", box: box)]),
        ]))
        let proposal = try #require(result.statementProposal(for: .amountDue))

        #expect(proposal.provenance.pageIndex == 2)
        #expect(proposal.provenance.snippet == "Amount Due: $77.19")
        #expect(proposal.provenance.normalizedBoundingBox == box)
        #expect(proposal.origin == .extracted)
    }

    @Test
    func derivesBillingDaysOnlyFromConfidentPeriod() throws {
        let result = extractor.extract(from: recognition(
            "Electricity",
            "Billing Period: 01/01/2026 - 01/31/2026"
        ))
        let electric = try #require(result.serviceGroup(for: .electricity))
        let proposal = try #require(electric.proposal(for: .billingDays))

        #expect(proposal.value == .integer(30))
        #expect(proposal.origin == .derived)
    }

    @Test
    func explicitBillingDaysRemainSourceExtracted() throws {
        let result = extractor.extract(from: recognition(
            "Electricity",
            "Billing Period: 01/01/2026 - 01/31/2026",
            "Billing Days: 31"
        ))
        let electric = try #require(result.serviceGroup(for: .electricity))
        let proposal = try #require(electric.proposal(for: .billingDays))

        #expect(proposal.value == .integer(31))
        #expect(proposal.origin == .extracted)
        #expect(proposal.provenance.snippet == "Billing Days: 31")
    }

    @Test @MainActor
    func extractionDoesNotModifyTrustedBillValuesOrVerificationState() {
        let bill = UtilityBill(
            amountDue: Decimal(10),
            verificationState: .verified
        )

        _ = extractor.extract(from: recognition("Amount Due: $99.00"))

        #expect(bill.amountDue == Decimal(10))
        #expect(bill.statementDate == nil)
        #expect(bill.dueDate == nil)
        #expect(bill.serviceDetails.isEmpty)
        #expect(bill.verificationState == .verified)
    }

    @Test
    func repeatedExtractionIsDeterministic() {
        let input = recognition(
            "Statement Date: 01/31/2026",
            "Amount Due: $73.42",
            "Electricity",
            "Billing Period: 01/01/2026 - 01/31/2026",
            "Usage: 650 kWh",
            "Due Date: February 20, 2026"
        )

        #expect(extractor.extract(from: input) == extractor.extract(from: input))
    }

    @Test
    func extractsCurrentElectricCharges() throws {
        let result = extractor.extract(from: recognition(
            "Electricity",
            "Current Electric Charges: $29.30"
        ))
        let electric = try #require(result.serviceGroup(for: .electricity))

        #expect(try serviceDecimal(electric, .currentPeriodCharges) == Decimal(string: "29.30"))
    }

    @Test
    func extractsTotalElectricCharges() throws {
        let result = extractor.extract(from: recognition(
            "Electricity",
            "Total Electric Charges: $29.30"
        ))
        let electric = try #require(result.serviceGroup(for: .electricity))

        #expect(try serviceDecimal(electric, .currentPeriodCharges) == Decimal(string: "29.30"))
    }

    @Test
    func extractsEquivalentCurrentAndTotalGasChargeLabels() throws {
        let current = extractor.extract(from: recognition(
            "Natural Gas",
            "Current Gas Charges: $40.22"
        ))
        let total = extractor.extract(from: recognition(
            "Natural Gas",
            "Total Natural Gas Charges: $40.22"
        ))

        #expect(try serviceDecimal(
            #require(current.serviceGroup(for: .naturalGas)),
            .currentPeriodCharges
        ) == Decimal(string: "40.22"))
        #expect(try serviceDecimal(
            #require(total.serviceGroup(for: .naturalGas)),
            .currentPeriodCharges
        ) == Decimal(string: "40.22"))
    }

    @Test
    func identicalSummaryAndDetailServiceChargesDoNotConflict() throws {
        let result = extractor.extract(from: recognition(
            "Electricity",
            "Total Electric Charges: $29.30",
            "Current Electric Charges: $29.30"
        ))
        let electric = try #require(result.serviceGroup(for: .electricity))

        #expect(try serviceDecimal(electric, .currentPeriodCharges) == Decimal(string: "29.30"))
    }

    @Test
    func conflictingServiceChargeValuesProduceNoProposal() throws {
        let result = extractor.extract(from: recognition(
            "Electricity",
            "Total Electric Charges: $29.30",
            "Current Electric Charges: $30.10"
        ))
        let electric = try #require(result.serviceGroup(for: .electricity))

        #expect(electric.proposal(for: .currentPeriodCharges) == nil)
    }

    @Test
    func scopedBareDateRangeWithBillingDaysExtractsPeriodAndCorrectDayCount() throws {
        let result = extractor.extract(from: recognition(
            "Electricity",
            "10/30/2018 - 11/29/2018 (31 billing days)"
        ))
        let electric = try #require(result.serviceGroup(for: .electricity))
        let days = try #require(electric.proposal(for: .billingDays))

        #expect(try serviceDate(electric, .billingPeriodStart) == utcDate(2018, 10, 30))
        #expect(try serviceDate(electric, .billingPeriodEnd) == utcDate(2018, 11, 29))
        #expect(days.value == .integer(31))
        #expect(days.origin == .extracted)
    }

    @Test
    func bareDateRangeWithBillingDaysRequiresServiceContext() {
        let result = extractor.extract(from: recognition(
            "10/30/2018 - 11/29/2018 (31 billing days)"
        ))

        #expect(result.serviceGroups.isEmpty)
    }

    @Test
    func electricAndGasBarePeriodsRemainSeparate() throws {
        let result = extractor.extract(from: recognition(
            "Electricity",
            "10/30/2018 - 11/29/2018 (31 billing days)",
            "Natural Gas",
            "10/25/2018 - 11/26/2018 (33 billing days)"
        ))
        let electric = try #require(result.serviceGroup(for: .electricity))
        let gas = try #require(result.serviceGroup(for: .naturalGas))

        #expect(try serviceDate(electric, .billingPeriodStart) == utcDate(2018, 10, 30))
        #expect(try serviceInteger(electric, .billingDays) == 31)
        #expect(try serviceDate(gas, .billingPeriodStart) == utcDate(2018, 10, 25))
        #expect(try serviceInteger(gas, .billingDays) == 33)
    }

    @Test
    func associatesSplitStatementAmountDueByGeometry() throws {
        let labelBox = CGRect(x: 0.10, y: 0.80, width: 0.25, height: 0.04)
        let valueBox = CGRect(x: 0.50, y: 0.80, width: 0.15, height: 0.04)
        let result = extractor.extract(from: recognition(pages: [
            page(0, lines: [
                line("Total Amount Due", box: labelBox),
                line("$47.72", box: valueBox),
            ]),
        ]))
        let proposal = try #require(result.statementProposal(for: .amountDue))

        #expect(proposal.value == .decimal(Decimal(string: "47.72") ?? 0))
        #expect(proposal.provenance.pageIndex == 0)
        #expect(proposal.provenance.snippet == "Total Amount Due | $47.72")
        #expect(proposal.provenance.normalizedBoundingBox == labelBox.union(valueBox))
    }

    @Test
    func associatesSplitElectricAndGasChargesWithinTheirScopes() throws {
        let result = extractor.extract(from: recognition(pages: [
            page(0, lines: [
                line("Electricity", box: CGRect(x: 0.1, y: 0.9, width: 0.2, height: 0.04)),
                line("Current Electric Charges", box: CGRect(x: 0.1, y: 0.8, width: 0.3, height: 0.04)),
                line("$29.30", box: CGRect(x: 0.55, y: 0.8, width: 0.12, height: 0.04)),
                line("Natural Gas", box: CGRect(x: 0.1, y: 0.65, width: 0.2, height: 0.04)),
                line("Current Gas Charges", box: CGRect(x: 0.1, y: 0.55, width: 0.3, height: 0.04)),
                line("$40.22", box: CGRect(x: 0.55, y: 0.55, width: 0.12, height: 0.04)),
            ]),
        ]))
        let electric = try #require(result.serviceGroup(for: .electricity))
        let gas = try #require(result.serviceGroup(for: .naturalGas))

        #expect(try serviceDecimal(electric, .currentPeriodCharges) == Decimal(string: "29.30"))
        #expect(try serviceDecimal(gas, .currentPeriodCharges) == Decimal(string: "40.22"))
    }

    @Test
    func associatesSplitElectricityUsageWithExplicitUnit() throws {
        let result = extractor.extract(from: recognition(pages: [
            page(0, lines: [
                line("Electricity", box: CGRect(x: 0.1, y: 0.9, width: 0.2, height: 0.04)),
                line("Total Usage", box: CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.04)),
                line("152.041 kWh", box: CGRect(x: 0.50, y: 0.8, width: 0.2, height: 0.04)),
            ]),
        ]))
        let electric = try #require(result.serviceGroup(for: .electricity))

        #expect(try serviceDecimal(electric, .usageQuantity) == Decimal(string: "152.041"))
        #expect(try serviceText(electric, .usageUnit) == "kWh")
    }

    @Test
    func spatiallyUnrelatedSplitValuesDoNotAssociate() {
        let result = extractor.extract(from: recognition(pages: [
            page(0, lines: [
                line("Total Amount Due", box: CGRect(x: 0.1, y: 0.85, width: 0.25, height: 0.04)),
                line("$47.72", box: CGRect(x: 0.6, y: 0.20, width: 0.12, height: 0.04)),
            ]),
        ]))

        #expect(result.statementProposal(for: .amountDue) == nil)
    }

    @Test
    func competingNearbySplitValuesProduceNoProposal() {
        let result = extractor.extract(from: recognition(pages: [
            page(0, lines: [
                line("Total Amount Due", box: CGRect(x: 0.1, y: 0.8, width: 0.25, height: 0.04)),
                line("$47.72", box: CGRect(x: 0.50, y: 0.8, width: 0.12, height: 0.04)),
                line("$48.10", box: CGRect(x: 0.68, y: 0.8, width: 0.12, height: 0.04)),
            ]),
        ]))

        #expect(result.statementProposal(for: .amountDue) == nil)
    }

    @Test
    func splitAssociationNeverCrossesPages() {
        let result = extractor.extract(from: recognition(pages: [
            page(0, lines: [
                line("Total Amount Due", box: CGRect(x: 0.1, y: 0.8, width: 0.25, height: 0.04)),
            ]),
            page(1, lines: [
                line("$47.72", box: CGRect(x: 0.50, y: 0.8, width: 0.12, height: 0.04)),
            ]),
        ]))

        #expect(result.statementProposal(for: .amountDue) == nil)
    }

    @Test
    func splitUsageValuesDoNotLeakAcrossServiceScopes() throws {
        let result = extractor.extract(from: recognition(pages: [
            page(0, lines: [
                line("Electricity", box: CGRect(x: 0.1, y: 0.9, width: 0.2, height: 0.04)),
                line("Total Usage", box: CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.04)),
                line("152.041 kWh", box: CGRect(x: 0.5, y: 0.8, width: 0.2, height: 0.04)),
                line("Natural Gas", box: CGRect(x: 0.1, y: 0.65, width: 0.2, height: 0.04)),
                line("Total Usage", box: CGRect(x: 0.1, y: 0.55, width: 0.2, height: 0.04)),
                line("8 therms", box: CGRect(x: 0.5, y: 0.55, width: 0.2, height: 0.04)),
            ]),
        ]))
        let electric = try #require(result.serviceGroup(for: .electricity))
        let gas = try #require(result.serviceGroup(for: .naturalGas))

        #expect(try serviceDecimal(electric, .usageQuantity) == Decimal(string: "152.041"))
        #expect(try serviceText(electric, .usageUnit) == "kWh")
        #expect(try serviceDecimal(gas, .usageQuantity) == Decimal(8))
        #expect(try serviceText(gas, .usageUnit) == "therms")
    }

    @Test
    func serviceQualifiedChargeLabelsOverrideSequentialOCRScope() throws {
        let result = extractor.extract(from: recognition(pages: [
            page(0, lines: [
                line("Electricity", box: CGRect(x: 0.1, y: 0.94, width: 0.2, height: 0.04)),
                line("Current Electric Charges", box: CGRect(x: 0.1, y: 0.82, width: 0.3, height: 0.04)),
                line("Current Gas Charges", box: CGRect(x: 0.1, y: 0.70, width: 0.3, height: 0.04)),
                line("$29.30", box: CGRect(x: 0.55, y: 0.82, width: 0.12, height: 0.04)),
                line("40.22", box: CGRect(x: 0.55, y: 0.70, width: 0.12, height: 0.04)),
            ]),
        ]))
        let electric = try #require(result.serviceGroup(for: .electricity))
        let gas = try #require(result.serviceGroup(for: .naturalGas))

        #expect(try serviceDecimal(electric, .currentPeriodCharges) == Decimal(string: "29.30"))
        #expect(try serviceDecimal(gas, .currentPeriodCharges) == Decimal(string: "40.22"))
    }

    @Test
    func sameRowServiceChargeWinsOverLowerConfidenceStackedValue() throws {
        let result = extractor.extract(from: recognition(pages: [
            page(0, lines: [
                line("Total Electric Charges", box: CGRect(x: 0.1, y: 0.80, width: 0.3, height: 0.04)),
                line("1.70", box: CGRect(x: 0.1, y: 0.74, width: 0.12, height: 0.03)),
                line("$29.30", box: CGRect(x: 0.55, y: 0.80, width: 0.12, height: 0.04)),
            ]),
        ]))
        let electric = try #require(result.serviceGroup(for: .electricity))

        #expect(try serviceDecimal(electric, .currentPeriodCharges) == Decimal(string: "29.30"))
    }

    @Test
    func descriptiveTaxLineIsNotSplitMoney() throws {
        let result = extractor.extract(from: recognition(pages: [
            page(0, lines: [
                line("Total Electric Charges", box: CGRect(x: 0.1, y: 0.80, width: 0.3, height: 0.04)),
                line("Utility Users' Tax (6.000%)", box: CGRect(x: 0.1, y: 0.75, width: 0.3, height: 0.03)),
                line("$29.30", box: CGRect(x: 0.55, y: 0.80, width: 0.12, height: 0.04)),
            ]),
        ]))
        let electric = try #require(result.serviceGroup(for: .electricity))

        #expect(try serviceDecimal(electric, .currentPeriodCharges) == Decimal(string: "29.30"))
    }

    @Test
    func descriptiveGasRatesAreNotSplitMoney() throws {
        let result = extractor.extract(from: recognition(pages: [
            page(0, lines: [
                line("Total Gas Charges", box: CGRect(x: 0.1, y: 0.80, width: 0.3, height: 0.04)),
                line("Gas PPP Surcharge ($0.08849 /Therm)", box: CGRect(x: 0.1, y: 0.75, width: 0.35, height: 0.03)),
                line("Utility Users' Tax (6.000%)", box: CGRect(x: 0.1, y: 0.71, width: 0.3, height: 0.03)),
                line("$40.22", box: CGRect(x: 0.55, y: 0.80, width: 0.12, height: 0.04)),
            ]),
        ]))
        let gas = try #require(result.serviceGroup(for: .naturalGas))

        #expect(try serviceDecimal(gas, .currentPeriodCharges) == Decimal(string: "40.22"))
    }

    @Test
    func splitMoneyRejectsDescriptivePercentageAndRateObservations() throws {
        let electricResult = extractor.extract(from: recognition(pages: [
            page(0, lines: [
                line("Total Electric Charges", box: CGRect(x: 0.1, y: 0.80, width: 0.3, height: 0.04)),
                line("Utility Users' Tax (6.000%)", box: CGRect(x: 0.50, y: 0.80, width: 0.3, height: 0.04)),
            ]),
        ]))
        let gasResult = extractor.extract(from: recognition(pages: [
            page(0, lines: [
                line("Total Gas Charges", box: CGRect(x: 0.1, y: 0.80, width: 0.3, height: 0.04)),
                line("Gas PPP Surcharge ($0.08849 /Therm)", box: CGRect(x: 0.50, y: 0.80, width: 0.4, height: 0.04)),
            ]),
        ]))

        #expect(try #require(electricResult.serviceGroup(for: .electricity))
            .proposal(for: .currentPeriodCharges) == nil)
        #expect(try #require(gasResult.serviceGroup(for: .naturalGas))
            .proposal(for: .currentPeriodCharges) == nil)
    }

    @Test
    func splitMoneyAcceptsStandaloneSignedAmount() throws {
        let result = extractor.extract(from: recognition(pages: [
            page(0, lines: [
                line("Total Electric Charges", box: CGRect(x: 0.1, y: 0.80, width: 0.3, height: 0.04)),
                line("-$21.80", box: CGRect(x: 0.55, y: 0.80, width: 0.12, height: 0.04)),
            ]),
        ]))
        let electric = try #require(result.serviceGroup(for: .electricity))

        #expect(try serviceDecimal(electric, .currentPeriodCharges) == Decimal(string: "-21.80"))
    }

    @Test
    func totalElectricUsageIgnoresTierDetailLabels() throws {
        let result = extractor.extract(from: recognition(pages: [
            page(0, lines: [
                line("Electricity", box: CGRect(x: 0.1, y: 0.94, width: 0.2, height: 0.04)),
                line("Total Usage", box: CGRect(x: 0.1, y: 0.82, width: 0.2, height: 0.04)),
                line("152.041000 kWh", box: CGRect(x: 0.50, y: 0.82, width: 0.2, height: 0.04)),
                line("Tier 1 Usage: 100.000000 kWh", box: CGRect(x: 0.1, y: 0.60, width: 0.4, height: 0.04)),
                line("Tier 2 Usage: 52.041000 kWh", box: CGRect(x: 0.1, y: 0.52, width: 0.4, height: 0.04)),
                line("Your Tier Usage: 152.041000 kWh", box: CGRect(x: 0.1, y: 0.44, width: 0.4, height: 0.04)),
            ]),
        ]))
        let electric = try #require(result.serviceGroup(for: .electricity))

        #expect(try serviceDecimal(electric, .usageQuantity) == Decimal(string: "152.041"))
        #expect(try serviceText(electric, .usageUnit) == "kWh")
    }

    @Test
    func agreeingGasAggregateUsageIgnoresTierDetails() throws {
        let result = extractor.extract(from: recognition(pages: [
            page(0, lines: [
                line("Gas Usage This Period: 36.000000 Therms, 31 billing days", box: CGRect(x: 0.1, y: 0.90, width: 0.55, height: 0.04)),
                line("Tier 1 Usage: 20.000000 Therms", box: CGRect(x: 0.1, y: 0.72, width: 0.4, height: 0.04)),
                line("Tier 2 Usage: 16.000000 Therms", box: CGRect(x: 0.1, y: 0.64, width: 0.4, height: 0.04)),
                line("Total Usage", box: CGRect(x: 0.1, y: 0.50, width: 0.2, height: 0.04)),
                line("36.000000 Therms", box: CGRect(x: 0.50, y: 0.50, width: 0.2, height: 0.04)),
            ]),
        ]))
        let gas = try #require(result.serviceGroup(for: .naturalGas))

        #expect(try serviceDecimal(gas, .usageQuantity) == Decimal(36))
        #expect(try serviceText(gas, .usageUnit) == "therms")
        #expect(try serviceInteger(gas, .billingDays) == 31)
    }

    @Test
    func genericUsageLabelCannotCrossEstablishedServiceBoundary() throws {
        let result = extractor.extract(from: recognition(pages: [
            page(0, lines: [
                line("Electricity", box: CGRect(x: 0.1, y: 0.94, width: 0.2, height: 0.04)),
                line("Total Usage", box: CGRect(x: 0.1, y: 0.80, width: 0.2, height: 0.04)),
                line("Natural Gas", box: CGRect(x: 0.1, y: 0.74, width: 0.2, height: 0.04)),
                line("36.000000 Therms", box: CGRect(x: 0.50, y: 0.80, width: 0.2, height: 0.04)),
            ]),
        ]))
        let electric = try #require(result.serviceGroup(for: .electricity))
        let gas = try #require(result.serviceGroup(for: .naturalGas))

        #expect(electric.proposal(for: .usageQuantity) == nil)
        #expect(gas.proposal(for: .usageQuantity) == nil)
    }

    @Test
    func conflictingSameRowServiceChargeValuesProduceNoProposal() throws {
        let result = extractor.extract(from: recognition(pages: [
            page(0, lines: [
                line("Total Electric Charges", box: CGRect(x: 0.1, y: 0.80, width: 0.3, height: 0.04)),
                line("$29.30", box: CGRect(x: 0.50, y: 0.80, width: 0.12, height: 0.04)),
                line("$30.10", box: CGRect(x: 0.66, y: 0.80, width: 0.12, height: 0.04)),
            ]),
        ]))
        let electric = try #require(result.serviceGroup(for: .electricity))

        #expect(electric.proposal(for: .currentPeriodCharges) == nil)
    }

    @Test
    func dateOnlyPresentationPreservesCivilDayOutsideUTC() throws {
        let locale = Locale(identifier: "en_US")
        let expected = [
            (try #require(utcDate(2018, 10, 30)), "Oct 30, 2018"),
            (try #require(utcDate(2018, 11, 29)), "Nov 29, 2018"),
            (try #require(utcDate(2018, 10, 31)), "Oct 31, 2018"),
            (try #require(utcDate(2018, 11, 30)), "Nov 30, 2018"),
        ]
        let nonUTCFormatter = DateFormatter()
        nonUTCFormatter.calendar = Calendar(identifier: .gregorian)
        nonUTCFormatter.locale = locale
        nonUTCFormatter.timeZone = TimeZone(identifier: "America/Los_Angeles")
        nonUTCFormatter.dateStyle = .medium

        #expect(nonUTCFormatter.string(from: expected[0].0) == "Oct 29, 2018")
        for (date, displayedDate) in expected {
            #expect(BillDateOnlyPresentation.string(from: date, locale: locale) == displayedDate)
        }
    }

    private func recognition(_ texts: String...) -> DocumentRecognitionResult {
        recognition(pages: [page(0, lines: texts.map { line($0) })])
    }

    private func recognition(pages: [RecognizedDocumentPage]) -> DocumentRecognitionResult {
        DocumentRecognitionResult(pages: pages)
    }

    private func page(
        _ index: Int,
        lines: [RecognizedDocumentLine]
    ) -> RecognizedDocumentPage {
        RecognizedDocumentPage(pageIndex: index, lines: lines, warnings: [])
    }

    private func line(
        _ text: String,
        box: CGRect = CGRect(x: 0.1, y: 0.8, width: 0.7, height: 0.05)
    ) -> RecognizedDocumentLine {
        RecognizedDocumentLine(text: text, normalizedBoundingBox: box)
    }

    private func utcDate(_ year: Int, _ month: Int, _ day: Int) -> Date? {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        return components.date
    }

    private func statementDecimal(
        _ result: BillExtractionResult,
        _ field: BillStatementFieldName
    ) throws -> Decimal? {
        guard let proposal = result.statementProposal(for: field) else { return nil }
        guard case .decimal(let value) = proposal.value else {
            Issue.record("Expected decimal statement proposal for \(field.rawValue)")
            return nil
        }
        return value
    }

    private func statementDate(
        _ result: BillExtractionResult,
        _ field: BillStatementFieldName
    ) throws -> Date? {
        guard let proposal = result.statementProposal(for: field) else { return nil }
        guard case .date(let value) = proposal.value else {
            Issue.record("Expected date statement proposal for \(field.rawValue)")
            return nil
        }
        return value
    }

    private func serviceDecimal(
        _ group: BillServiceProposalGroup,
        _ field: BillServiceFieldName
    ) throws -> Decimal? {
        guard let proposal = group.proposal(for: field) else { return nil }
        guard case .decimal(let value) = proposal.value else {
            Issue.record("Expected decimal service proposal for \(field.rawValue)")
            return nil
        }
        return value
    }

    private func serviceDate(
        _ group: BillServiceProposalGroup,
        _ field: BillServiceFieldName
    ) throws -> Date? {
        guard let proposal = group.proposal(for: field) else { return nil }
        guard case .date(let value) = proposal.value else {
            Issue.record("Expected date service proposal for \(field.rawValue)")
            return nil
        }
        return value
    }

    private func serviceInteger(
        _ group: BillServiceProposalGroup,
        _ field: BillServiceFieldName
    ) throws -> Int? {
        guard let proposal = group.proposal(for: field) else { return nil }
        guard case .integer(let value) = proposal.value else {
            Issue.record("Expected integer service proposal for \(field.rawValue)")
            return nil
        }
        return value
    }

    private func serviceText(
        _ group: BillServiceProposalGroup,
        _ field: BillServiceFieldName
    ) throws -> String? {
        guard let proposal = group.proposal(for: field) else { return nil }
        guard case .text(let value) = proposal.value else {
            Issue.record("Expected text service proposal for \(field.rawValue)")
            return nil
        }
        return value
    }
}
