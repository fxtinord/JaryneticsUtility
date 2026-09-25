import Foundation
import SwiftData

enum UtilityServiceType: String, Codable, CaseIterable {
    case electricity
    case naturalGas
    case waterWastewater = "water/wastewater"
}

enum BillVerificationState: String, Codable, CaseIterable {
    case draft
    case needsReview
    case verified
}

@Model
final class Household {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    @Relationship(deleteRule: .cascade, inverse: \UtilityService.household)
    var utilityServices: [UtilityService]

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.utilityServices = []
    }
}

@Model
final class UtilityService {
    @Attribute(.unique) var id: UUID
    var serviceType: UtilityServiceType
    var providerName: String
    var serviceLabel: String?
    var household: Household
    @Relationship(deleteRule: .cascade, inverse: \UtilityBill.utilityService)
    var bills: [UtilityBill]

    init(
        id: UUID = UUID(),
        serviceType: UtilityServiceType,
        providerName: String,
        serviceLabel: String? = nil,
        household: Household
    ) {
        self.id = id
        self.serviceType = serviceType
        self.providerName = providerName
        self.serviceLabel = serviceLabel
        self.household = household
        self.bills = []
    }
}

@Model
final class UtilityBill {
    @Attribute(.unique) var id: UUID
    var utilityService: UtilityService
    var statementDate: Date?
    var billingPeriodStart: Date?
    var billingPeriodEnd: Date?
    var billingDays: Int?
    var amountDue: Decimal?
    var currentPeriodCharges: Decimal?
    var usageQuantity: Decimal?
    var usageUnit: String?
    var dueDate: Date?
    var verificationState: BillVerificationState
    var createdAt: Date

    init(
        id: UUID = UUID(),
        utilityService: UtilityService,
        statementDate: Date? = nil,
        billingPeriodStart: Date? = nil,
        billingPeriodEnd: Date? = nil,
        billingDays: Int? = nil,
        amountDue: Decimal? = nil,
        currentPeriodCharges: Decimal? = nil,
        usageQuantity: Decimal? = nil,
        usageUnit: String? = nil,
        dueDate: Date? = nil,
        verificationState: BillVerificationState = .draft,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.utilityService = utilityService
        self.statementDate = statementDate
        self.billingPeriodStart = billingPeriodStart
        self.billingPeriodEnd = billingPeriodEnd
        self.billingDays = billingDays
        self.amountDue = amountDue
        self.currentPeriodCharges = currentPeriodCharges
        self.usageQuantity = usageQuantity
        self.usageUnit = usageUnit
        self.dueDate = dueDate
        self.verificationState = verificationState
        self.createdAt = createdAt
    }
}
