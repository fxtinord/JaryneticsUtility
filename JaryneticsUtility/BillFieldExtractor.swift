import CoreGraphics
import Foundation

enum BillStatementFieldName: String, CaseIterable, Sendable {
    case statementDate = "Statement date"
    case amountDue = "Total amount due"
    case dueDate = "Due date"
}

enum BillServiceFieldName: String, CaseIterable, Sendable {
    case billingPeriodStart = "Billing-period start"
    case billingPeriodEnd = "Billing-period end"
    case billingDays = "Billing days"
    case currentPeriodCharges = "Current-period charges"
    case usageQuantity = "Usage quantity"
    case usageUnit = "Usage unit"
}

enum BillProposedValue: Sendable, Equatable {
    case date(Date)
    case decimal(Decimal)
    case integer(Int)
    case text(String)
}

enum BillProposalOrigin: Sendable, Equatable {
    case extracted
    case derived
}

struct BillSourceProvenance: Sendable, Equatable {
    let pageIndex: Int
    let snippet: String
    let normalizedBoundingBox: CGRect?
}

struct BillStatementFieldProposal: Sendable, Equatable, Identifiable {
    var id: BillStatementFieldName { field }

    let field: BillStatementFieldName
    let value: BillProposedValue
    let provenance: BillSourceProvenance
    let origin: BillProposalOrigin
}

struct BillServiceFieldProposal: Sendable, Equatable, Identifiable {
    var id: BillServiceFieldName { field }

    let field: BillServiceFieldName
    let value: BillProposedValue
    let provenance: BillSourceProvenance
    let origin: BillProposalOrigin
}

struct BillServiceProposalGroup: Sendable, Equatable, Identifiable {
    var id: UtilityServiceType { serviceType }

    let serviceType: UtilityServiceType
    let serviceIdentityProvenance: BillSourceProvenance
    let proposals: [BillServiceFieldProposal]

    func proposal(for field: BillServiceFieldName) -> BillServiceFieldProposal? {
        proposals.first { $0.field == field }
    }
}

struct BillExtractionResult: Sendable, Equatable {
    let statementProposals: [BillStatementFieldProposal]
    let serviceGroups: [BillServiceProposalGroup]

    func statementProposal(
        for field: BillStatementFieldName
    ) -> BillStatementFieldProposal? {
        statementProposals.first { $0.field == field }
    }

    func serviceGroup(for serviceType: UtilityServiceType) -> BillServiceProposalGroup? {
        serviceGroups.first { $0.serviceType == serviceType }
    }
}

struct BillFieldExtractor {
    private struct Candidate<Value: Equatable> {
        let value: Value
        let provenance: BillSourceProvenance
    }

    private struct DatePair: Equatable {
        let start: Date
        let end: Date
    }

    private struct UsageValue: Equatable {
        let quantity: Decimal
        let unit: String
    }

    private struct SourceLine {
        let pageIndex: Int
        let line: RecognizedDocumentLine
    }

    private struct ServiceLines {
        let serviceType: UtilityServiceType
        let identityProvenance: BillSourceProvenance
        var lines: [SourceLine]
    }

    private enum ServiceTypeMatch {
        case none
        case identified(UtilityServiceType)
        case ambiguous
    }

    private enum LayoutAssociationTier {
        case sameRow
        case stacked
    }

    /// Conservative normalized-coordinate limits for joining OCR observations.
    /// Same-row values must sit to the right within 35% of page width and have
    /// at least 50% vertical overlap (or centers within 2.5%). Stacked values
    /// must be within 4% vertically and overlap at least 50% horizontally.
    private enum LayoutAssociationRule {
        static let rowCenterTolerance: CGFloat = 0.025
        static let maximumHorizontalGap: CGFloat = 0.35
        static let maximumStackedGap: CGFloat = 0.04
        static let minimumOverlapFraction: CGFloat = 0.5
        static let leadingTolerance: CGFloat = 0.02
    }

    private static let datePattern = #"(?:\d{1,2}/\d{1,2}/(?:\d{4}|\d{2})\b|(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\s+\d{1,2},\s+\d{4})"#
    private static let moneyPattern = #"\$?\s*([0-9]{1,3}(?:,[0-9]{3})*|[0-9]+)\.([0-9]{2})"#
    private static let usageValuePattern = #"\b[0-9]+(?:,[0-9]{3})*(?:\.\d+)?\s*(?:kwh|therms?|ccf|gallons?|gal|water\s+units?)\b"#
    private static let nonCurrentContextPattern = #"\b(?:previous|prior|historical|history|past[\s-]+due|average|daily|comparison|comparative|compare|last\s+(?:month|period|year)|year[\s-]+over[\s-]+year)\b"#

    func extract(from recognition: DocumentRecognitionResult) -> BillExtractionResult {
        let documentLines = sourceLines(in: recognition)
        let statementProposals = extractStatementProposals(from: documentLines)
        let scopedLines = scopedServiceLines(in: recognition)
        let serviceGroups = scopedLines.map {
            extractServiceGroup($0, documentLines: documentLines)
        }
        return BillExtractionResult(
            statementProposals: statementProposals,
            serviceGroups: serviceGroups
        )
    }

    private func extractStatementProposals(
        from lines: [SourceLine]
    ) -> [BillStatementFieldProposal] {
        let statementDate = uniqueDate(
            in: lines,
            labelPattern: #"\bstatement\s+date\b"#
        )
        let amountDue = uniqueMoney(
            in: lines,
            labelPattern: #"\b(?:total\s+)?amount\s+due\b"#,
            allowsSplitAssociation: true
        )
        let dueDate = uniqueDate(
            in: lines,
            labelPattern: #"\bdue\s+date\b|\bpayment\s+due\b"#
        )

        var proposals: [BillStatementFieldProposal] = []
        appendStatement(statementDate, field: .statementDate, to: &proposals) { .date($0) }
        appendStatement(amountDue, field: .amountDue, to: &proposals) { .decimal($0) }
        appendStatement(dueDate, field: .dueDate, to: &proposals) { .date($0) }
        return proposals
    }

    private func extractServiceGroup(
        _ serviceLines: ServiceLines,
        documentLines: [SourceLine]
    ) -> BillServiceProposalGroup {
        let periods = uniqueBillingPeriod(in: serviceLines.lines)
        let explicitDays = uniqueBillingDays(in: serviceLines.lines)
        let currentCharges = uniqueMoney(
            in: serviceLines.lines,
            labelPattern: #"\b(?:current(?:\s+period)?\s+charges|(?:current|total)\s+(?:electric(?:ity)?|natural\s+gas|gas|water(?:\s*/\s*wastewater)?|wastewater)\s+charges)\b"#,
            allowsSplitAssociation: true,
            splitValueLines: documentLines,
            explicitlyScopedService: serviceLines.serviceType
        )
        let usage = uniqueUsage(
            in: serviceLines.lines,
            documentLines: documentLines,
            serviceType: serviceLines.serviceType
        )

        var proposals: [BillServiceFieldProposal] = []
        if let periods {
            proposals.append(serviceProposal(
                .billingPeriodStart,
                .date(periods.value.start),
                periods.provenance
            ))
            proposals.append(serviceProposal(
                .billingPeriodEnd,
                .date(periods.value.end),
                periods.provenance
            ))
        }
        if let explicitDays {
            appendService(explicitDays, field: .billingDays, to: &proposals) { .integer($0) }
        } else if let periods,
                  let days = derivedDays(from: periods.value.start, to: periods.value.end) {
            proposals.append(serviceProposal(
                .billingDays,
                .integer(days),
                periods.provenance,
                origin: .derived
            ))
        }
        appendService(currentCharges, field: .currentPeriodCharges, to: &proposals) {
            .decimal($0)
        }
        if let usage {
            proposals.append(serviceProposal(
                .usageQuantity,
                .decimal(usage.value.quantity),
                usage.provenance
            ))
            proposals.append(serviceProposal(
                .usageUnit,
                .text(usage.value.unit),
                usage.provenance
            ))
        }

        return BillServiceProposalGroup(
            serviceType: serviceLines.serviceType,
            serviceIdentityProvenance: serviceLines.identityProvenance,
            proposals: proposals
        )
    }

    private func scopedServiceLines(
        in recognition: DocumentRecognitionResult
    ) -> [ServiceLines] {
        var groups: [UtilityServiceType: ServiceLines] = [:]
        var order: [UtilityServiceType] = []

        for page in recognition.pages {
            let eligibleLines = page.lines.compactMap { line in
                isEligibleCurrentLine(line.text)
                    ? SourceLine(pageIndex: page.pageIndex, line: line)
                    : nil
            }
            let identifiedTypes = eligibleLines.compactMap { sourceLine -> UtilityServiceType? in
                let line = sourceLine.line
                guard case .identified(let type) = serviceTypeMatch(in: line.text) else {
                    return nil
                }
                return type
            }
            let distinctTypes = identifiedTypes.reduce(into: [UtilityServiceType]()) { result, type in
                if !result.contains(type) {
                    result.append(type)
                }
            }
            var currentType = distinctTypes.count == 1 ? distinctTypes.first : nil

            for sourceLine in eligibleLines {
                let line = sourceLine.line
                switch serviceTypeMatch(in: line.text) {
                case .identified(let type):
                    currentType = type
                    if groups[type] == nil {
                        order.append(type)
                        groups[type] = ServiceLines(
                            serviceType: type,
                            identityProvenance: provenance(pageIndex: page.pageIndex, line: line),
                            lines: []
                        )
                    }
                case .ambiguous:
                    currentType = nil
                    continue
                case .none:
                    break
                }

                guard let currentType else { continue }
                if groups[currentType] == nil,
                   let identityLine = eligibleLines.first(where: {
                       if case .identified(currentType) = serviceTypeMatch(in: $0.line.text) {
                           return true
                       }
                       return false
                   }) {
                    order.append(currentType)
                    groups[currentType] = ServiceLines(
                        serviceType: currentType,
                        identityProvenance: provenance(
                            pageIndex: page.pageIndex,
                            line: identityLine.line
                        ),
                        lines: []
                    )
                }
                groups[currentType]?.lines.append(sourceLine)
            }
        }

        return order.compactMap { groups[$0] }
    }

    private func serviceTypeMatch(in text: String) -> ServiceTypeMatch {
        var matchesByType: [UtilityServiceType] = []
        if matches(#"\belectric(?:ity)?\b"#, in: text) {
            matchesByType.append(.electricity)
        }
        if matches(#"\bnatural\s+gas\b|\bgas\b"#, in: text) {
            matchesByType.append(.naturalGas)
        }
        if matches(#"\bwater\b|\bwastewater\b"#, in: text) {
            matchesByType.append(.waterWastewater)
        }

        switch matchesByType.count {
        case 0:
            return .none
        case 1:
            return .identified(matchesByType[0])
        default:
            return .ambiguous
        }
    }

    private func uniqueDate(
        in lines: [SourceLine],
        labelPattern: String
    ) -> Candidate<Date>? {
        uniqueCandidate(in: lines) { line in
            let dateTexts = allMatches(Self.datePattern, in: line.text)
            guard isEligibleCurrentLine(line.text),
                  matches(labelPattern, in: line.text),
                  dateTexts.count == 1,
                  let dateText = dateTexts.first,
                  let date = parseDate(dateText) else {
                return nil
            }
            return date
        }
    }

    private func uniqueMoney(
        in lines: [SourceLine],
        labelPattern: String,
        allowsSplitAssociation: Bool = false,
        splitValueLines: [SourceLine]? = nil,
        explicitlyScopedService: UtilityServiceType? = nil
    ) -> Candidate<Decimal>? {
        let directCandidates: [Candidate<Decimal>] = candidates(in: lines) { line in
            let amountTexts = allMatches(Self.moneyPattern, in: line.text)
            guard isEligibleCurrentLine(line.text),
                  matches(labelPattern, in: line.text),
                  amountTexts.count == 1,
                  let amountText = amountTexts.first else {
                return nil
            }
            let normalized = amountText
                .replacingOccurrences(of: "$", with: "")
                .replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: " ", with: "")
            return Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX"))
        }
        let splitCandidates: [Candidate<Decimal>] = allowsSplitAssociation
            ? splitCandidates(
                in: lines,
                valueLines: splitValueLines ?? lines,
                labelMatches: { matches(labelPattern, in: $0) },
                valueParser: standaloneMoneyValue,
                explicitlyScopedService: explicitlyScopedService
            )
            : []
        return unique(directCandidates + splitCandidates)
    }

    private func uniqueBillingDays(in lines: [SourceLine]) -> Candidate<Int>? {
        uniqueCandidate(in: lines) { line in
            guard isEligibleCurrentLine(line.text),
                  let value = billingDaysValue(in: line.text),
                  (1...366).contains(value) else {
                return nil
            }
            return value
        }
    }

    private func uniqueBillingPeriod(in lines: [SourceLine]) -> Candidate<DatePair>? {
        uniqueCandidate(in: lines) { line in
            guard isEligibleCurrentLine(line.text),
                  matches(#"\bbilling\s+period\b|\bservice\s+period\b"#, in: line.text)
                    || billingDaysValue(in: line.text) != nil else {
                return nil
            }
            let dateTexts = allMatches(Self.datePattern, in: line.text)
            guard dateTexts.count == 2,
                  let start = parseDate(dateTexts[0]),
                  let end = parseDate(dateTexts[1]),
                  start <= end else {
                return nil
            }
            return DatePair(start: start, end: end)
        }
    }

    private func billingDaysValue(in text: String) -> Int? {
        let patterns = [
            #"\bbilling\s+days\s*[:\-]?\s*(\d{1,3})\b"#,
            #"\b(\d{1,3})\s+billing\s+days\b"#,
            #"\bdays\s+in\s+billing\s+period\s*[:\-]?\s*(\d{1,3})\b"#,
        ]
        for pattern in patterns {
            if let valueText = firstCapture(pattern, in: text),
               let value = Int(valueText) {
                return value
            }
        }
        return nil
    }

    private func uniqueUsage(
        in lines: [SourceLine],
        documentLines: [SourceLine],
        serviceType: UtilityServiceType
    ) -> Candidate<UsageValue>? {
        let directCandidates: [Candidate<UsageValue>] = candidates(in: lines) { line in
            guard isEligibleCurrentLine(line.text),
                  isSupportedUsageLabel(line.text),
                  let usage = usageValue(in: line.text) else {
                return nil
            }
            return usage
        }
        let splitCandidates = splitCandidates(
            in: lines,
            valueLines: documentLines,
            labelMatches: isSupportedUsageLabel,
            valueParser: usageValue,
            explicitlyScopedService: serviceType
        )
        return unique(directCandidates + splitCandidates)
    }

    private func moneyValue(in text: String) -> Decimal? {
        let amountTexts = allMatches(Self.moneyPattern, in: text)
        guard amountTexts.count == 1, let amountText = amountTexts.first else {
            return nil
        }
        let normalized = amountText
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")
        return Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX"))
    }

    private func standaloneMoneyValue(in text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let amountText = firstMatch(
            #"^-?\$?\s*(?:[0-9]{1,3}(?:,[0-9]{3})*|[0-9]+)\.[0-9]{2}$"#,
            in: trimmed
        ) else {
            return nil
        }
        let normalized = amountText
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")
        return Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX"))
    }

    private func isSupportedUsageLabel(_ text: String) -> Bool {
        matches(
            #"^\s*(?:(?:electricity|electric|natural\s+gas|gas|water|wastewater)\s+)?(?:total\s+)?usage(?:\s+this\s+period)?\b"#,
            in: text
        )
    }

    private func usageValue(in text: String) -> UsageValue? {
        let values = allMatches(Self.usageValuePattern, in: text)
        guard values.count == 1,
              let valueText = values.first,
              let quantityText = firstCapture(
                #"\b([0-9]+(?:,[0-9]{3})*(?:\.\d+)?)"#,
                in: valueText
              ),
              let unitText = firstCapture(
                #"\b[0-9]+(?:,[0-9]{3})*(?:\.\d+)?\s*(kwh|therms?|ccf|gallons?|gal|water\s+units?)\b"#,
                in: valueText,
                capture: 1
              ),
              let quantity = Decimal(
                string: quantityText.replacingOccurrences(of: ",", with: ""),
                locale: Locale(identifier: "en_US_POSIX")
              ) else {
            return nil
        }
        return UsageValue(quantity: quantity, unit: normalizedUnit(unitText))
    }

    private func sourceLines(in recognition: DocumentRecognitionResult) -> [SourceLine] {
        recognition.pages.flatMap { page in
            page.lines.map { SourceLine(pageIndex: page.pageIndex, line: $0) }
        }
    }

    private func uniqueCandidate<Value: Equatable>(
        in lines: [SourceLine],
        parser: (RecognizedDocumentLine) -> Value?
    ) -> Candidate<Value>? {
        unique(candidates(in: lines, parser: parser))
    }

    private func candidates<Value: Equatable>(
        in lines: [SourceLine],
        parser: (RecognizedDocumentLine) -> Value?
    ) -> [Candidate<Value>] {
        lines.compactMap { sourceLine -> Candidate<Value>? in
            guard let value = parser(sourceLine.line) else { return nil }
            return Candidate(
                value: value,
                provenance: provenance(
                    pageIndex: sourceLine.pageIndex,
                    line: sourceLine.line
                )
            )
        }
    }

    private func splitCandidates<Value: Equatable>(
        in lines: [SourceLine],
        valueLines: [SourceLine],
        labelMatches: (String) -> Bool,
        valueParser: (String) -> Value?,
        explicitlyScopedService: UtilityServiceType? = nil
    ) -> [Candidate<Value>] {
        lines.compactMap { labelSource in
            guard isEligibleCurrentLine(labelSource.line.text),
                  labelMatches(labelSource.line.text),
                  valueParser(labelSource.line.text) == nil else {
                return nil
            }
            let hasExplicitMatchingScope: Bool
            if let explicitlyScopedService,
               case .identified(let labelService) = serviceTypeMatch(in: labelSource.line.text) {
                hasExplicitMatchingScope = labelService == explicitlyScopedService
            } else {
                hasExplicitMatchingScope = false
            }
            let candidateValueLines = hasExplicitMatchingScope ? valueLines : lines
            let associatedValues = candidateValueLines.compactMap {
                valueSource -> (Value, SourceLine, LayoutAssociationTier)? in
                guard valueSource.pageIndex == labelSource.pageIndex,
                      isEligibleCurrentLine(valueSource.line.text),
                      let tier = layoutAssociationTier(
                        label: labelSource.line.normalizedBoundingBox,
                        value: valueSource.line.normalizedBoundingBox
                      ),
                      let value = valueParser(valueSource.line.text) else {
                    return nil
                }
                return (value, valueSource, tier)
            }
            let sameRowValues = associatedValues.filter { $0.2 == .sameRow }
            let highestTierValues = sameRowValues.isEmpty
                ? associatedValues.filter { $0.2 == .stacked }
                : sameRowValues
            guard let association = highestTierValues.first,
                  highestTierValues.dropFirst().allSatisfy({ $0.0 == association.0 }) else {
                return nil
            }
            return Candidate(
                value: association.0,
                provenance: combinedProvenance(
                    label: labelSource,
                    value: association.1
                )
            )
        }
    }

    private func unique<Value: Equatable>(
        _ candidates: [Candidate<Value>]
    ) -> Candidate<Value>? {
        guard let first = candidates.first,
              candidates.dropFirst().allSatisfy({ $0.value == first.value }) else {
            return nil
        }
        return first
    }

    private func layoutAssociationTier(
        label: CGRect,
        value: CGRect
    ) -> LayoutAssociationTier? {
        let verticalOverlap = max(0, min(label.maxY, value.maxY) - max(label.minY, value.minY))
        let minimumHeight = min(label.height, value.height)
        let verticalOverlapFraction = minimumHeight > 0 ? verticalOverlap / minimumHeight : 0
        let rowCenterDistance = abs(label.midY - value.midY)
        let horizontalGap = max(0, value.minX - label.maxX)
        let sameRow = value.midX >= label.midX - LayoutAssociationRule.leadingTolerance
            && horizontalGap <= LayoutAssociationRule.maximumHorizontalGap
            && (verticalOverlapFraction >= LayoutAssociationRule.minimumOverlapFraction
                || rowCenterDistance <= LayoutAssociationRule.rowCenterTolerance)

        let horizontalOverlap = max(0, min(label.maxX, value.maxX) - max(label.minX, value.minX))
        let minimumWidth = min(label.width, value.width)
        let horizontalOverlapFraction = minimumWidth > 0 ? horizontalOverlap / minimumWidth : 0
        let verticalGap = max(0, max(label.minY, value.minY) - min(label.maxY, value.maxY))
        let stacked = verticalGap <= LayoutAssociationRule.maximumStackedGap
            && horizontalOverlapFraction >= LayoutAssociationRule.minimumOverlapFraction

        if sameRow {
            return .sameRow
        }
        if stacked {
            return .stacked
        }
        return nil
    }

    private func combinedProvenance(
        label: SourceLine,
        value: SourceLine
    ) -> BillSourceProvenance {
        BillSourceProvenance(
            pageIndex: label.pageIndex,
            snippet: boundedSnippet("\(label.line.text) | \(value.line.text)"),
            normalizedBoundingBox: label.line.normalizedBoundingBox.union(
                value.line.normalizedBoundingBox
            )
        )
    }

    private func statementProposal(
        _ field: BillStatementFieldName,
        _ value: BillProposedValue,
        _ provenance: BillSourceProvenance,
        origin: BillProposalOrigin = .extracted
    ) -> BillStatementFieldProposal {
        BillStatementFieldProposal(
            field: field,
            value: value,
            provenance: provenance,
            origin: origin
        )
    }

    private func serviceProposal(
        _ field: BillServiceFieldName,
        _ value: BillProposedValue,
        _ provenance: BillSourceProvenance,
        origin: BillProposalOrigin = .extracted
    ) -> BillServiceFieldProposal {
        BillServiceFieldProposal(
            field: field,
            value: value,
            provenance: provenance,
            origin: origin
        )
    }

    private func appendStatement<Value>(
        _ candidate: Candidate<Value>?,
        field: BillStatementFieldName,
        to proposals: inout [BillStatementFieldProposal],
        value: (Value) -> BillProposedValue
    ) {
        guard let candidate else { return }
        proposals.append(statementProposal(field, value(candidate.value), candidate.provenance))
    }

    private func appendService<Value>(
        _ candidate: Candidate<Value>?,
        field: BillServiceFieldName,
        to proposals: inout [BillServiceFieldProposal],
        value: (Value) -> BillProposedValue
    ) {
        guard let candidate else { return }
        proposals.append(serviceProposal(field, value(candidate.value), candidate.provenance))
    }

    private func provenance(
        pageIndex: Int,
        line: RecognizedDocumentLine
    ) -> BillSourceProvenance {
        BillSourceProvenance(
            pageIndex: pageIndex,
            snippet: boundedSnippet(line.text),
            normalizedBoundingBox: line.normalizedBoundingBox
        )
    }

    private func derivedDays(from start: Date, to end: Date) -> Int? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        guard let days = calendar.dateComponents([.day], from: start, to: end).day,
              (1...366).contains(days) else {
            return nil
        }
        return days
    }

    private func parseDate(_ text: String) -> Date? {
        let formats = ["M/d/yyyy", "M/d/yy", "MMMM d, yyyy", "MMM d, yyyy"]
        for format in formats {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            formatter.isLenient = false
            if let date = formatter.date(from: text) {
                return date
            }
        }
        return nil
    }

    private func normalizedUnit(_ unit: String) -> String {
        switch unit.lowercased() {
        case "kwh": "kWh"
        case "therm", "therms": "therms"
        case "ccf": "CCF"
        case "gallon", "gallons", "gal": unit.lowercased()
        case "water unit", "water units": "water units"
        default: unit
        }
    }

    private func boundedSnippet(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(collapsed.prefix(240))
    }

    private func matches(_ pattern: String, in text: String) -> Bool {
        firstMatch(pattern, in: text) != nil
    }

    private func isEligibleCurrentLine(_ text: String) -> Bool {
        !matches(Self.nonCurrentContextPattern, in: text)
    }

    private func firstMatch(_ pattern: String, in text: String) -> String? {
        firstCapture(pattern, in: text, capture: 0)
    }

    private func firstCapture(
        _ pattern: String,
        in text: String,
        capture: Int = 1
    ) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ),
              capture < match.numberOfRanges,
              let range = Range(match.range(at: capture), in: text) else {
            return nil
        }
        return String(text[range])
    }

    private func allMatches(_ pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        return expression.matches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        ).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

}
