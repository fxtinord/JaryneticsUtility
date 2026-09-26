import Foundation
import SwiftData
import Testing
@testable import JaryneticsUtility

@MainActor
struct DistributedEnergyModelTests {
    @Test
    func ordinaryServiceDetailsPersistWithoutDistributedEnergy() throws {
        let container = try makeContainer()

        for serviceType in UtilityServiceType.allCases {
            let graph = makeServiceDetail(serviceType: serviceType)
            container.mainContext.insert(graph.bill)
            container.mainContext.insert(graph.detail)
        }
        try container.mainContext.save()

        let verificationContext = ModelContext(container)
        let storedDetails = try verificationContext.fetch(
            FetchDescriptor<UtilityBillServiceDetail>()
        )
        #expect(storedDetails.count == UtilityServiceType.allCases.count)
        #expect(storedDetails.allSatisfy { $0.distributedEnergyDetail == nil })
    }

    @Test
    func distributedEnergyValuesSurvivePersistenceRoundTrip() throws {
        let container = try makeContainer()
        let graph = makeServiceDetail(
            serviceType: .electricity,
            usageQuantity: Decimal(684),
            usageUnit: "kWh"
        )
        let energyID = UUID(uuidString: "00000000-0000-0000-0000-0000000000DE")!
        let energy = DistributedEnergyDetail(
            id: energyID,
            serviceDetail: graph.detail,
            isNetMetered: true,
            netEnergyQuantity: Decimal(-2251),
            netEnergyUnit: "kWh",
            generationQuantity: Decimal(3100),
            generationUnit: "kWh",
            priorEnergyCreditBalance: Decimal(-1178),
            energyCreditReceived: Decimal(2251),
            energyCreditApplied: Decimal(0),
            newEnergyCreditBalance: Decimal(-3429),
            energyCreditUnit: "kWh",
            priorMonetaryCreditBalance: Decimal(string: "-45.60"),
            monetaryCreditReceived: Decimal(string: "12.34"),
            monetaryCreditApplied: Decimal(string: "8.90"),
            newMonetaryCreditBalance: Decimal(string: "-49.04"),
            settlementMonth: 3,
            incentivePaymentAmount: Decimal(string: "125.75"),
            programLabel: "Synthetic Community Energy Credit"
        )
        graph.detail.distributedEnergyDetail = energy

        container.mainContext.insert(graph.bill)
        container.mainContext.insert(graph.detail)
        container.mainContext.insert(energy)
        try container.mainContext.save()

        let verificationContext = ModelContext(container)
        let storedEnergy = try #require(
            verificationContext.fetch(FetchDescriptor<DistributedEnergyDetail>()).first
        )
        let storedDetail = storedEnergy.serviceDetail

        #expect(storedEnergy.id == energyID)
        #expect(storedDetail.id == graph.detail.id)
        #expect(storedDetail.distributedEnergyDetail?.id == energyID)
        #expect(storedEnergy.isNetMetered == true)
        #expect(storedEnergy.netEnergyQuantity == Decimal(-2251))
        #expect(storedEnergy.netEnergyUnit == "kWh")
        #expect(storedEnergy.generationQuantity == Decimal(3100))
        #expect(storedEnergy.generationUnit == "kWh")
        #expect(storedEnergy.priorEnergyCreditBalance == Decimal(-1178))
        #expect(storedEnergy.energyCreditReceived == Decimal(2251))
        #expect(storedEnergy.energyCreditApplied == Decimal(0))
        #expect(storedEnergy.newEnergyCreditBalance == Decimal(-3429))
        #expect(storedEnergy.energyCreditUnit == "kWh")
        #expect(storedEnergy.priorMonetaryCreditBalance == Decimal(string: "-45.60"))
        #expect(storedEnergy.monetaryCreditReceived == Decimal(string: "12.34"))
        #expect(storedEnergy.monetaryCreditApplied == Decimal(string: "8.90"))
        #expect(storedEnergy.newMonetaryCreditBalance == Decimal(string: "-49.04"))
        #expect(storedEnergy.settlementMonth == 3)
        #expect(storedEnergy.incentivePaymentAmount == Decimal(string: "125.75"))
        #expect(storedEnergy.programLabel == "Synthetic Community Energy Credit")

        // Ordinary usage and signed net energy are independent source-supported facts.
        #expect(storedDetail.usageQuantity == Decimal(684))
        #expect(storedDetail.usageUnit == "kWh")
        #expect(storedDetail.usageQuantity != storedEnergy.netEnergyQuantity)
    }

    @Test
    func missingDistributedEnergyFieldsRemainNil() throws {
        let container = try makeContainer()
        let graph = makeServiceDetail(serviceType: .electricity)
        let energy = DistributedEnergyDetail(
            serviceDetail: graph.detail,
            isNetMetered: true
        )
        graph.detail.distributedEnergyDetail = energy

        container.mainContext.insert(graph.bill)
        container.mainContext.insert(graph.detail)
        container.mainContext.insert(energy)
        try container.mainContext.save()

        let verificationContext = ModelContext(container)
        let stored = try #require(
            verificationContext.fetch(FetchDescriptor<DistributedEnergyDetail>()).first
        )
        #expect(stored.netEnergyQuantity == nil)
        #expect(stored.netEnergyUnit == nil)
        #expect(stored.generationQuantity == nil)
        #expect(stored.generationUnit == nil)
        #expect(stored.priorEnergyCreditBalance == nil)
        #expect(stored.energyCreditReceived == nil)
        #expect(stored.energyCreditApplied == nil)
        #expect(stored.newEnergyCreditBalance == nil)
        #expect(stored.energyCreditUnit == nil)
        #expect(stored.priorMonetaryCreditBalance == nil)
        #expect(stored.monetaryCreditReceived == nil)
        #expect(stored.monetaryCreditApplied == nil)
        #expect(stored.newMonetaryCreditBalance == nil)
        #expect(stored.settlementMonth == nil)
        #expect(stored.incentivePaymentAmount == nil)
        #expect(stored.programLabel == nil)
    }

    @Test
    func deletingServiceDetailCascadesDistributedEnergyDeletion() throws {
        let container = try makeContainer()
        let graph = makeServiceDetail(serviceType: .electricity)
        let energy = DistributedEnergyDetail(
            serviceDetail: graph.detail,
            netEnergyQuantity: Decimal(-2251)
        )
        graph.detail.distributedEnergyDetail = energy
        container.mainContext.insert(graph.bill)
        container.mainContext.insert(graph.detail)
        container.mainContext.insert(energy)
        try container.mainContext.save()

        container.mainContext.delete(graph.detail)
        try container.mainContext.save()

        let verificationContext = ModelContext(container)
        #expect(try verificationContext.fetchCount(
            FetchDescriptor<DistributedEnergyDetail>()
        ) == 0)
    }

    @Test
    func deletingBillCascadeLeavesNoDistributedEnergyOrphan() throws {
        let container = try makeContainer()
        let graph = makeServiceDetail(serviceType: .electricity)
        let energy = DistributedEnergyDetail(
            serviceDetail: graph.detail,
            programLabel: "Synthetic Net Metering"
        )
        graph.detail.distributedEnergyDetail = energy
        container.mainContext.insert(graph.bill)
        container.mainContext.insert(graph.detail)
        container.mainContext.insert(energy)
        try container.mainContext.save()

        container.mainContext.delete(graph.bill)
        try container.mainContext.save()

        let verificationContext = ModelContext(container)
        #expect(try verificationContext.fetchCount(
            FetchDescriptor<UtilityBillServiceDetail>()
        ) == 0)
        #expect(try verificationContext.fetchCount(
            FetchDescriptor<DistributedEnergyDetail>()
        ) == 0)
    }

    private func makeServiceDetail(
        serviceType: UtilityServiceType,
        usageQuantity: Decimal? = nil,
        usageUnit: String? = nil
    ) -> (bill: UtilityBill, detail: UtilityBillServiceDetail) {
        let household = Household(name: "Synthetic Household")
        let service = UtilityService(
            serviceType: serviceType,
            providerName: "Synthetic Provider",
            household: household
        )
        let bill = UtilityBill()
        let detail = UtilityBillServiceDetail(
            utilityBill: bill,
            utilityService: service,
            usageQuantity: usageQuantity,
            usageUnit: usageUnit
        )
        return (bill, detail)
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
        return try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
    }
}
