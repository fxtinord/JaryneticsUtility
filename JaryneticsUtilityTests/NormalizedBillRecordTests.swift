import CoreGraphics
import Foundation
import SwiftData
import Testing
@testable import JaryneticsUtility

@MainActor
struct NormalizedBillRecordTests {
    private let resolver = ProviderNeutralBillIdentityResolver()
    private let assembler = NormalizedBillRecordAssembler()

    @Test
    func resolvesOrganizationLikeIssuerNearBillHeaderWithProvenance() throws {
        let headerBox = CGRect(x: 0.08, y: 0.89, width: 0.52, height: 0.06)
        let identity = try #require(resolver.resolve(from: recognition(
            line("North Valley Electric Cooperative", box: headerBox),
            line("Electric Bill Statement", y: 0.80),
            line("Account Summary", y: 0.74)
        )))

        #expect(identity.issuer == "North Valley Electric Cooperative")
        #expect(identity.provenance.pageIndex == 0)
        #expect(identity.provenance.sequenceIndex == 0)
        #expect(identity.provenance.snippet == "North Valley Electric Cooperative")
        #expect(identity.provenance.normalizedBoundingBox == headerBox)
    }

    @Test
    func domainCorroboratesOrganizationIdentity() throws {
        let identity = try #require(resolver.resolve(from: recognition(
            line("Blue River Gas Company", y: 0.64),
            line("www.bluerivergas.com", y: 0.58),
            line("Account Summary", y: 0.52)
        )))

        #expect(identity.issuer == "Blue River Gas Company")
        #expect(identity.supportingEvidence.contains { $0.snippet == "www.bluerivergas.com" })
    }

    @Test
    func customerNameAndServiceAddressAreNotIssuerCandidates() {
        let identity = resolver.resolve(from: recognition(
            line("Customer Name: Jordan Electric", y: 0.90),
            line("Service Address: 18 Pioneer Power Road", y: 0.84),
            line("Electric Bill Statement", y: 0.78)
        ))

        #expect(identity == nil)
    }

    @Test
    func genericBillingHeadingsAreNotIssuerCandidates() {
        let identity = resolver.resolve(from: recognition(
            line("Electric Bill Statement", y: 0.92),
            line("Account Summary", y: 0.86),
            line("Current Charges", y: 0.80)
        ))

        #expect(identity == nil)
    }

    @Test
    func weakAndAmbiguousIdentityEvidenceAbstains() {
        #expect(resolver.resolve(from: recognition(
            line("Metro Municipal Energy", y: 0.40)
        )) == nil)
        #expect(resolver.resolve(from: recognition(
            line("North Valley Electric Cooperative", y: 0.90),
            line("Blue River Gas Company", y: 0.84),
            line("Bill Statement", y: 0.78)
        )) == nil)
    }

    @Test
    func topLevelBrandDefeatsGenericCorporateFamilyDescriptor() throws {
        let identity = try #require(resolver.resolve(from: recognition(
            line("gridco", y: 0.94),
            line("AN METRO HOLDINGS COMPANY", y: 0.89),
            line("Your Electric Bill", y: 0.83),
            line("Account Summary", y: 0.77)
        )))

        #expect(identity.issuer == "gridco")
        #expect(identity.provenance.snippet == "gridco")
    }

    @Test
    func realisticBrandEvidenceBeatsNamedParentDescriptorWithoutProductionMapping() throws {
        let identity = try #require(resolver.resolve(from: recognition(
            line("comed", y: 0.94),
            line("AN EXELON COMPANY", y: 0.89),
            line("Your Electric Bill", y: 0.83),
            line("Account Summary", y: 0.77)
        )))

        #expect(identity.issuer == "comed")
        #expect(identity.provenance.snippet == "comed")
    }

    @Test
    func corporateDescriptorAloneDoesNotBecomeIssuer() {
        let identity = resolver.resolve(from: recognition(
            line("AN METRO HOLDINGS COMPANY", y: 0.93),
            line("Your Energy Bill", y: 0.86),
            line("Account Summary", y: 0.80)
        ))

        #expect(identity == nil)
    }

    @Test
    func separatedEnergySupplierDoesNotReplaceBillIssuer() throws {
        let identity = try #require(resolver.resolve(from: recognition(
            line("North Valley Electric Cooperative", y: 0.94),
            line("Your Electricity Bill", y: 0.88),
            line("Account Summary", y: 0.82),
            line("SUPPLY CHARGES", y: 0.55),
            line("Blue River Energy Company", y: 0.50),
            line("Blue River Energy Company provides your energy", y: 0.46)
        )))

        #expect(identity.issuer == "North Valley Electric Cooperative")
    }

    @Test
    func directBillDatePopulatesNormalizedStatementDateWithProvenance() throws {
        let recognition = recognition(
            line("Metro Municipal Energy", y: 0.94),
            line("Your Energy Bill", y: 0.88),
            line("Bill date Jul 25, 2022", y: 0.82),
            line("Billing summary", y: 0.76)
        )
        let extraction = BillFieldExtractor().extract(from: recognition)
        let record = assembler.assemble(
            recognition: recognition,
            extraction: extraction,
            semanticGuided: emptyGuided
        )
        let proposal = try #require(record.statementDate)

        #expect(dateComponents(proposal.value) == DateComponents(year: 2022, month: 7, day: 25))
        #expect(proposal.provenance.snippet == "Bill date Jul 25, 2022")
        #expect(proposal.provenance.normalizedBoundingBox != nil)
    }

    @Test
    func realisticExtremePageIdentityAndBillDateAssembleWithoutLayoutRule() throws {
        let recognition = recognition(
            line("DUKE ENERGY", y: 0.96),
            line("Your Energy Bill", y: 0.91),
            line("Bill date Jul 25, 2022", y: 0.85),
            line("For service June 22, 2022 through July 21, 2022", y: 0.79),
            line("Billing summary", y: 0.73)
        )
        let extraction = BillFieldExtractor().extract(from: recognition)
        let record = assembler.assemble(
            recognition: recognition,
            extraction: extraction,
            semanticGuided: emptyGuided
        )

        #expect(record.billIssuer?.value == .text("DUKE ENERGY"))
        let statementDate = try #require(record.statementDate)
        #expect(dateComponents(statementDate.value)
            == DateComponents(year: 2022, month: 7, day: 25))
    }

    @Test
    func dueDateAndServicePeriodDoNotBecomeStatementDate() {
        let recognition = recognition(
            line("Metro Municipal Energy", y: 0.94),
            line("Due Date: 08/15/2022", y: 0.84),
            line("Service Period: 06/20/2022 - 07/21/2022", y: 0.78)
        )
        let extraction = BillFieldExtractor().extract(from: recognition)
        let record = assembler.assemble(
            recognition: recognition,
            extraction: extraction,
            semanticGuided: emptyGuided
        )

        #expect(record.statementDate == nil)
    }

    @Test
    func directIssuerDomainAndAmountDueBehaviorRemainPreferred() throws {
        let recognition = recognition(
            line("www.pge.com", y: 0.94),
            line("Statement Date: 10/31/2018", y: 0.86),
            line("Total Amount Due: $47.72", y: 0.80)
        )
        let extraction = BillFieldExtractor().extract(from: recognition)
        let record = assembler.assemble(
            recognition: recognition,
            extraction: extraction,
            semanticGuided: emptyGuided
        )

        #expect(record.billIssuer?.value == .text("PG&E"))
        #expect(record.totalAmountDue?.value == .decimal(Decimal(string: "47.72")!))
        #expect(record.totalAmountDue?.provenance.snippet == "Total Amount Due: $47.72")
    }

    @Test
    func adjacentHeaderFragmentsComposeIntoIssuerWithCombinedProvenance() throws {
        let identity = try #require(resolver.resolve(from: recognition(
            line("NORTH VALLEY", box: CGRect(x: 0.08, y: 0.91, width: 0.30, height: 0.04)),
            line("POWER.", box: CGRect(x: 0.08, y: 0.86, width: 0.18, height: 0.04)),
            line("Your Energy Bill", y: 0.80)
        )))

        #expect(identity.issuer == "NORTH VALLEY POWER")
        #expect(identity.provenance.snippet == "NORTH VALLEY POWER")
        #expect(identity.provenance.sequenceIndex == 0)
        #expect(identity.supportingEvidence.contains { $0.snippet == "NORTH VALLEY" })
        #expect(identity.supportingEvidence.contains { $0.snippet == "POWER." })
    }

    @Test
    func physicalIssuerFragmentStructureComposesWithoutProviderRule() throws {
        let recognition = recognition(
            line("DUKE", box: CGRect(x: 0.07, y: 0.92, width: 0.18, height: 0.04)),
            line("ENERGY.", box: CGRect(x: 0.07, y: 0.87, width: 0.24, height: 0.04)),
            line("duks-enengy.com", y: 0.82),
            line("Your Energy Bill", y: 0.77),
            line("Bill date", y: 0.71),
            line("Jul 25, 2022", y: 0.66)
        )
        let extraction = BillExtractionResult(
            statementProposals: [],
            serviceGroups: [serviceGroup(.electricity, proposals: [
                service(.usageQuantity, .decimal(46)),
                service(.usageUnit, .text("kWh")),
            ])]
        )
        let record = assembler.assemble(
            recognition: recognition,
            extraction: extraction,
            semanticGuided: emptyGuided
        )

        #expect(record.billIssuer?.value == .text("DUKE ENERGY"))
        #expect(dateComponents(try #require(record.statementDate).value)
            == DateComponents(year: 2022, month: 7, day: 25))
        #expect(record.services.first?.usageQuantity?.value == .decimal(46))
        #expect(record.services.first?.usageUnit?.value == .text("kWh"))
    }

    @Test
    func separatedOrDistantIdentityFragmentsDoNotCompose() {
        #expect(resolver.resolve(from: recognition(
            line("NORTH VALLEY", y: 0.94),
            line("Welcome", y: 0.89),
            line("POWER", y: 0.84),
            line("Your Energy Bill", y: 0.78)
        )) == nil)
        #expect(resolver.resolve(from: recognition(
            line("NORTH VALLEY", y: 0.94),
            line("POWER", y: 0.55),
            line("Your Energy Bill", y: 0.49)
        )) == nil)
    }

    @Test
    func ambiguousAdjacentIssuerCompositionsAbstain() {
        let identity = resolver.resolve(from: recognition(
            line("NORTH", y: 0.96),
            line("ENERGY", y: 0.91),
            line("Your Bill", y: 0.86),
            line("BLUE", y: 0.81),
            line("POWER", y: 0.76),
            line("Account Summary", y: 0.71)
        ))

        #expect(identity == nil)
    }

    @Test
    func directIssuerPrecedesWeakerAdjacentComposition() {
        let direct = statement(.billIssuer, .text("Direct Source Utility"))
        let record = assembler.assemble(
            recognition: recognition(
                line("NORTH VALLEY", y: 0.94),
                line("POWER", y: 0.89),
                line("Your Energy Bill", y: 0.83)
            ),
            extraction: .init(statementProposals: [direct], serviceGroups: []),
            semanticGuided: emptyGuided
        )

        #expect(record.billIssuer == direct)
    }

    @Test(arguments: ["Bill date", "Statement date"])
    func adjacentStatementDateLabelResolvesDateOnlyValue(label: String) throws {
        let recognition = recognition(
            line(label, box: CGRect(x: 0.08, y: 0.81, width: 0.22, height: 0.04)),
            line("Jul 25, 2022", box: CGRect(x: 0.08, y: 0.76, width: 0.28, height: 0.04))
        )
        let record = assembler.assemble(
            recognition: recognition,
            extraction: BillFieldExtractor().extract(from: recognition),
            semanticGuided: emptyGuided
        )
        let proposal = try #require(record.statementDate)

        #expect(dateComponents(proposal.value) == DateComponents(year: 2022, month: 7, day: 25))
        #expect(proposal.provenance.snippet == "\(label) · Jul 25, 2022")
        #expect(proposal.provenance.sequenceIndex == 1)
    }

    @Test
    func sameLineStatementDateStillTakesPrecedence() throws {
        let recognition = recognition(
            line("Statement date: Aug 16, 2023", y: 0.84),
            line("Bill date", y: 0.78),
            line("Jul 25, 2022", y: 0.73)
        )
        let extraction = BillFieldExtractor().extract(from: recognition)
        let record = assembler.assemble(
            recognition: recognition,
            extraction: extraction,
            semanticGuided: emptyGuided
        )

        #expect(dateComponents(try #require(record.statementDate).value)
            == DateComponents(year: 2023, month: 8, day: 16))
    }

    @Test
    func dueServiceAndMeterDatesDoNotBecomeAdjacentStatementDate() {
        for lines in [
            [line("Due date", y: 0.84), line("Jul 25, 2022", y: 0.79)],
            [line("Service period", y: 0.84), line("Jun 22, 2022 - Jul 21, 2022", y: 0.79)],
            [line("Meter read date", y: 0.84), line("Jul 25, 2022", y: 0.79)],
        ] {
            let recognition = recognition(lines)
            let record = assembler.assemble(
                recognition: recognition,
                extraction: BillFieldExtractor().extract(from: recognition),
                semanticGuided: emptyGuided
            )
            #expect(record.statementDate == nil)
        }
    }

    @Test
    func conflictingOrDistantAdjacentStatementDatesAbstain() {
        let conflicting = recognition(
            line("Bill date", y: 0.90),
            line("Jul 25, 2022", y: 0.85),
            line("Statement date", y: 0.80),
            line("Aug 16, 2023", y: 0.75)
        )
        let distant = recognition(
            line("Bill date", y: 0.90),
            line("Jul 25, 2022", y: 0.50)
        )

        for recognition in [conflicting, distant] {
            let record = assembler.assemble(
                recognition: recognition,
                extraction: BillFieldExtractor().extract(from: recognition),
                semanticGuided: emptyGuided
            )
            #expect(record.statementDate == nil)
        }
    }

    @Test
    func electricityOnlyRecordPreservesStatementAndServiceScopes() throws {
        let extraction = BillExtractionResult(
            statementProposals: [statement(.statementDate, .date(referenceDate)),
                                 statement(.amountDue, .decimal(42))],
            serviceGroups: [serviceGroup(.electricity, proposals: [
                service(.billingPeriodStart, .date(referenceDate)),
                service(.billingDays, .integer(31)),
                service(.usageQuantity, .decimal(642)),
                service(.usageUnit, .text("kWh")),
            ])]
        )
        let record = assembler.assemble(
            recognition: recognition(line("Pioneer Water & Power", y: 0.90)),
            extraction: extraction,
            semanticGuided: emptyGuided
        )

        #expect(record.billIssuer?.value == .text("Pioneer Water & Power"))
        #expect(record.statementDate?.value == .date(referenceDate))
        #expect(record.totalAmountDue?.value == .decimal(42))
        let electricity = try #require(record.services.first)
        #expect(electricity.serviceType == .electricity)
        #expect(electricity.usageQuantity?.value == .decimal(642))
        #expect(electricity.usageUnit?.value == .text("kWh"))
        #expect(record.state == .proposedUnverified)
    }

    @Test
    func naturalGasOnlyRecordCanUseSupportedSemanticGuidedValues() throws {
        let guided = guidedGroup(.naturalGas, proposals: [
            service(.usageQuantity, .decimal(36), snippet: "Gas Usage · 36 therms"),
            service(.usageUnit, .text("therms"), snippet: "Gas Usage · 36 therms"),
            service(.currentPeriodCharges, .decimal(Decimal(string: "40.22")!)),
        ])
        let record = assembler.assemble(
            recognition: recognition(line("Blue River Gas Company", y: 0.90)),
            extraction: .init(statementProposals: [], serviceGroups: []),
            semanticGuided: .init(serviceAssociations: [guided])
        )
        let gas = try #require(record.services.first)

        #expect(gas.serviceType == .naturalGas)
        #expect(gas.usageQuantity?.value == .decimal(36))
        #expect(gas.currentPeriodCharges?.value == .decimal(Decimal(string: "40.22")!))
    }

    @Test
    func combinedRecordKeepsElectricityAndGasValuesSeparate() throws {
        let guided = SemanticGuidedAssociationResult(serviceAssociations: [
            guidedGroup(.electricity, proposals: [
                service(.usageQuantity, .decimal(Decimal(string: "152.041")!)),
                service(.usageUnit, .text("kWh")),
                service(.currentPeriodCharges, .decimal(Decimal(string: "29.30")!)),
            ]),
            guidedGroup(.naturalGas, proposals: [
                service(.usageQuantity, .decimal(36)),
                service(.usageUnit, .text("therms")),
                service(.currentPeriodCharges, .decimal(Decimal(string: "40.22")!)),
            ]),
        ])
        let record = assembler.assemble(
            recognition: recognition(line("Metro Municipal Energy", y: 0.90)),
            extraction: .init(statementProposals: [], serviceGroups: []),
            semanticGuided: guided
        )

        #expect(record.services.count == 2)
        #expect(record.services.first { $0.serviceType == .electricity }?
            .usageUnit?.value == .text("kWh"))
        #expect(record.services.first { $0.serviceType == .electricity }?
            .currentPeriodCharges?.value == .decimal(Decimal(string: "29.30")!))
        #expect(record.services.first { $0.serviceType == .naturalGas }?
            .usageUnit?.value == .text("therms"))
        #expect(record.services.first { $0.serviceType == .naturalGas }?
            .currentPeriodCharges?.value == .decimal(Decimal(string: "40.22")!))
    }

    @Test
    func directExtractionPrecedesGuidedValuesAndProviderNeutralIdentity() throws {
        let directIssuer = statement(.billIssuer, .text("Direct Source Utility"))
        let directUsage = service(.usageQuantity, .decimal(100))
        let extraction = BillExtractionResult(
            statementProposals: [directIssuer],
            serviceGroups: [serviceGroup(.electricity, proposals: [directUsage])]
        )
        let guided = guidedGroup(.electricity, proposals: [
            service(.usageQuantity, .decimal(999)),
        ])
        let record = assembler.assemble(
            recognition: recognition(line("North Valley Electric Cooperative", y: 0.90)),
            extraction: extraction,
            semanticGuided: .init(serviceAssociations: [guided])
        )

        #expect(record.billIssuer == directIssuer)
        #expect(record.services.first?.usageQuantity == directUsage)
        #expect(record.warnings == [.conflictingIssuerEvidence(
            direct: "Direct Source Utility",
            providerNeutral: "North Valley Electric Cooperative"
        )])
    }

    @Test
    func missingAndAmbiguousFieldsRemainAbsent() {
        let record = assembler.assemble(
            recognition: recognition(line("Account Summary", y: 0.90)),
            extraction: .init(statementProposals: [], serviceGroups: []),
            semanticGuided: emptyGuided
        )

        #expect(record.billIssuer == nil)
        #expect(record.statementDate == nil)
        #expect(record.totalAmountDue == nil)
        #expect(record.services.isEmpty)
    }

    @Test
    func provenanceSurvivesAssembly() throws {
        let proposal = service(
            .currentPeriodCharges,
            .decimal(29),
            snippet: "Total Electric Charges · $29.00",
            page: 3,
            sequence: 7
        )
        let record = assembler.assemble(
            recognition: recognition(line("North Valley Electric Cooperative", y: 0.90)),
            extraction: .init(statementProposals: [], serviceGroups: []),
            semanticGuided: .init(serviceAssociations: [
                guidedGroup(.electricity, proposals: [proposal]),
            ])
        )
        let assembled = try #require(record.services.first?.currentPeriodCharges)

        #expect(assembled.provenance == proposal.provenance)
        #expect(assembled.origin == .extracted)
    }

    @Test
    func distributedEnergyRemainsScopedToItsExtractedService() throws {
        let distributed = BillDistributedEnergyProposalGroup(proposals: [
            BillDistributedEnergyFieldProposal(
                field: .isNetMetered,
                value: .boolean(true),
                provenance: provenance("Net Metered", page: 1, sequence: 4),
                origin: .extracted
            ),
            BillDistributedEnergyFieldProposal(
                field: .netEnergyQuantity,
                value: .decimal(-2251),
                provenance: provenance("Net Metered · -2251 kWh", page: 1, sequence: 5),
                origin: .extracted
            ),
        ])
        let extraction = BillExtractionResult(
            statementProposals: [],
            serviceGroups: [
                serviceGroup(.electricity, proposals: [], distributed: distributed),
                serviceGroup(.naturalGas, proposals: []),
            ]
        )
        let record = assembler.assemble(
            recognition: recognition(line("Metro Municipal Energy", y: 0.90)),
            extraction: extraction,
            semanticGuided: emptyGuided
        )

        #expect(record.services.first { $0.serviceType == .electricity }?
            .distributedEnergy == distributed)
        #expect(record.services.first { $0.serviceType == .naturalGas }?
            .distributedEnergy == nil)
    }

    @Test
    func assemblyDoesNotMutatePersistedBillOrVerificationState() throws {
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

        _ = assembler.assemble(
            recognition: recognition(line("North Valley Electric Cooperative", y: 0.90)),
            extraction: .init(statementProposals: [statement(.amountDue, .decimal(99))],
                              serviceGroups: []),
            semanticGuided: emptyGuided
        )

        let context = ModelContext(container)
        let stored = try #require(context.fetch(FetchDescriptor<UtilityBill>()).first)
        #expect(stored.amountDue == 77)
        #expect(stored.verificationState == .needsReview)
    }

    private var referenceDate: Date { Date(timeIntervalSince1970: 1_700_000_000) }
    private var emptyGuided: SemanticGuidedAssociationResult {
        .init(serviceAssociations: [])
    }

    private func recognition(_ lines: RecognizedDocumentLine...) -> DocumentRecognitionResult {
        .init(pages: [.init(pageIndex: 0, lines: lines, warnings: [])])
    }

    private func recognition(_ lines: [RecognizedDocumentLine]) -> DocumentRecognitionResult {
        .init(pages: [.init(pageIndex: 0, lines: lines, warnings: [])])
    }

    private func line(
        _ text: String,
        y: CGFloat? = nil,
        box: CGRect? = nil
    ) -> RecognizedDocumentLine {
        .init(
            text: text,
            normalizedBoundingBox: box ?? CGRect(x: 0.08, y: y ?? 0.80, width: 0.70, height: 0.05)
        )
    }

    private func statement(
        _ field: BillStatementFieldName,
        _ value: BillProposedValue
    ) -> BillStatementFieldProposal {
        .init(field: field, value: value, provenance: provenance(field.rawValue), origin: .extracted)
    }

    private func service(
        _ field: BillServiceFieldName,
        _ value: BillProposedValue,
        snippet: String? = nil,
        page: Int = 0,
        sequence: Int = 0
    ) -> BillServiceFieldProposal {
        .init(
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

    private func serviceGroup(
        _ type: UtilityServiceType,
        proposals: [BillServiceFieldProposal],
        distributed: BillDistributedEnergyProposalGroup? = nil
    ) -> BillServiceProposalGroup {
        .init(
            serviceType: type,
            serviceIdentityProvenance: provenance("Service identity"),
            proposals: proposals,
            distributedEnergy: distributed
        )
    }

    private func guidedGroup(
        _ type: UtilityServiceType,
        proposals: [BillServiceFieldProposal]
    ) -> SemanticGuidedServiceAssociation {
        .init(serviceType: type, proposals: proposals, reasons: [:])
    }

    private func dateComponents(_ value: BillProposedValue) -> DateComponents? {
        guard case .date(let date) = value else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.dateComponents([.year, .month, .day], from: date)
    }
}
