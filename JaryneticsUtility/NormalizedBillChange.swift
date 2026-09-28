import Foundation

enum NormalizedBillChangeDirection: Sendable, Equatable {
    case increased
    case decreased
    case unchanged
}

enum NormalizedBillChangeAbstentionReason: Sendable, Equatable {
    case comparisonNotOrdered
    case comparisonNotComparable
    case noComparableServicePair
    case noCalculableMetric
    case missingEarlierValue
    case missingLaterValue
    case incompatibleUsageUnit
    case insufficientUsageUnitEvidence
    case unsupportedNumericValue
}

enum NormalizedPercentageChange: Sendable, Equatable {
    case calculated(Decimal)
    case unavailableZeroBaseline
}

enum NormalizedBillChangeUnit: Sendable, Equatable {
    case usage(String)
    case usd
}

struct NormalizedNumericChange: Sendable, Equatable {
    let earlierValue: Decimal
    let laterValue: Decimal
    let delta: Decimal
    let percentageChange: NormalizedPercentageChange
    let direction: NormalizedBillChangeDirection
    let origin: BillProposalOrigin
}

struct NormalizedBillMetricChange: Sendable, Equatable {
    let sourceValues: NormalizedBillComparisonValuePair<BillServiceFieldProposal>
    let unit: NormalizedBillChangeUnit?
    let calculation: NormalizedNumericChange?
    let abstentionReason: NormalizedBillChangeAbstentionReason?
}

struct NormalizedBillServiceChange: Sendable, Equatable, Identifiable {
    var id: UtilityServiceType { serviceType }

    let serviceType: UtilityServiceType
    let sourcePair: NormalizedBillServiceComparison
    let usage: NormalizedBillMetricChange
    let currentPeriodCharges: NormalizedBillMetricChange
}

enum NormalizedBillChangeReadiness: Sendable, Equatable {
    case calculated
    case partiallyCalculated
    case unavailable
}

struct NormalizedBillChange: Sendable, Equatable {
    let sourceComparison: NormalizedBillComparison
    let serviceChanges: [NormalizedBillServiceChange]
    let readiness: NormalizedBillChangeReadiness
    let abstentionReason: NormalizedBillChangeAbstentionReason?
}

/// Calculates deterministic arithmetic only from service pairs accepted by the
/// normalized comparison layer. It does not extract, infer, persist, or explain.
struct NormalizedBillChangeAssembler {
    func assemble(from comparison: NormalizedBillComparison) -> NormalizedBillChange {
        guard comparison.chronology == .ordered else {
            return NormalizedBillChange(
                sourceComparison: comparison,
                serviceChanges: [],
                readiness: .unavailable,
                abstentionReason: .comparisonNotOrdered
            )
        }
        guard comparison.readiness != .notComparable else {
            return NormalizedBillChange(
                sourceComparison: comparison,
                serviceChanges: [],
                readiness: .unavailable,
                abstentionReason: .comparisonNotComparable
            )
        }
        guard !comparison.servicePairs.isEmpty else {
            return NormalizedBillChange(
                sourceComparison: comparison,
                serviceChanges: [],
                readiness: .unavailable,
                abstentionReason: .noComparableServicePair
            )
        }

        let serviceChanges = comparison.servicePairs.map(serviceChange)
        let metrics = serviceChanges.flatMap { [$0.usage, $0.currentPeriodCharges] }
        let calculatedCount = metrics.filter { $0.calculation != nil }.count
        let readiness: NormalizedBillChangeReadiness
        if calculatedCount == metrics.count {
            readiness = .calculated
        } else if calculatedCount > 0 {
            readiness = .partiallyCalculated
        } else {
            readiness = .unavailable
        }
        return NormalizedBillChange(
            sourceComparison: comparison,
            serviceChanges: serviceChanges,
            readiness: readiness,
            abstentionReason: readiness == .unavailable ? .noCalculableMetric : nil
        )
    }

    private func serviceChange(
        _ pair: NormalizedBillServiceComparison
    ) -> NormalizedBillServiceChange {
        NormalizedBillServiceChange(
            serviceType: pair.serviceType,
            sourcePair: pair,
            usage: usageChange(for: pair),
            currentPeriodCharges: numericChange(
                sourceValues: pair.currentPeriodCharges,
                unit: .usd
            )
        )
    }

    private func usageChange(
        for pair: NormalizedBillServiceComparison
    ) -> NormalizedBillMetricChange {
        let sourceValues = pair.usageQuantity
        if sourceValues.earlier == nil {
            return unavailable(
                sourceValues: sourceValues,
                reason: .missingEarlierValue
            )
        }
        if sourceValues.later == nil {
            return unavailable(
                sourceValues: sourceValues,
                reason: .missingLaterValue
            )
        }
        switch pair.usageUnitCompatibility {
        case .compatible(let unit):
            return numericChange(sourceValues: sourceValues, unit: .usage(unit))
        case .incompatible:
            return unavailable(
                sourceValues: sourceValues,
                reason: .incompatibleUsageUnit
            )
        case .insufficientEvidence:
            return unavailable(
                sourceValues: sourceValues,
                reason: .insufficientUsageUnitEvidence
            )
        }
    }

    private func numericChange(
        sourceValues: NormalizedBillComparisonValuePair<BillServiceFieldProposal>,
        unit: NormalizedBillChangeUnit
    ) -> NormalizedBillMetricChange {
        guard let earlierProposal = sourceValues.earlier else {
            return unavailable(
                sourceValues: sourceValues,
                unit: unit,
                reason: .missingEarlierValue
            )
        }
        guard let laterProposal = sourceValues.later else {
            return unavailable(
                sourceValues: sourceValues,
                unit: unit,
                reason: .missingLaterValue
            )
        }
        guard case .decimal(let earlier) = earlierProposal.value,
              case .decimal(let later) = laterProposal.value else {
            return unavailable(
                sourceValues: sourceValues,
                unit: unit,
                reason: .unsupportedNumericValue
            )
        }

        let delta = later - earlier
        let percentage: NormalizedPercentageChange
        if earlier == 0 {
            percentage = .unavailableZeroBaseline
        } else {
            let denominator = earlier < 0 ? -earlier : earlier
            percentage = .calculated((delta / denominator) * 100)
        }
        let direction: NormalizedBillChangeDirection = if delta > 0 {
            .increased
        } else if delta < 0 {
            .decreased
        } else {
            .unchanged
        }
        return NormalizedBillMetricChange(
            sourceValues: sourceValues,
            unit: unit,
            calculation: NormalizedNumericChange(
                earlierValue: earlier,
                laterValue: later,
                delta: delta,
                percentageChange: percentage,
                direction: direction,
                origin: .derived
            ),
            abstentionReason: nil
        )
    }

    private func unavailable(
        sourceValues: NormalizedBillComparisonValuePair<BillServiceFieldProposal>,
        unit: NormalizedBillChangeUnit? = nil,
        reason: NormalizedBillChangeAbstentionReason
    ) -> NormalizedBillMetricChange {
        NormalizedBillMetricChange(
            sourceValues: sourceValues,
            unit: unit,
            calculation: nil,
            abstentionReason: reason
        )
    }
}
