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
}
