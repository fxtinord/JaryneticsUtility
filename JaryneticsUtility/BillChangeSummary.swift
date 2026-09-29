import Foundation

#if DEBUG
struct BillChangeSummaryPeriod: Sendable, Equatable {
    let start: BillServiceFieldProposal
    let end: BillServiceFieldProposal
}

struct BillChangeSummaryMetric: Sendable, Equatable {
    let sourceValues: NormalizedBillComparisonValuePair<BillServiceFieldProposal>
    let calculation: NormalizedNumericChange
    let unit: NormalizedBillChangeUnit
}

struct BillChangeServiceSummary: Sendable, Equatable, Identifiable {
    var id: UtilityServiceType { serviceType }

    let serviceType: UtilityServiceType
    let earlierPeriod: BillChangeSummaryPeriod?
    let laterPeriod: BillChangeSummaryPeriod?
    let earlierBillingDays: BillServiceFieldProposal?
    let laterBillingDays: BillServiceFieldProposal?
    let usage: BillChangeSummaryMetric?
    let currentPeriodCharges: BillChangeSummaryMetric?

    var hasCalculatedMetric: Bool {
        usage != nil || currentPeriodCharges != nil
    }
}

struct BillChangeSummary: Sendable, Equatable {
    let sourceChange: NormalizedBillChange
    let earlierIssuer: BillStatementFieldProposal?
    let laterIssuer: BillStatementFieldProposal?
    let utilityName: String?
    let services: [BillChangeServiceSummary]

    var hasCalculatedMetric: Bool {
        services.contains(where: \.hasCalculatedMetric)
    }
}

/// Projects accepted deterministic changes into customer-readable structure.
/// It preserves source proposals and performs no extraction or arithmetic.
struct BillChangeSummaryAssembler {
    func assemble(from change: NormalizedBillChange) -> BillChangeSummary {
        let billLevel = change.sourceComparison.billLevel
        return BillChangeSummary(
            sourceChange: change,
            earlierIssuer: billLevel?.issuer.earlier,
            laterIssuer: billLevel?.issuer.later,
            utilityName: sharedIssuerName(billLevel?.issuer),
            services: change.serviceChanges.map(serviceSummary)
        )
    }

    private func sharedIssuerName(
        _ pair: NormalizedBillComparisonValuePair<BillStatementFieldProposal>?
    ) -> String? {
        guard let earlier = pair?.earlier,
              let later = pair?.later,
              case .text(let earlierName) = earlier.value,
              case .text(let laterName) = later.value,
              earlierName.localizedCaseInsensitiveCompare(laterName) == .orderedSame else {
            return nil
        }
        return laterName
    }

    private func serviceSummary(
        _ change: NormalizedBillServiceChange
    ) -> BillChangeServiceSummary {
        let pair = change.sourcePair
        return BillChangeServiceSummary(
            serviceType: change.serviceType,
            earlierPeriod: period(start: pair.billingPeriodStart.earlier, end: pair.billingPeriodEnd.earlier),
            laterPeriod: period(start: pair.billingPeriodStart.later, end: pair.billingPeriodEnd.later),
            earlierBillingDays: integerProposal(pair.billingDays.earlier),
            laterBillingDays: integerProposal(pair.billingDays.later),
            usage: metric(change.usage),
            currentPeriodCharges: metric(change.currentPeriodCharges)
        )
    }

    private func period(
        start: BillServiceFieldProposal?,
        end: BillServiceFieldProposal?
    ) -> BillChangeSummaryPeriod? {
        guard let start, let end,
              case .date = start.value,
              case .date = end.value else { return nil }
        return BillChangeSummaryPeriod(start: start, end: end)
    }

    private func integerProposal(
        _ proposal: BillServiceFieldProposal?
    ) -> BillServiceFieldProposal? {
        guard let proposal, case .integer = proposal.value else { return nil }
        return proposal
    }

    private func metric(_ metric: NormalizedBillMetricChange) -> BillChangeSummaryMetric? {
        guard let calculation = metric.calculation, let unit = metric.unit else { return nil }
        return BillChangeSummaryMetric(
            sourceValues: metric.sourceValues,
            calculation: calculation,
            unit: unit
        )
    }
}

enum BillChangeSummaryFormatting {
    static func serviceName(_ serviceType: UtilityServiceType) -> String {
        switch serviceType {
        case .electricity: String(localized: "Electricity")
        case .naturalGas: String(localized: "Natural Gas")
        case .waterWastewater: String(localized: "Water / Wastewater")
        }
    }

    static func period(
        _ period: BillChangeSummaryPeriod,
        locale: Locale = .current
    ) -> String? {
        guard case .date(let start) = period.start.value,
              case .date(let end) = period.end.value else { return nil }
        return FirstBillSummaryFormatting.billingPeriod(start: start, end: end, locale: locale)
    }

    static func billingDays(_ proposal: BillServiceFieldProposal) -> String? {
        guard case .integer(let days) = proposal.value else { return nil }
        return String(localized: "\(days) days")
    }

    static func sourceValue(
        _ value: Decimal,
        unit: NormalizedBillChangeUnit,
        locale: Locale = .current
    ) -> String {
        switch unit {
        case .usage(let usageUnit):
            FirstBillSummaryFormatting.usage(quantity: value, unit: usageUnit, locale: locale)
        case .usd:
            FirstBillSummaryFormatting.currency(value, locale: locale)
        }
    }

    static func signedChange(
        _ value: Decimal,
        unit: NormalizedBillChangeUnit,
        locale: Locale = .current
    ) -> String {
        switch unit {
        case .usage(let usageUnit):
            "\(signedNumber(value, locale: locale)) \(usageUnit)"
        case .usd:
            signedCurrency(value, locale: locale)
        }
    }

    static func percentage(
        _ percentage: NormalizedPercentageChange,
        locale: Locale = .current
    ) -> String? {
        guard case .calculated(let value) = percentage else { return nil }
        return "\(signedNumber(value, maximumFractionDigits: 1, locale: locale))%"
    }

    static func direction(
        _ direction: NormalizedBillChangeDirection,
        metricName: String
    ) -> String {
        switch direction {
        case .increased: String(localized: "\(metricName) increased")
        case .decreased: String(localized: "\(metricName) decreased")
        case .unchanged: String(localized: "\(metricName) was unchanged")
        }
    }

    private static func signedNumber(
        _ value: Decimal,
        maximumFractionDigits: Int = 3,
        locale: Locale
    ) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = maximumFractionDigits
        let formatted = formatter.string(from: value as NSDecimalNumber) ?? value.description
        return value > 0 ? "+\(formatted)" : formatted
    }

    private static func signedCurrency(_ value: Decimal, locale: Locale) -> String {
        let formatted = FirstBillSummaryFormatting.currency(value, locale: locale)
        return value > 0 ? "+\(formatted)" : formatted
    }
}
#endif
