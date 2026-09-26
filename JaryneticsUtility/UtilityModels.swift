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

enum SourceDocumentType: String, Codable {
    case pdf
    case image
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
    @Relationship(deleteRule: .cascade, inverse: \UtilityBillServiceDetail.utilityService)
    var billDetails: [UtilityBillServiceDetail]

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
        self.billDetails = []
    }
}

@Model
final class UtilityBill {
    @Attribute(.unique) var id: UUID
    var statementDate: Date?
    var amountDue: Decimal?
    var dueDate: Date?
    var verificationState: BillVerificationState
    var createdAt: Date
    @Relationship(deleteRule: .cascade, inverse: \UtilityBillServiceDetail.utilityBill)
    var serviceDetails: [UtilityBillServiceDetail]
    @Relationship(deleteRule: .cascade)
    var sourceDocument: SourceDocument?

    init(
        id: UUID = UUID(),
        statementDate: Date? = nil,
        amountDue: Decimal? = nil,
        dueDate: Date? = nil,
        verificationState: BillVerificationState = .draft,
        createdAt: Date = Date(),
        sourceDocument: SourceDocument? = nil
    ) {
        self.id = id
        self.statementDate = statementDate
        self.amountDue = amountDue
        self.dueDate = dueDate
        self.verificationState = verificationState
        self.createdAt = createdAt
        self.serviceDetails = []
        self.sourceDocument = sourceDocument
    }
}

@Model
final class UtilityBillServiceDetail {
    @Attribute(.unique) var id: UUID
    var utilityBill: UtilityBill
    var utilityService: UtilityService
    var billingPeriodStart: Date?
    var billingPeriodEnd: Date?
    var billingDays: Int?
    var currentPeriodCharges: Decimal?
    var usageQuantity: Decimal?
    var usageUnit: String?
    @Relationship(deleteRule: .cascade, inverse: \DistributedEnergyDetail.serviceDetail)
    var distributedEnergyDetail: DistributedEnergyDetail?

    init(
        id: UUID = UUID(),
        utilityBill: UtilityBill,
        utilityService: UtilityService,
        billingPeriodStart: Date? = nil,
        billingPeriodEnd: Date? = nil,
        billingDays: Int? = nil,
        currentPeriodCharges: Decimal? = nil,
        usageQuantity: Decimal? = nil,
        usageUnit: String? = nil
    ) {
        self.id = id
        self.utilityBill = utilityBill
        self.utilityService = utilityService
        self.billingPeriodStart = billingPeriodStart
        self.billingPeriodEnd = billingPeriodEnd
        self.billingDays = billingDays
        self.currentPeriodCharges = currentPeriodCharges
        self.usageQuantity = usageQuantity
        self.usageUnit = usageUnit
        self.distributedEnergyDetail = nil
    }
}

@Model
final class DistributedEnergyDetail {
    @Attribute(.unique) var id: UUID
    var serviceDetail: UtilityBillServiceDetail
    var isNetMetered: Bool?
    var netEnergyQuantity: Decimal?
    var netEnergyUnit: String?
    var generationQuantity: Decimal?
    var generationUnit: String?
    var priorEnergyCreditBalance: Decimal?
    var energyCreditReceived: Decimal?
    var energyCreditApplied: Decimal?
    var newEnergyCreditBalance: Decimal?
    var energyCreditUnit: String?
    var priorMonetaryCreditBalance: Decimal?
    var monetaryCreditReceived: Decimal?
    var monetaryCreditApplied: Decimal?
    var newMonetaryCreditBalance: Decimal?
    var settlementMonth: Int?
    var incentivePaymentAmount: Decimal?
    var programLabel: String?

    init(
        id: UUID = UUID(),
        serviceDetail: UtilityBillServiceDetail,
        isNetMetered: Bool? = nil,
        netEnergyQuantity: Decimal? = nil,
        netEnergyUnit: String? = nil,
        generationQuantity: Decimal? = nil,
        generationUnit: String? = nil,
        priorEnergyCreditBalance: Decimal? = nil,
        energyCreditReceived: Decimal? = nil,
        energyCreditApplied: Decimal? = nil,
        newEnergyCreditBalance: Decimal? = nil,
        energyCreditUnit: String? = nil,
        priorMonetaryCreditBalance: Decimal? = nil,
        monetaryCreditReceived: Decimal? = nil,
        monetaryCreditApplied: Decimal? = nil,
        newMonetaryCreditBalance: Decimal? = nil,
        settlementMonth: Int? = nil,
        incentivePaymentAmount: Decimal? = nil,
        programLabel: String? = nil
    ) {
        self.id = id
        self.serviceDetail = serviceDetail
        self.isNetMetered = isNetMetered
        self.netEnergyQuantity = netEnergyQuantity
        self.netEnergyUnit = netEnergyUnit
        self.generationQuantity = generationQuantity
        self.generationUnit = generationUnit
        self.priorEnergyCreditBalance = priorEnergyCreditBalance
        self.energyCreditReceived = energyCreditReceived
        self.energyCreditApplied = energyCreditApplied
        self.newEnergyCreditBalance = newEnergyCreditBalance
        self.energyCreditUnit = energyCreditUnit
        self.priorMonetaryCreditBalance = priorMonetaryCreditBalance
        self.monetaryCreditReceived = monetaryCreditReceived
        self.monetaryCreditApplied = monetaryCreditApplied
        self.newMonetaryCreditBalance = newMonetaryCreditBalance
        self.settlementMonth = settlementMonth
        self.incentivePaymentAmount = incentivePaymentAmount
        self.programLabel = programLabel
    }
}


@Model
final class SourceDocument {
    @Attribute(.unique) var id: UUID
    var relativePath: String
    var originalFilename: String?
    var documentType: SourceDocumentType
    var importedAt: Date

    init(
        id: UUID = UUID(),
        relativePath: String,
        originalFilename: String? = nil,
        documentType: SourceDocumentType,
        importedAt: Date = Date()
    ) {
        self.id = id
        self.relativePath = relativePath
        self.originalFilename = originalFilename
        self.documentType = documentType
        self.importedAt = importedAt
    }
}
