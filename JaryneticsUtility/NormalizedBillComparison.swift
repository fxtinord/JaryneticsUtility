import Foundation

enum NormalizedBillComparisonReadiness: Sendable, Equatable {
    case comparable
    case partiallyComparable
    case notComparable
}

enum NormalizedBillComparisonSide: Sendable, Equatable {
    case earlier
    case later
}

enum NormalizedBillComparisonInput: Sendable, Equatable {
    case first
    case second
}

enum NormalizedBillChronologyIssue: Sendable, Equatable {
    case missingStatementDate(input: NormalizedBillComparisonInput)
    case equalStatementDates
}

enum NormalizedBillComparisonChronology: Sendable, Equatable {
    case ordered
    case unresolved(NormalizedBillChronologyIssue)
}

enum NormalizedBillComparisonReason: Sendable, Equatable {
    case missingStatementDate(input: NormalizedBillComparisonInput)
    case equalStatementDates
    case noCommonServices
    case unmatchedService(side: NormalizedBillComparisonSide, serviceType: UtilityServiceType)
    case ambiguousDuplicateServiceType(UtilityServiceType)
    case missingServiceValue(
        side: NormalizedBillComparisonSide,
        serviceType: UtilityServiceType,
        field: BillServiceFieldName
    )
    case incompatibleUsageUnits(
        serviceType: UtilityServiceType,
        earlierUnit: String,
        laterUnit: String
    )
}

struct NormalizedBillComparisonValuePair<Value> {
    let earlier: Value?
    let later: Value?
}

extension NormalizedBillComparisonValuePair: Sendable where Value: Sendable {}
extension NormalizedBillComparisonValuePair: Equatable where Value: Equatable {}

struct NormalizedBillLevelComparison: Sendable, Equatable {
    let issuer: NormalizedBillComparisonValuePair<BillStatementFieldProposal>
    let statementDate: NormalizedBillComparisonValuePair<BillStatementFieldProposal>
    let amountDue: NormalizedBillComparisonValuePair<BillStatementFieldProposal>
}

enum NormalizedUsageUnitCompatibility: Sendable, Equatable {
    case compatible(unit: String)
    case incompatible(earlierUnit: String, laterUnit: String)
    case insufficientEvidence
}

struct NormalizedBillServiceComparison: Sendable, Equatable, Identifiable {
    var id: UtilityServiceType { serviceType }

    let serviceType: UtilityServiceType
    let earlier: NormalizedBillServiceRecord
    let later: NormalizedBillServiceRecord
    let billingPeriodStart: NormalizedBillComparisonValuePair<BillServiceFieldProposal>
    let billingPeriodEnd: NormalizedBillComparisonValuePair<BillServiceFieldProposal>
    let billingDays: NormalizedBillComparisonValuePair<BillServiceFieldProposal>
    let usageQuantity: NormalizedBillComparisonValuePair<BillServiceFieldProposal>
    let usageUnit: NormalizedBillComparisonValuePair<BillServiceFieldProposal>
    let currentPeriodCharges: NormalizedBillComparisonValuePair<BillServiceFieldProposal>
    let usageUnitCompatibility: NormalizedUsageUnitCompatibility
}

struct NormalizedBillUnmatchedService: Sendable, Equatable {
    let side: NormalizedBillComparisonSide
    let service: NormalizedBillServiceRecord
}

struct NormalizedBillComparison: Sendable, Equatable {
    let inputRecords: [NormalizedBillRecord]
    let chronology: NormalizedBillComparisonChronology
    let earlierBill: NormalizedBillRecord?
    let laterBill: NormalizedBillRecord?
    let billLevel: NormalizedBillLevelComparison?
    let servicePairs: [NormalizedBillServiceComparison]
    let unmatchedServices: [NormalizedBillUnmatchedService]
    let readiness: NormalizedBillComparisonReadiness
    let reasons: [NormalizedBillComparisonReason]
}

/// Deterministically orders and structurally pairs exactly two normalized records.
/// It does not extract, infer, persist, or calculate customer-facing changes.
struct NormalizedBillComparisonAssembler {
    func assemble(
        _ first: NormalizedBillRecord,
        _ second: NormalizedBillRecord
    ) -> NormalizedBillComparison {
        let inputs = [first, second]
        guard let firstDate = statementDate(in: first) else {
            return unresolved(
                inputs: inputs,
                issue: .missingStatementDate(input: .first),
                reason: .missingStatementDate(input: .first)
            )
        }
        guard let secondDate = statementDate(in: second) else {
            return unresolved(
                inputs: inputs,
                issue: .missingStatementDate(input: .second),
                reason: .missingStatementDate(input: .second)
            )
        }
        guard firstDate != secondDate else {
            return unresolved(
                inputs: inputs,
                issue: .equalStatementDates,
                reason: .equalStatementDates
            )
        }

        let earlier = firstDate < secondDate ? first : second
        let later = firstDate < secondDate ? second : first
        return ordered(inputs: inputs, earlier: earlier, later: later)
    }

    private func ordered(
        inputs: [NormalizedBillRecord],
        earlier: NormalizedBillRecord,
        later: NormalizedBillRecord
    ) -> NormalizedBillComparison {
        let earlierByType = Dictionary(grouping: earlier.services, by: \.serviceType)
        let laterByType = Dictionary(grouping: later.services, by: \.serviceType)
        var pairs: [NormalizedBillServiceComparison] = []
        var unmatched: [NormalizedBillUnmatchedService] = []
        var reasons: [NormalizedBillComparisonReason] = []

        for serviceType in UtilityServiceType.allCases {
            let earlierServices = earlierByType[serviceType] ?? []
            let laterServices = laterByType[serviceType] ?? []
            if earlierServices.count > 1 || laterServices.count > 1 {
                reasons.append(.ambiguousDuplicateServiceType(serviceType))
                unmatched += earlierServices.map {
                    NormalizedBillUnmatchedService(side: .earlier, service: $0)
                }
                unmatched += laterServices.map {
                    NormalizedBillUnmatchedService(side: .later, service: $0)
                }
                continue
            }
            if let earlierService = earlierServices.first,
               let laterService = laterServices.first {
                let pair = servicePair(earlier: earlierService, later: laterService)
                pairs.append(pair)
                reasons += missingValueReasons(for: pair)
                if case .incompatible(let earlierUnit, let laterUnit) = pair.usageUnitCompatibility {
                    reasons.append(.incompatibleUsageUnits(
                        serviceType: serviceType,
                        earlierUnit: earlierUnit,
                        laterUnit: laterUnit
                    ))
                }
            } else if let earlierService = earlierServices.first {
                unmatched.append(.init(side: .earlier, service: earlierService))
                reasons.append(.unmatchedService(side: .earlier, serviceType: serviceType))
            } else if let laterService = laterServices.first {
                unmatched.append(.init(side: .later, service: laterService))
                reasons.append(.unmatchedService(side: .later, serviceType: serviceType))
            }
        }
        if pairs.isEmpty {
            reasons.append(.noCommonServices)
        }

        return NormalizedBillComparison(
            inputRecords: inputs,
            chronology: .ordered,
            earlierBill: earlier,
            laterBill: later,
            billLevel: billLevel(earlier: earlier, later: later),
            servicePairs: pairs,
            unmatchedServices: unmatched,
            readiness: readiness(hasPairs: !pairs.isEmpty, reasons: reasons),
            reasons: reasons
        )
    }

    private func unresolved(
        inputs: [NormalizedBillRecord],
        issue: NormalizedBillChronologyIssue,
        reason: NormalizedBillComparisonReason
    ) -> NormalizedBillComparison {
        NormalizedBillComparison(
            inputRecords: inputs,
            chronology: .unresolved(issue),
            earlierBill: nil,
            laterBill: nil,
            billLevel: nil,
            servicePairs: [],
            unmatchedServices: [],
            readiness: .notComparable,
            reasons: [reason]
        )
    }

    private func billLevel(
        earlier: NormalizedBillRecord,
        later: NormalizedBillRecord
    ) -> NormalizedBillLevelComparison {
        NormalizedBillLevelComparison(
            issuer: .init(earlier: earlier.billIssuer, later: later.billIssuer),
            statementDate: .init(earlier: earlier.statementDate, later: later.statementDate),
            amountDue: .init(earlier: earlier.totalAmountDue, later: later.totalAmountDue)
        )
    }

    private func servicePair(
        earlier: NormalizedBillServiceRecord,
        later: NormalizedBillServiceRecord
    ) -> NormalizedBillServiceComparison {
        NormalizedBillServiceComparison(
            serviceType: earlier.serviceType,
            earlier: earlier,
            later: later,
            billingPeriodStart: .init(
                earlier: earlier.billingPeriodStart,
                later: later.billingPeriodStart
            ),
            billingPeriodEnd: .init(
                earlier: earlier.billingPeriodEnd,
                later: later.billingPeriodEnd
            ),
            billingDays: .init(earlier: earlier.billingDays, later: later.billingDays),
            usageQuantity: .init(earlier: earlier.usageQuantity, later: later.usageQuantity),
            usageUnit: .init(earlier: earlier.usageUnit, later: later.usageUnit),
            currentPeriodCharges: .init(
                earlier: earlier.currentPeriodCharges,
                later: later.currentPeriodCharges
            ),
            usageUnitCompatibility: usageCompatibility(earlier: earlier, later: later)
        )
    }

    private func usageCompatibility(
        earlier: NormalizedBillServiceRecord,
        later: NormalizedBillServiceRecord
    ) -> NormalizedUsageUnitCompatibility {
        guard decimalValue(earlier.usageQuantity) != nil,
              decimalValue(later.usageQuantity) != nil,
              let earlierUnit = textValue(earlier.usageUnit),
              let laterUnit = textValue(later.usageUnit) else {
            return .insufficientEvidence
        }
        if normalizedUnit(earlierUnit) == normalizedUnit(laterUnit) {
            return .compatible(unit: earlierUnit)
        }
        return .incompatible(earlierUnit: earlierUnit, laterUnit: laterUnit)
    }

    private func missingValueReasons(
        for pair: NormalizedBillServiceComparison
    ) -> [NormalizedBillComparisonReason] {
        let fields: [(BillServiceFieldName, BillServiceFieldProposal?, BillServiceFieldProposal?)] = [
            (.billingPeriodStart, pair.billingPeriodStart.earlier, pair.billingPeriodStart.later),
            (.billingPeriodEnd, pair.billingPeriodEnd.earlier, pair.billingPeriodEnd.later),
            (.billingDays, pair.billingDays.earlier, pair.billingDays.later),
            (.usageQuantity, pair.usageQuantity.earlier, pair.usageQuantity.later),
            (.usageUnit, pair.usageUnit.earlier, pair.usageUnit.later),
            (.currentPeriodCharges, pair.currentPeriodCharges.earlier,
             pair.currentPeriodCharges.later),
        ]
        return fields.flatMap { field, earlier, later -> [NormalizedBillComparisonReason] in
            if earlier == nil, later != nil {
                return [.missingServiceValue(
                    side: .earlier,
                    serviceType: pair.serviceType,
                    field: field
                )]
            }
            if earlier != nil, later == nil {
                return [.missingServiceValue(
                    side: .later,
                    serviceType: pair.serviceType,
                    field: field
                )]
            }
            return []
        }
    }

    private func readiness(
        hasPairs: Bool,
        reasons: [NormalizedBillComparisonReason]
    ) -> NormalizedBillComparisonReadiness {
        guard hasPairs else { return .notComparable }
        return reasons.isEmpty ? .comparable : .partiallyComparable
    }

    private func statementDate(in record: NormalizedBillRecord) -> Date? {
        guard case .date(let date) = record.statementDate?.value else { return nil }
        return date
    }

    private func decimalValue(_ proposal: BillServiceFieldProposal?) -> Decimal? {
        guard case .decimal(let value) = proposal?.value else { return nil }
        return value
    }

    private func textValue(_ proposal: BillServiceFieldProposal?) -> String? {
        guard case .text(let value) = proposal?.value else { return nil }
        return value
    }

    private func normalizedUnit(_ unit: String) -> String {
        unit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
