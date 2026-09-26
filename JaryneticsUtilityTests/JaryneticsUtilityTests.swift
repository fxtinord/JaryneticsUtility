import Foundation
import SwiftData
import Testing
@testable import JaryneticsUtility

@MainActor
struct JaryneticsUtilityTests {
    @Test
    func createsHousehold() throws {
        let container = try makeContainer()
        let household = Household(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "Test Household",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        container.mainContext.insert(household)
        try container.mainContext.save()

        let households = try container.mainContext.fetch(FetchDescriptor<Household>())
        #expect(households.count == 1)
        #expect(households.first?.id == household.id)
        #expect(households.first?.name == "Test Household")
        #expect(households.first?.createdAt == household.createdAt)
    }

    @Test
    func createsEachSupportedUtilityServiceType() throws {
        let household = Household(name: "Test Household")
        let services = [
            UtilityService(
                serviceType: .electricity,
                providerName: "Electric Provider",
                household: household
            ),
            UtilityService(
                serviceType: .naturalGas,
                providerName: "Gas Provider",
                household: household
            ),
            UtilityService(
                serviceType: .waterWastewater,
                providerName: "Water Provider",
                household: household
            ),
        ]

        #expect(services.map(\.serviceType) == [
            .electricity,
            .naturalGas,
            .waterWastewater,
        ])
    }

    @Test
    func associatesUtilityServiceWithHousehold() throws {
        let container = try makeContainer()
        let household = Household(name: "Test Household")
        let service = UtilityService(
            serviceType: .electricity,
            providerName: "Electric Provider",
            serviceLabel: "Home",
            household: household
        )

        container.mainContext.insert(service)
        try container.mainContext.save()

        #expect(service.household === household)
        #expect(household.utilityServices.count == 1)
        #expect(household.utilityServices.first === service)
    }

    @Test
    func createsDraftUtilityBill() throws {
        let container = try makeContainer()
        let bill = UtilityBill(
            amountDue: Decimal(string: "92.14"),
            verificationState: .draft
        )

        container.mainContext.insert(bill)
        try container.mainContext.save()

        #expect(bill.verificationState == .draft)
        #expect(bill.serviceDetails.isEmpty)
    }

    @Test
    func transitionsVerificationStateToVerified() throws {
        let container = try makeContainer()
        let bill = UtilityBill()

        container.mainContext.insert(bill)
        bill.verificationState = .verified
        try container.mainContext.save()

        let bills = try container.mainContext.fetch(FetchDescriptor<UtilityBill>())
        #expect(bills.first?.verificationState == .verified)
    }

    @Test
    func preservesMissingOptionalBillFields() throws {
        let container = try makeContainer()
        let bill = UtilityBill()

        container.mainContext.insert(bill)
        try container.mainContext.save()

        let storedBill = try #require(
            container.mainContext.fetch(FetchDescriptor<UtilityBill>()).first
        )
        #expect(storedBill.statementDate == nil)
        #expect(storedBill.amountDue == nil)
        #expect(storedBill.dueDate == nil)
        #expect(storedBill.serviceDetails.isEmpty)
    }

    @Test
    func preservesNormalizedBillValuesAfterPersistenceRoundTrip() throws {
        let container = try makeContainer()
        let household = Household(name: "Test Household")
        let service = UtilityService(
            serviceType: .electricity,
            providerName: "Electric Provider",
            household: household
        )
        let statementDate = Date(timeIntervalSince1970: 1_735_689_600)
        let billingPeriodStart = Date(timeIntervalSince1970: 1_732_838_400)
        let billingPeriodEnd = Date(timeIntervalSince1970: 1_735_516_800)
        let dueDate = Date(timeIntervalSince1970: 1_737_590_400)
        let amountDue = Decimal(string: "128.47")
        let currentPeriodCharges = Decimal(string: "121.32")
        let usageQuantity = Decimal(string: "842.6")
        let bill = UtilityBill(
            statementDate: statementDate,
            amountDue: amountDue,
            dueDate: dueDate,
            verificationState: .needsReview
        )
        let detail = UtilityBillServiceDetail(
            utilityBill: bill,
            utilityService: service,
            billingPeriodStart: billingPeriodStart,
            billingPeriodEnd: billingPeriodEnd,
            billingDays: 31,
            currentPeriodCharges: currentPeriodCharges,
            usageQuantity: usageQuantity,
            usageUnit: "kWh"
        )

        container.mainContext.insert(bill)
        container.mainContext.insert(detail)
        try container.mainContext.save()

        let verificationContext = ModelContext(container)
        let storedBill = try #require(
            verificationContext.fetch(FetchDescriptor<UtilityBill>()).first
        )
        let storedDetail = try #require(storedBill.serviceDetails.first)
        #expect(storedBill.statementDate == statementDate)
        #expect(storedBill.amountDue == amountDue)
        #expect(storedBill.dueDate == dueDate)
        #expect(storedBill.verificationState == .needsReview)
        #expect(storedDetail.utilityService.id == service.id)
        #expect(storedDetail.billingPeriodStart == billingPeriodStart)
        #expect(storedDetail.billingPeriodEnd == billingPeriodEnd)
        #expect(storedDetail.billingDays == 31)
        #expect(storedDetail.currentPeriodCharges == currentPeriodCharges)
        #expect(storedDetail.usageQuantity == usageQuantity)
        #expect(storedDetail.usageUnit == "kWh")
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
