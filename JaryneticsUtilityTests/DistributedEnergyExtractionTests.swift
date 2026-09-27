import CoreGraphics
import Foundation
import SwiftData
import Testing
@testable import JaryneticsUtility

@MainActor
struct DistributedEnergyExtractionTests {
    private let extractor = BillFieldExtractor()

    @Test
    func extractsSourceReportedResidentialNetMeteringFields() throws {
        let result = extractor.extract(from: recognition(
            "Electricity",
            "Cumulative Credit -1178 kWh",
            "Net Metered -2251 kWh",
            "New Cumulative Credit -3429 kWh",
            "Anniversary Month 3"
        ))
        let electricity = try #require(result.serviceGroup(for: .electricity))
        let distributed = try #require(electricity.distributedEnergy)

        #expect(try boolean(distributed, .isNetMetered) == true)
        #expect(try decimal(distributed, .netEnergyQuantity) == Decimal(-2251))
        #expect(try text(distributed, .netEnergyUnit) == "kWh")
        #expect(try decimal(distributed, .priorEnergyCreditBalance) == Decimal(-1178))
        #expect(try decimal(distributed, .newEnergyCreditBalance) == Decimal(-3429))
        #expect(try text(distributed, .energyCreditUnit) == "kWh")
        #expect(try integer(distributed, .settlementMonth) == 3)
        #expect(electricity.proposal(for: .usageQuantity) == nil)
        #expect(distributed.proposals.allSatisfy { $0.origin == .extracted })
    }

    @Test
    func distributedEnergyIsElectricityOnly() throws {
        let gasResult = extractor.extract(from: recognition(
            "Natural Gas",
            "Net Metered -2251 kWh",
            "Cumulative Credit -1178 kWh"
        ))
        let waterResult = extractor.extract(from: recognition(
            "Water/Wastewater Service",
            "Net Metered -2251 kWh",
            "New Cumulative Credit -3429 kWh"
        ))

        #expect(try #require(gasResult.serviceGroup(for: .naturalGas)).distributedEnergy == nil)
        #expect(try #require(waterResult.serviceGroup(for: .waterWastewater)).distributedEnergy == nil)
    }

    @Test
    func monetaryGenericAndHistoricalCreditsAreExcluded() throws {
        let result = extractor.extract(from: recognition(
            "Electricity",
            "Cumulative Credit: -$11.78",
            "New Cumulative Credit: $34.29",
            "Credit -1178 kWh",
            "Previous Net Metered -2251 kWh",
            "Historical Cumulative Credit -1178 kWh",
            "Tier 1 Usage -3429 kWh",
            "Average Daily Usage -12 kWh"
        ))
        let electricity = try #require(result.serviceGroup(for: .electricity))

        #expect(electricity.distributedEnergy == nil)
    }

    @Test
    func conflictingNetEnergyValuesOmitNetEnergy() throws {
        let result = extractor.extract(from: recognition(
            "Electricity",
            "Net Metered -2251 kWh",
            "Net Metered -2200 kWh"
        ))
        let distributed = try #require(
            result.serviceGroup(for: .electricity)?.distributedEnergy
        )

        #expect(try boolean(distributed, .isNetMetered) == true)
        #expect(distributed.proposal(for: .netEnergyQuantity) == nil)
        #expect(distributed.proposal(for: .netEnergyUnit) == nil)
    }

    @Test
    func conflictingCumulativeCreditsOmitPriorBalance() throws {
        let result = extractor.extract(from: recognition(
            "Electricity",
            "Cumulative Credit -1178 kWh",
            "Cumulative Credit -1200 kWh"
        ))
        let electricity = try #require(result.serviceGroup(for: .electricity))

        #expect(electricity.distributedEnergy == nil)
    }

    @Test
    func splitValuesUseBoundedGeometryAndPreserveProvenance() throws {
        let netLabel = CGRect(x: 0.10, y: 0.82, width: 0.25, height: 0.04)
        let netValue = CGRect(x: 0.52, y: 0.82, width: 0.18, height: 0.04)
        let result = extractor.extract(from: recognition(pages: [
            page(2, lines: [
                line("Electricity", box: CGRect(x: 0.1, y: 0.94, width: 0.2, height: 0.04)),
                line("Net Metered", box: netLabel),
                line("-2251 kWh", box: netValue),
                line("Cumulative Credit", box: CGRect(x: 0.10, y: 0.70, width: 0.25, height: 0.04)),
                line("-1178 kWh", box: CGRect(x: 0.52, y: 0.70, width: 0.18, height: 0.04)),
                line("New Cumulative Credit", box: CGRect(x: 0.10, y: 0.58, width: 0.30, height: 0.04)),
                line("-3429 kWh", box: CGRect(x: 0.52, y: 0.58, width: 0.18, height: 0.04)),
                line("Settlement Month", box: CGRect(x: 0.10, y: 0.46, width: 0.25, height: 0.04)),
                line("3", box: CGRect(x: 0.52, y: 0.46, width: 0.05, height: 0.04)),
            ]),
        ]))
        let distributed = try #require(
            result.serviceGroup(for: .electricity)?.distributedEnergy
        )
        let netProposal = try #require(distributed.proposal(for: .netEnergyQuantity))

        #expect(netProposal.value == .decimal(Decimal(-2251)))
        #expect(netProposal.provenance.pageIndex == 2)
        #expect(netProposal.provenance.snippet == "Net Metered | -2251 kWh")
        #expect(netProposal.provenance.normalizedBoundingBox == netLabel.union(netValue))
        #expect(try decimal(distributed, .priorEnergyCreditBalance) == Decimal(-1178))
        #expect(try decimal(distributed, .newEnergyCreditBalance) == Decimal(-3429))
        #expect(try integer(distributed, .settlementMonth) == 3)

        let unrelated = extractor.extract(from: recognition(pages: [
            page(0, lines: [
                line("Electricity", box: CGRect(x: 0.1, y: 0.94, width: 0.2, height: 0.04)),
                line("Net Metered", box: CGRect(x: 0.1, y: 0.82, width: 0.25, height: 0.04)),
                line("-2251 kWh", box: CGRect(x: 0.7, y: 0.20, width: 0.18, height: 0.04)),
            ]),
        ]))
        let unrelatedGroup = try #require(
            unrelated.serviceGroup(for: .electricity)?.distributedEnergy
        )
        #expect(unrelatedGroup.proposal(for: .netEnergyQuantity) == nil)
    }

    @Test
    func splitValuesNeverAssociateAcrossPages() throws {
        let result = extractor.extract(from: recognition(pages: [
            page(0, lines: [
                line("Electricity", box: CGRect(x: 0.1, y: 0.94, width: 0.2, height: 0.04)),
                line("Net Metered", box: CGRect(x: 0.1, y: 0.82, width: 0.25, height: 0.04)),
            ]),
            page(1, lines: [
                line("-2251 kWh", box: CGRect(x: 0.52, y: 0.82, width: 0.18, height: 0.04)),
            ]),
        ]))
        let distributed = try #require(
            result.serviceGroup(for: .electricity)?.distributedEnergy
        )

        #expect(try boolean(distributed, .isNetMetered) == true)
        #expect(distributed.proposal(for: .netEnergyQuantity) == nil)
    }

    @Test
    func combinedServiceExtractionRemainsSeparate() throws {
        let result = extractor.extract(from: recognition(
            "Statement Date: 11/30/2018",
            "Total Amount Due: $69.52",
            "Electricity",
            "Current Electric Charges: $29.30",
            "Total Usage: 152.041 kWh",
            "Net Metered -2251 kWh",
            "Natural Gas",
            "Current Gas Charges: $40.22",
            "Gas Usage This Period: 36 therms"
        ))
        let electric = try #require(result.serviceGroup(for: .electricity))
        let gas = try #require(result.serviceGroup(for: .naturalGas))

        #expect(try serviceDecimal(electric, .currentPeriodCharges) == Decimal(string: "29.30"))
        #expect(try serviceDecimal(electric, .usageQuantity) == Decimal(string: "152.041"))
        #expect(try decimal(#require(electric.distributedEnergy), .netEnergyQuantity) == Decimal(-2251))
        #expect(try serviceDecimal(gas, .currentPeriodCharges) == Decimal(string: "40.22"))
        #expect(try serviceDecimal(gas, .usageQuantity) == Decimal(36))
        #expect(gas.distributedEnergy == nil)
    }

    @Test
    func extractionDoesNotMutatePersistedDistributedEnergyOrVerification() throws {
        let container = try makeContainer()
        let household = Household(name: "Synthetic Household")
        let service = UtilityService(
            serviceType: .electricity,
            providerName: "Synthetic Provider",
            household: household
        )
        let bill = UtilityBill(verificationState: .needsReview)
        let detail = UtilityBillServiceDetail(
            utilityBill: bill,
            utilityService: service,
            usageQuantity: Decimal(700),
            usageUnit: "kWh"
        )
        let savedEnergy = DistributedEnergyDetail(
            serviceDetail: detail,
            netEnergyQuantity: Decimal(999),
            netEnergyUnit: "kWh"
        )
        detail.distributedEnergyDetail = savedEnergy
        container.mainContext.insert(bill)
        container.mainContext.insert(detail)
        container.mainContext.insert(savedEnergy)
        try container.mainContext.save()

        let result = extractor.extract(from: recognition(
            "Electricity",
            "Net Metered -2251 kWh"
        ))
        #expect(try decimal(
            #require(result.serviceGroup(for: .electricity)?.distributedEnergy),
            .netEnergyQuantity
        ) == Decimal(-2251))

        let verificationContext = ModelContext(container)
        let storedBill = try #require(
            verificationContext.fetch(FetchDescriptor<UtilityBill>()).first
        )
        let storedDetail = try #require(storedBill.serviceDetails.first)
        #expect(storedBill.verificationState == .needsReview)
        #expect(storedDetail.usageQuantity == Decimal(700))
        #expect(storedDetail.distributedEnergyDetail?.netEnergyQuantity == Decimal(999))
        #expect(storedDetail.distributedEnergyDetail?.netEnergyUnit == "kWh")
    }

    @Test
    func distributedEnergyExtractionIsDeterministic() {
        let input = recognition(
            "Electricity",
            "Cumulative Credit -1178 kWh",
            "Net Metered -2251 kWh",
            "New Cumulative Credit -3429 kWh",
            "True-Up Month 3"
        )

        #expect(extractor.extract(from: input) == extractor.extract(from: input))
    }

    @Test
    func emergencyBoilerplateDoesNotEstablishServiceIdentity() {
        let result = extractor.extract(from: recognition(
            "GAS EMERGENCIES",
            "OUTAGE AND ELECTRIC EMERGENCIES",
            "For customer service telephone information call 555-0100",
            "Natural gas safety information",
            "Electric usage means energy consumed during a period"
        ))

        #expect(result.serviceGroups.isEmpty)
    }

    @Test
    func billingMarkersEstablishServicesAndMeaningfulProvenance() throws {
        let electricOnly = extractor.extract(from: recognition("Electric Service"))
        let combined = extractor.extract(from: recognition(
            "Details of Electric Charges",
            "Details of Gas Charges"
        ))
        let electric = try #require(electricOnly.serviceGroup(for: .electricity))

        #expect(electric.serviceIdentityProvenance.snippet == "Electric Service")
        #expect(combined.serviceGroup(for: .electricity) != nil)
        #expect(combined.serviceGroup(for: .naturalGas) != nil)
    }

    @Test
    func recognizesNationalGridIssuerWithProvenance() throws {
        let result = extractor.extract(from: recognition(pages: [
            page(3, lines: [line("National Grid")]),
        ]))
        let issuer = try #require(result.statementProposal(for: .billIssuer))

        #expect(issuer.value == .text("National Grid"))
        #expect(issuer.provenance.pageIndex == 3)
        #expect(issuer.provenance.snippet == "National Grid")
        #expect(issuer.origin == .extracted)
    }

    @Test
    func recognizesAgreeingPGEIssuerAliases() throws {
        let result = extractor.extract(from: recognition(
            "PG&E",
            "Pacific Gas and Electric Company",
            "www.pge.com"
        ))
        let issuer = try #require(result.statementProposal(for: .billIssuer))

        #expect(issuer.value == .text("PG&E"))
    }

    @Test
    func conflictingCanonicalIssuersOmitBillIssuer() {
        let result = extractor.extract(from: recognition(
            "National Grid",
            "PG&E"
        ))

        #expect(result.statementProposal(for: .billIssuer) == nil)
    }

    @Test
    func newYorkRowsKeepTheirOwnSignedValues() throws {
        let result = extractor.extract(from: recognition(pages: [
            page(0, lines: [
                line("Electric Service", box: CGRect(x: 0.05, y: 0.94, width: 0.25, height: 0.04)),
                line("Cumulative Credit", box: CGRect(x: 0.10, y: 0.82, width: 0.42, height: 0.04)),
                line("-1178 kWh", box: CGRect(x: 0.44, y: 0.82, width: 0.18, height: 0.04)),
                line("Net Metered", box: CGRect(x: 0.10, y: 0.75, width: 0.42, height: 0.04)),
                line("-2251 kWh", box: CGRect(x: 0.44, y: 0.75, width: 0.18, height: 0.04)),
                line("New Cumulative Credit", box: CGRect(x: 0.10, y: 0.68, width: 0.42, height: 0.04)),
                line("-3429 kWh", box: CGRect(x: 0.44, y: 0.68, width: 0.18, height: 0.04)),
            ]),
        ]))
        let distributed = try #require(
            result.serviceGroup(for: .electricity)?.distributedEnergy
        )

        #expect(try decimal(distributed, .priorEnergyCreditBalance) == Decimal(-1178))
        #expect(try decimal(distributed, .netEnergyQuantity) == Decimal(-2251))
        #expect(try decimal(distributed, .newEnergyCreditBalance) == Decimal(-3429))
    }

    @Test
    func missingCreditValueDoesNotBorrowNeighboringRowValue() throws {
        let result = extractor.extract(from: recognition(pages: [
            page(0, lines: [
                line("Electric Service", box: CGRect(x: 0.05, y: 0.94, width: 0.25, height: 0.04)),
                line("Cumulative Credit", box: CGRect(x: 0.10, y: 0.82, width: 0.42, height: 0.04)),
                line("Net Metered", box: CGRect(x: 0.10, y: 0.76, width: 0.42, height: 0.04)),
                line("-2251 kWh", box: CGRect(x: 0.44, y: 0.76, width: 0.18, height: 0.04)),
                line("New Cumulative Credit", box: CGRect(x: 0.10, y: 0.68, width: 0.42, height: 0.04)),
                line("-3429 kWh", box: CGRect(x: 0.44, y: 0.68, width: 0.18, height: 0.04)),
            ]),
        ]))
        let distributed = try #require(
            result.serviceGroup(for: .electricity)?.distributedEnergy
        )

        #expect(distributed.proposal(for: .priorEnergyCreditBalance) == nil)
        #expect(try decimal(distributed, .netEnergyQuantity) == Decimal(-2251))
        #expect(try decimal(distributed, .newEnergyCreditBalance) == Decimal(-3429))
    }

    @Test
    func settlementMonthRemainsBounded() throws {
        let valid = extractor.extract(from: recognition(
            "Electric Service",
            "Anniversary Month 12"
        ))
        let invalid = extractor.extract(from: recognition(
            "Electric Service",
            "Settlement Month 13"
        ))

        #expect(try integer(
            #require(valid.serviceGroup(for: .electricity)?.distributedEnergy),
            .settlementMonth
        ) == 12)
        #expect(invalid.serviceGroup(for: .electricity)?.distributedEnergy == nil)
    }

    @Test
    func massachusettsNetMeteringContextSupportsSignedTotalUsage() throws {
        let result = extractor.extract(from: recognition(
            "Electric Service",
            "Total Usage -277 kWh",
            "Net Met Cr -$71.91"
        ))
        let electric = try #require(result.serviceGroup(for: .electricity))
        let distributed = try #require(electric.distributedEnergy)

        #expect(try boolean(distributed, .isNetMetered) == true)
        #expect(try decimal(distributed, .netEnergyQuantity) == Decimal(-277))
        #expect(try text(distributed, .netEnergyUnit) == "kWh")
        #expect(electric.proposal(for: .usageQuantity) == nil)
        #expect(distributed.proposal(for: .priorEnergyCreditBalance) == nil)
        #expect(distributed.proposal(for: .newEnergyCreditBalance) == nil)
    }

    @Test
    func signedTotalUsageWithoutNetMeteringContextIsNotNetEnergy() throws {
        let result = extractor.extract(from: recognition(
            "Electric Service",
            "Total Usage -277 kWh"
        ))

        #expect(try #require(result.serviceGroup(for: .electricity)).distributedEnergy == nil)
    }

    @Test
    func solarChoiceDoesNotEstablishDistributedEnergy() throws {
        let result = extractor.extract(from: recognition(
            "Electric Service",
            "Solar Choice Plan - 100%",
            "Renewable energy program enrollment"
        ))

        #expect(try #require(result.serviceGroup(for: .electricity)).distributedEnergy == nil)
    }

    @Test
    func pgeCombinedBillBehaviorRemainsIntactWithSolarChoice() throws {
        let result = extractor.extract(from: recognition(
            "PG&E",
            "Total Amount Due: $47.72",
            "Current Electric Charges: $29.30",
            "Total Usage: 152.041 kWh",
            "Solar Choice Plan - 100%",
            "Current Gas Charges: $40.22",
            "Gas Usage This Period: 36 therms"
        ))
        let electric = try #require(result.serviceGroup(for: .electricity))
        let gas = try #require(result.serviceGroup(for: .naturalGas))

        #expect(result.statementProposal(for: .billIssuer)?.value == .text("PG&E"))
        #expect(try statementDecimal(result, .amountDue) == Decimal(string: "47.72"))
        #expect(try serviceDecimal(electric, .currentPeriodCharges) == Decimal(string: "29.30"))
        #expect(try serviceDecimal(electric, .usageQuantity) == Decimal(string: "152.041"))
        #expect(electric.distributedEnergy == nil)
        #expect(try serviceDecimal(gas, .currentPeriodCharges) == Decimal(string: "40.22"))
        #expect(try serviceDecimal(gas, .usageQuantity) == Decimal(36))
        #expect(gas.distributedEnergy == nil)
    }

    @Test
    func singleElectricServiceScopesMarkerlessDistributedEnergyContinuationPage() throws {
        let result = extractor.extract(from: recognition(pages: [
            page(0, lines: [
                line("National Grid"),
                line("Electric Service"),
                line("GAS EMERGENCIES"),
            ]),
            page(1, lines: [
                line("Cumulative Credit -1178 kWh"),
                line("New Cumulative Credit -3429 kWh"),
                line("Anniversary Month 3"),
            ]),
        ]))
        let electric = try #require(result.serviceGroup(for: .electricity))
        let distributed = try #require(electric.distributedEnergy)

        #expect(result.serviceGroups.count == 1)
        #expect(electric.serviceIdentityProvenance.pageIndex == 0)
        #expect(electric.serviceIdentityProvenance.snippet == "Electric Service")
        #expect(try decimal(distributed, .priorEnergyCreditBalance) == Decimal(-1178))
        #expect(try decimal(distributed, .newEnergyCreditBalance) == Decimal(-3429))
        #expect(try integer(distributed, .settlementMonth) == 3)
    }

    @Test
    func newYorkMultiPageNetMeteringFieldsRemainVisible() throws {
        let result = extractor.extract(from: recognition(pages: [
            page(0, lines: [
                line("National Grid"),
                line("Electric Service"),
                line("OUTAGE AND ELECTRIC EMERGENCIES"),
                line("GAS EMERGENCIES"),
            ]),
            page(1, lines: [
                line("Cumulative Credit -1178 kWh"),
                line("Net Metered -2251 kWh"),
                line("New Cumulative Credit -3429 kWh"),
                line("Anniversary Month 3"),
            ]),
        ]))
        let distributed = try #require(
            result.serviceGroup(for: .electricity)?.distributedEnergy
        )

        #expect(result.serviceGroup(for: .naturalGas) == nil)
        #expect(try boolean(distributed, .isNetMetered) == true)
        #expect(try decimal(distributed, .netEnergyQuantity) == Decimal(-2251))
        #expect(try text(distributed, .netEnergyUnit) == "kWh")
        #expect(try decimal(distributed, .priorEnergyCreditBalance) == Decimal(-1178))
        #expect(try decimal(distributed, .newEnergyCreditBalance) == Decimal(-3429))
        #expect(try text(distributed, .energyCreditUnit) == "kWh")
        #expect(try integer(distributed, .settlementMonth) == 3)
    }

    @Test
    func massachusettsNetMeteringEvidenceEstablishesElectricityAcrossPages() throws {
        let result = extractor.extract(from: recognition(pages: [
            page(0, lines: [
                line("National Grid"),
                line("Amount Due: $0.00"),
                line("Customer service telephone information"),
            ]),
            page(1, lines: [
                line("Total Usage -277 kWh"),
                line("Net Metering Credit -$71.91"),
            ]),
        ]))
        let electric = try #require(result.serviceGroup(for: .electricity))
        let distributed = try #require(electric.distributedEnergy)

        #expect(electric.serviceIdentityProvenance.pageIndex == 1)
        #expect(electric.serviceIdentityProvenance.snippet == "Net Metering Credit -$71.91")
        #expect(try boolean(distributed, .isNetMetered) == true)
        #expect(try decimal(distributed, .netEnergyQuantity) == Decimal(-277))
        #expect(try text(distributed, .netEnergyUnit) == "kWh")
        #expect(distributed.proposal(for: .priorEnergyCreditBalance) == nil)
        #expect(distributed.proposal(for: .newEnergyCreditBalance) == nil)
    }

    @Test
    func multiServiceDocumentDoesNotBlanketScopeMarkerlessContinuationPage() throws {
        let result = extractor.extract(from: recognition(pages: [
            page(0, lines: [
                line("Electric Service"),
                line("Gas Service"),
            ]),
            page(1, lines: [
                line("Current Period Charges: $99.00"),
                line("Usage: 999 kWh"),
            ]),
        ]))
        let electric = try #require(result.serviceGroup(for: .electricity))
        let gas = try #require(result.serviceGroup(for: .naturalGas))

        #expect(electric.proposals.isEmpty)
        #expect(electric.distributedEnergy == nil)
        #expect(gas.proposals.isEmpty)
        #expect(gas.distributedEnergy == nil)
    }

    @Test
    func realNYRowSpacingAssignsEachValueOnlyToItsClosestRow() throws {
        let result = extractor.extract(from: recognition(pages: [
            page(0, lines: [line("Electric Service")]),
            page(1, lines: [
                line("Cumulative Credit", box: CGRect(x: 0.10, y: 0.697917, width: 0.25, height: 0.006)),
                line("1178 kWh", box: CGRect(x: 0.60, y: 0.697917, width: 0.12, height: 0.006)),
                line("Net Metered", box: CGRect(x: 0.10, y: 0.683333, width: 0.20, height: 0.006)),
                line("2251 kWh", box: CGRect(x: 0.60, y: 0.683103, width: 0.12, height: 0.006)),
                line("New Cumulative Credit", box: CGRect(x: 0.10, y: 0.668750, width: 0.30, height: 0.006)),
                line("3429 kWh", box: CGRect(x: 0.60, y: 0.668750, width: 0.12, height: 0.006)),
            ]),
        ]))
        let distributed = try #require(result.serviceGroup(for: .electricity)?.distributedEnergy)

        #expect(try decimal(distributed, .priorEnergyCreditBalance) == Decimal(1178))
        #expect(try decimal(distributed, .netEnergyQuantity) == Decimal(2251))
        #expect(try decimal(distributed, .newEnergyCreditBalance) == Decimal(3429))
    }

    @Test
    func failedRefinementOmitsInsteadOfInferringMissingSign() throws {
        let result = extractor.extract(from: recognition(pages: [page(0, lines: [
            line("Electric Service"),
            line("Net Metered", refinement: RecognizedRowRefinement(
                kind: .signedEnergy, valueText: nil, normalizedBoundingBox: nil
            )),
            line("2251 kWh"),
        ])]))
        let distributed = try #require(result.serviceGroup(for: .electricity)?.distributedEnergy)
        #expect(distributed.proposal(for: .netEnergyQuantity) == nil)
    }

    @Test
    func sourceRecognizedSignedRefinementIsPreservedExactly() throws {
        let result = extractor.extract(from: recognition(pages: [page(0, lines: [
            line("Electric Service"),
            line("Net Metered", box: CGRect(x: 0.1, y: 0.70, width: 0.2, height: 0.02),
                 refinement: RecognizedRowRefinement(
                    kind: .signedEnergy,
                    valueText: "-2251 kWh",
                    normalizedBoundingBox: CGRect(x: 0.5, y: 0.70, width: 0.2, height: 0.02)
                 )),
        ])]))
        let distributed = try #require(result.serviceGroup(for: .electricity)?.distributedEnergy)
        #expect(try decimal(distributed, .netEnergyQuantity) == Decimal(-2251))
    }

    @Test
    func settlementMonthRequiresExplicitSuccessfulRecognition() throws {
        let omitted = extractor.extract(from: recognition(pages: [page(0, lines: [
            line("Electric Service"), line("Net Metered -1 kWh"),
            line("Anniversary Month", refinement: RecognizedRowRefinement(
                kind: .settlementMonth, valueText: nil, normalizedBoundingBox: nil
            )),
        ])]))
        let accepted = extractor.extract(from: recognition(pages: [page(0, lines: [
            line("Electric Service"), line("Net Metered -1 kWh"),
            line("Anniversary Month", refinement: RecognizedRowRefinement(
                kind: .settlementMonth, valueText: "3", normalizedBoundingBox: nil
            )),
        ])]))
        #expect(try #require(omitted.serviceGroup(for: .electricity)?.distributedEnergy)
            .proposal(for: .settlementMonth) == nil)
        #expect(try integer(
            #require(accepted.serviceGroup(for: .electricity)?.distributedEnergy),
            .settlementMonth
        ) == 3)
    }

    @Test
    func massachusettsUsesOnlyCleanStandaloneSignedEnergy() throws {
        let accepted = extractor.extract(from: recognition(
            "Net Met Cr",
            "-277 kWh",
            "0.25959 × •277 kWh",
            "Net Metering Credit: $-71.91"
        ))
        let unsigned = extractor.extract(from: recognition("Net Met Cr", "277 kWh"))
        #expect(try decimal(
            #require(accepted.serviceGroup(for: .electricity)?.distributedEnergy),
            .netEnergyQuantity
        ) == Decimal(-277))
        #expect(try #require(unsigned.serviceGroup(for: .electricity)?.distributedEnergy)
            .proposal(for: .netEnergyQuantity) == nil)
    }

    @Test
    func signedEnergyFallbackRequiresTwoAgreeingRecognitions() {
        #expect(DocumentRecognitionService.corroboratedSignedEnergyValue(
            from: [["+2251 kWh"]]
        ) == nil)
        #expect(DocumentRecognitionService.corroboratedSignedEnergyValue(
            from: [["-2251 kWh"]]
        ) == nil)
        #expect(DocumentRecognitionService.corroboratedSignedEnergyValue(
            from: [["-2,251 kWh"], ["-2251 kWh"]]
        ) == "-2251 kWh")
        #expect(DocumentRecognitionService.corroboratedSignedEnergyValue(
            from: [["+2251 kWh"], ["+2,251 kWh"]]
        ) == "+2251 kWh")
    }

    @Test
    func signedEnergyFallbackRejectsSignOrUnsignedDisagreement() {
        #expect(DocumentRecognitionService.corroboratedSignedEnergyValue(
            from: [["+2251 kWh"], ["-2251 kWh"]]
        ) == nil)
        #expect(DocumentRecognitionService.corroboratedSignedEnergyValue(
            from: [["-2251 kWh"], ["2251 kWh"]]
        ) == nil)
    }

    @Test
    func adjacentSignedRowDoesNotSuppressTargetRefinement() {
        let service = DocumentRecognitionService()
        let lines = [
            line("Cumulative Credit", box: CGRect(x: 0.10, y: 0.697917, width: 0.25, height: 0.006)),
            line("Net Metered", box: CGRect(x: 0.10, y: 0.683333, width: 0.20, height: 0.006)),
            line("-2251 kWh", box: CGRect(x: 0.60, y: 0.683103, width: 0.12, height: 0.006)),
            line("New Cumulative Credit", box: CGRect(x: 0.10, y: 0.668750, width: 0.30, height: 0.006)),
            line("-3429 kWh", box: CGRect(x: 0.60, y: 0.668750, width: 0.12, height: 0.006)),
        ]

        #expect(service.hasPrimaryRowValue(at: 0, among: lines, kind: .signedEnergy) == false)
        #expect(service.hasPrimaryRowValue(at: 1, among: lines, kind: .signedEnergy) == true)
        #expect(service.hasPrimaryRowValue(at: 3, among: lines, kind: .signedEnergy) == true)
    }

    @Test
    func cumulativeCreditRefinementOmitsFailureAndPreservesCorroboratedNewBalance() throws {
        let result = extractor.extract(from: recognition(pages: [page(0, lines: [
            line("Electric Service"),
            line("Cumulative Credit", refinement: RecognizedRowRefinement(
                kind: .signedEnergy, valueText: nil, normalizedBoundingBox: nil
            )),
            line("New Cumulative Credit", refinement: RecognizedRowRefinement(
                kind: .signedEnergy,
                valueText: "-3429 kWh",
                normalizedBoundingBox: CGRect(x: 0.5, y: 0.7, width: 0.2, height: 0.02)
            )),
        ])]))
        let distributed = try #require(result.serviceGroup(for: .electricity)?.distributedEnergy)

        #expect(distributed.proposal(for: .priorEnergyCreditBalance) == nil)
        #expect(try decimal(distributed, .newEnergyCreditBalance) == Decimal(-3429))
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
        box: CGRect = CGRect(x: 0.1, y: 0.8, width: 0.7, height: 0.05),
        refinement: RecognizedRowRefinement? = nil
    ) -> RecognizedDocumentLine {
        RecognizedDocumentLine(
            text: text,
            normalizedBoundingBox: box,
            rowRefinement: refinement
        )
    }


    private func boolean(
        _ group: BillDistributedEnergyProposalGroup,
        _ field: BillDistributedEnergyFieldName
    ) throws -> Bool? {
        guard let proposal = group.proposal(for: field) else { return nil }
        guard case .boolean(let value) = proposal.value else {
            Issue.record("Expected Boolean distributed-energy proposal for \(field.rawValue)")
            return nil
        }
        return value
    }

    private func decimal(
        _ group: BillDistributedEnergyProposalGroup,
        _ field: BillDistributedEnergyFieldName
    ) throws -> Decimal? {
        guard let proposal = group.proposal(for: field) else { return nil }
        guard case .decimal(let value) = proposal.value else {
            Issue.record("Expected decimal distributed-energy proposal for \(field.rawValue)")
            return nil
        }
        return value
    }

    private func integer(
        _ group: BillDistributedEnergyProposalGroup,
        _ field: BillDistributedEnergyFieldName
    ) throws -> Int? {
        guard let proposal = group.proposal(for: field) else { return nil }
        guard case .integer(let value) = proposal.value else {
            Issue.record("Expected integer distributed-energy proposal for \(field.rawValue)")
            return nil
        }
        return value
    }

    private func text(
        _ group: BillDistributedEnergyProposalGroup,
        _ field: BillDistributedEnergyFieldName
    ) throws -> String? {
        guard let proposal = group.proposal(for: field) else { return nil }
        guard case .text(let value) = proposal.value else {
            Issue.record("Expected text distributed-energy proposal for \(field.rawValue)")
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

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Household.self,
            UtilityService.self,
            UtilityBill.self,
            UtilityBillServiceDetail.self,
            DistributedEnergyDetail.self,
            SourceDocument.self,
        ])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
