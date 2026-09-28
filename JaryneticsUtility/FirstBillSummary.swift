import Foundation

#if DEBUG
struct FirstBillSummaryValue<Value: Sendable & Equatable>: Sendable, Equatable {
    let value: Value
    let provenance: BillSourceProvenance
    let origin: BillProposalOrigin
}

struct FirstBillSummaryPeriod: Sendable, Equatable {
    let start: FirstBillSummaryValue<Date>
    let end: FirstBillSummaryValue<Date>
}

struct FirstBillSummaryUsage: Sendable, Equatable {
    let quantity: FirstBillSummaryValue<Decimal>
    let unit: FirstBillSummaryValue<String>
}

struct FirstBillServiceSummary: Sendable, Equatable, Identifiable {
    var id: UtilityServiceType { serviceType }

    let serviceType: UtilityServiceType
    let billingPeriod: FirstBillSummaryPeriod?
    let billingDays: FirstBillSummaryValue<Int>?
    let usage: FirstBillSummaryUsage?
    let currentPeriodCharges: FirstBillSummaryValue<Decimal>?
}

struct FirstBillSummary: Sendable, Equatable {
    let billIssuer: FirstBillSummaryValue<String>?
    let statementDate: FirstBillSummaryValue<Date>?
    let amountDue: FirstBillSummaryValue<Decimal>?
    let services: [FirstBillServiceSummary]

    var hasContent: Bool {
        billIssuer != nil || statementDate != nil || amountDue != nil || !services.isEmpty
    }
}

/// Projects only accepted normalized proposals into a compact presentation model.
/// It performs no recognition, extraction, inference, persistence, or verification.
struct FirstBillSummaryAssembler {
    func assemble(from record: NormalizedBillRecord) -> FirstBillSummary {
        FirstBillSummary(
            billIssuer: statementValue(record.billIssuer, value: textValue),
            statementDate: statementValue(record.statementDate, value: dateValue),
            amountDue: statementValue(record.totalAmountDue, value: decimalValue),
            services: record.services.map(serviceSummary)
        )
    }

    private func serviceSummary(_ record: NormalizedBillServiceRecord) -> FirstBillServiceSummary {
        let start = serviceValue(record.billingPeriodStart, value: dateValue)
        let end = serviceValue(record.billingPeriodEnd, value: dateValue)
        let quantity = serviceValue(record.usageQuantity, value: decimalValue)
        let unit = serviceValue(record.usageUnit, value: textValue)
        return FirstBillServiceSummary(
            serviceType: record.serviceType,
            billingPeriod: start.flatMap { start in
                end.map { FirstBillSummaryPeriod(start: start, end: $0) }
            },
            billingDays: serviceValue(record.billingDays, value: integerValue),
            usage: quantity.flatMap { quantity in
                unit.map { FirstBillSummaryUsage(quantity: quantity, unit: $0) }
            },
            currentPeriodCharges: serviceValue(
                record.currentPeriodCharges,
                value: decimalValue
            )
        )
    }

    private func statementValue<Value: Sendable & Equatable>(
        _ proposal: BillStatementFieldProposal?,
        value: (BillProposedValue) -> Value?
    ) -> FirstBillSummaryValue<Value>? {
        guard let proposal, let value = value(proposal.value) else { return nil }
        return FirstBillSummaryValue(
            value: value,
            provenance: proposal.provenance,
            origin: proposal.origin
        )
    }

    private func serviceValue<Value: Sendable & Equatable>(
        _ proposal: BillServiceFieldProposal?,
        value: (BillProposedValue) -> Value?
    ) -> FirstBillSummaryValue<Value>? {
        guard let proposal, let value = value(proposal.value) else { return nil }
        return FirstBillSummaryValue(
            value: value,
            provenance: proposal.provenance,
            origin: proposal.origin
        )
    }

    private func textValue(_ value: BillProposedValue) -> String? {
        guard case .text(let text) = value else { return nil }
        return text
    }

    private func dateValue(_ value: BillProposedValue) -> Date? {
        guard case .date(let date) = value else { return nil }
        return date
    }

    private func decimalValue(_ value: BillProposedValue) -> Decimal? {
        guard case .decimal(let decimal) = value else { return nil }
        return decimal
    }

    private func integerValue(_ value: BillProposedValue) -> Int? {
        guard case .integer(let integer) = value else { return nil }
        return integer
    }
}

enum FirstBillSummaryFormatting {
    static func currency(
        _ value: Decimal,
        locale: Locale = .current
    ) -> String {
        value.formatted(.currency(code: "USD").locale(locale))
    }

    static func usage(
        quantity: Decimal,
        unit: String,
        locale: Locale = .current
    ) -> String {
        "\(quantity.formatted(.number.locale(locale))) \(unit)"
    }

    static func billingPeriod(
        start: Date,
        end: Date,
        locale: Locale = .current
    ) -> String {
        "\(BillDateOnlyPresentation.string(from: start, locale: locale)) – \(BillDateOnlyPresentation.string(from: end, locale: locale))"
    }
}
#endif
