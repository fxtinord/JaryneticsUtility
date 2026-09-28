import CoreGraphics
import Foundation

enum BillStatementFieldName: String, CaseIterable, Sendable {
    case billIssuer = "Bill issuer"
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

enum BillDistributedEnergyFieldName: String, CaseIterable, Sendable {
    case isNetMetered = "Net metered"
    case netEnergyQuantity = "Net energy quantity"
    case netEnergyUnit = "Net energy unit"
    case priorEnergyCreditBalance = "Prior energy-credit balance"
    case newEnergyCreditBalance = "New energy-credit balance"
    case energyCreditUnit = "Energy-credit unit"
    case settlementMonth = "Settlement month"
}

enum BillProposedValue: Sendable, Equatable {
    case boolean(Bool)
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
    let sequenceIndex: Int?

    init(
        pageIndex: Int,
        snippet: String,
        normalizedBoundingBox: CGRect?,
        sequenceIndex: Int? = nil
    ) {
        self.pageIndex = pageIndex
        self.snippet = snippet
        self.normalizedBoundingBox = normalizedBoundingBox
        self.sequenceIndex = sequenceIndex
    }
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

struct BillDistributedEnergyFieldProposal: Sendable, Equatable, Identifiable {
    var id: BillDistributedEnergyFieldName { field }

    let field: BillDistributedEnergyFieldName
    let value: BillProposedValue
    let provenance: BillSourceProvenance
    let origin: BillProposalOrigin
}

struct BillDistributedEnergyProposalGroup: Sendable, Equatable {
    let proposals: [BillDistributedEnergyFieldProposal]

    func proposal(
        for field: BillDistributedEnergyFieldName
    ) -> BillDistributedEnergyFieldProposal? {
        proposals.first { $0.field == field }
    }
}

struct BillServiceProposalGroup: Sendable, Equatable, Identifiable {
    var id: UtilityServiceType { serviceType }

    let serviceType: UtilityServiceType
    let serviceIdentityProvenance: BillSourceProvenance
    let proposals: [BillServiceFieldProposal]
    let distributedEnergy: BillDistributedEnergyProposalGroup?

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

    private struct EnergyValue: Equatable {
        let quantity: Decimal
        let unit: String
    }

    private struct BillIssuerIdentity {
        let canonicalName: String
        let evidencePatterns: [String]
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
    private static let usageValuePattern = #"(?<![-+])\b[0-9]+(?:,[0-9]{3})*(?:\.\d+)?\s*(?:kwh|therms?|ccf|gallons?|gal|water\s+units?)\b"#
    private static let nonCurrentContextPattern = #"\b(?:previous|prior|historical|history|past[\s-]+due|average|daily|comparison|comparative|compare|last\s+(?:month|period|year)|year[\s-]+over[\s-]+year)\b"#
    private static let nonBillingServiceContextPattern = #"\b(?:emergenc(?:y|ies)|outage|safety|customer\s+service|telephone|phone|contact|call|means|definition|defined|example|glossary)\b"#
    private static let issuerIdentities = [
        BillIssuerIdentity(
            canonicalName: "National Grid",
            evidencePatterns: [
                #"\bnational\s+grid\b"#,
                #"\b(?:www\.)?nationalgrid(?:us)?\.com\b"#,
            ]
        ),
        BillIssuerIdentity(
            canonicalName: "PG&E",
            evidencePatterns: [
                #"\bpg\s*&\s*e\b"#,
                #"\bpacific\s+gas\s+and\s+electric(?:\s+company)?\b"#,
                #"\b(?:www\.)?pge\.com\b"#,
            ]
        ),
    ]

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
        let billIssuer = uniqueBillIssuer(in: lines)
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
        appendStatement(billIssuer, field: .billIssuer, to: &proposals) { .text($0) }
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
            proposals: proposals,
            distributedEnergy: extractDistributedEnergy(
                from: serviceLines
            )
        )
    }

    private func extractDistributedEnergy(
        from serviceLines: ServiceLines
    ) -> BillDistributedEnergyProposalGroup? {
        guard serviceLines.serviceType == .electricity else { return nil }

        let netMetered: Candidate<Bool>? = uniqueCandidate(in: serviceLines.lines) { line in
            guard isEligibleCurrentLine(line.text),
                  isNetMeteringContextLabel(line.text) else {
                return nil
            }
            return true
        }
        var netEnergyCandidates = energyCandidates(
            in: serviceLines.lines,
            labelMatches: isNetMeteredLabel
        )
        if netMetered != nil {
            netEnergyCandidates += energyCandidates(
                in: serviceLines.lines,
                labelMatches: isTotalUsageLabel,
                directValueParser: explicitlySignedEnergyValue,
                splitValueParser: standaloneExplicitlySignedEnergyValue
            )
            if netEnergyCandidates.isEmpty {
                // Some net-metering summaries place one signed current-period
                // kWh value apart from the later Net Met Cr label. Accept only
                // a unique standalone signed value; rate expressions, money,
                // unsigned OCR and descriptive/history lines do not qualify.
                let creditContextPages = Set(serviceLines.lines.compactMap { source in
                    isEligibleCurrentLine(source.line.text)
                        && isNetMeteringCreditLabel(source.line.text)
                        ? source.pageIndex : nil
                })
                let standalone: [Candidate<EnergyValue>] = candidates(
                    in: serviceLines.lines.filter { creditContextPages.contains($0.pageIndex) }
                ) { line in
                    guard isEligibleCurrentLine(line.text),
                          !matches(
                            #"\b(?:meter\s+reading|rate|calculation|example|tier|comparison)\b|[$•]"#,
                            in: line.text
                          ) else { return nil }
                    return standaloneExplicitlySignedEnergyValue(in: line.text)
                }
                if let uniqueStandalone = unique(standalone) {
                    netEnergyCandidates.append(uniqueStandalone)
                }
            }
        }
        let netEnergy = unique(netEnergyCandidates)
        let priorCredit = unique(energyCandidates(
            in: serviceLines.lines,
            labelMatches: isPriorEnergyCreditLabel
        ))
        let newCredit = unique(energyCandidates(
            in: serviceLines.lines,
            labelMatches: isNewEnergyCreditLabel
        ))
        let settlementMonth = uniqueSettlementMonth(in: serviceLines.lines)

        var proposals: [BillDistributedEnergyFieldProposal] = []
        appendDistributedEnergy(netMetered, field: .isNetMetered, to: &proposals) {
            .boolean($0)
        }
        if let netEnergy {
            proposals.append(distributedEnergyProposal(
                .netEnergyQuantity,
                .decimal(netEnergy.value.quantity),
                netEnergy.provenance
            ))
            proposals.append(distributedEnergyProposal(
                .netEnergyUnit,
                .text(netEnergy.value.unit),
                netEnergy.provenance
            ))
        }
        appendDistributedEnergy(
            priorCredit.map { Candidate(value: $0.value.quantity, provenance: $0.provenance) },
            field: .priorEnergyCreditBalance,
            to: &proposals
        ) { .decimal($0) }
        appendDistributedEnergy(
            newCredit.map { Candidate(value: $0.value.quantity, provenance: $0.provenance) },
            field: .newEnergyCreditBalance,
            to: &proposals
        ) { .decimal($0) }

        let creditUnits = [priorCredit, newCredit].compactMap { candidate in
            candidate.map {
                Candidate(value: $0.value.unit, provenance: $0.provenance)
            }
        }
        appendDistributedEnergy(
            unique(creditUnits),
            field: .energyCreditUnit,
            to: &proposals
        ) { .text($0) }
        appendDistributedEnergy(
            settlementMonth,
            field: .settlementMonth,
            to: &proposals
        ) { .integer($0) }

        return proposals.isEmpty
            ? nil
            : BillDistributedEnergyProposalGroup(proposals: proposals)
    }

    private func scopedServiceLines(
        in recognition: DocumentRecognitionResult
    ) -> [ServiceLines] {
        let documentEvidence = documentServiceEvidence(in: recognition)
        let order = documentEvidence.map(\.serviceType)
        var groups = documentEvidence.reduce(into: [UtilityServiceType: ServiceLines]()) {
            result, evidence in
            result[evidence.serviceType] = ServiceLines(
                serviceType: evidence.serviceType,
                identityProvenance: provenance(
                    pageIndex: evidence.sourceLine.pageIndex,
                    line: evidence.sourceLine.line
                ),
                lines: []
            )
        }
        let inheritedType = order.count == 1 ? order.first : nil

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
            var currentType: UtilityServiceType?
            switch distinctTypes.count {
            case 0:
                currentType = inheritedType
            case 1:
                currentType = distinctTypes.first
            default:
                currentType = nil
            }

            for sourceLine in eligibleLines {
                let line = sourceLine.line
                switch serviceTypeMatch(in: line.text) {
                case .identified(let type):
                    currentType = type
                case .ambiguous:
                    currentType = nil
                    continue
                case .none:
                    break
                }

                guard let currentType else { continue }
                groups[currentType]?.lines.append(sourceLine)
            }
        }

        return order.compactMap { groups[$0] }
    }

    private func documentServiceEvidence(
        in recognition: DocumentRecognitionResult
    ) -> [(serviceType: UtilityServiceType, sourceLine: SourceLine)] {
        var evidence: [(UtilityServiceType, SourceLine)] = []
        for page in recognition.pages {
            for line in page.lines where isEligibleCurrentLine(line.text) {
                guard case .identified(let type) = serviceTypeMatch(in: line.text),
                      !evidence.contains(where: { $0.0 == type }) else {
                    continue
                }
                evidence.append((type, SourceLine(pageIndex: page.pageIndex, line: line)))
            }
        }
        return evidence
    }

    private func serviceTypeMatch(in text: String) -> ServiceTypeMatch {
        guard !matches(Self.nonBillingServiceContextPattern, in: text) else {
            return .none
        }

        var matchesByType: [UtilityServiceType] = []
        if isNetMeteringContextLabel(text) || matches(
            #"^\s*(?:(?:electricity|electric)\s*$|electric(?:ity)?\s+service\b|details?\s+of\s+electric(?:ity)?\s+charges\b|(?:current|total)\s+electric(?:ity)?\s+charges\b|electric(?:ity)?\s+usage\b)"#,
            in: text
        ) {
            matchesByType.append(.electricity)
        }
        if matches(
            #"^\s*(?:(?:natural\s+gas|gas)\s*$|(?:natural\s+)?gas\s+service\b|details?\s+of\s+(?:natural\s+)?gas\s+charges\b|(?:current|total)\s+(?:natural\s+)?gas\s+charges\b|(?:natural\s+)?gas\s+usage\b)"#,
            in: text
        ) {
            matchesByType.append(.naturalGas)
        }
        if matches(
            #"^\s*(?:(?:water(?:\s*/\s*wastewater)?|wastewater)\s*$|(?:water(?:\s*/\s*wastewater)?|wastewater)\s+(?:service|usage)\b|details?\s+of\s+(?:water(?:\s*/\s*wastewater)?|wastewater)\s+charges\b|(?:current|total)\s+(?:water(?:\s*/\s*wastewater)?|wastewater)\s+charges\b)"#,
            in: text
        ) {
            matchesByType.append(.waterWastewater)
        }

        let mentionsElectricity = matches(#"\belectric(?:ity)?\b"#, in: text)
        let mentionsGas = matches(#"\bnatural\s+gas\b|\bgas\b"#, in: text)
        if mentionsElectricity,
           mentionsGas,
           matches(#"\b(?:service|charges|usage)\b"#, in: text) {
            return .ambiguous
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

    private func uniqueBillIssuer(in lines: [SourceLine]) -> Candidate<String>? {
        uniqueCandidate(in: lines) { line in
            let identities = Self.issuerIdentities.filter { identity in
                identity.evidencePatterns.contains { pattern in
                    matches(pattern, in: line.text)
                }
            }
            guard identities.count == 1 else { return nil }
            return identities[0].canonicalName
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

    private func energyCandidates(
        in lines: [SourceLine],
        labelMatches: (String) -> Bool,
        directValueParser: ((String) -> EnergyValue?)? = nil,
        splitValueParser: ((String) -> EnergyValue?)? = nil
    ) -> [Candidate<EnergyValue>] {
        let directParser = directValueParser ?? energyValue
        let splitParser = splitValueParser ?? standaloneEnergyValue
        let directCandidates: [Candidate<EnergyValue>] = lines.compactMap { source in
            guard isEligibleCurrentLine(source.line.text), labelMatches(source.line.text) else {
                return nil
            }
            if let refinement = source.line.rowRefinement {
                guard refinement.kind == .signedEnergy,
                      let text = refinement.valueText,
                      let value = explicitlySignedEnergyValue(in: text) else { return nil }
                let valueLine = RecognizedDocumentLine(
                    text: text,
                    normalizedBoundingBox: refinement.normalizedBoundingBox
                        ?? source.line.normalizedBoundingBox
                )
                return Candidate(value: value, provenance: combinedProvenance(
                    label: source,
                    value: SourceLine(pageIndex: source.pageIndex, line: valueLine)
                ))
            }
            guard let value = directParser(source.line.text) else { return nil }
            return Candidate(value: value, provenance: provenance(
                pageIndex: source.pageIndex,
                line: source.line
            ))
        }
        let splitCandidates = distributedEnergySplitCandidates(
            in: lines,
            labelMatches: labelMatches,
            valueParser: splitParser
        )
        return directCandidates + splitCandidates
    }

    private func uniqueSettlementMonth(in lines: [SourceLine]) -> Candidate<Int>? {
        let directCandidates: [Candidate<Int>] = lines.compactMap { source in
            let line = source.line
            guard isEligibleCurrentLine(line.text), isSettlementMonthLabel(line.text) else {
                return nil
            }
            if let refinement = line.rowRefinement {
                guard refinement.kind == .settlementMonth,
                      let text = refinement.valueText,
                      let value = standaloneSettlementMonth(in: text) else { return nil }
                let valueLine = RecognizedDocumentLine(
                    text: text,
                    normalizedBoundingBox: refinement.normalizedBoundingBox
                        ?? line.normalizedBoundingBox
                )
                return Candidate(value: value, provenance: combinedProvenance(
                    label: source,
                    value: SourceLine(pageIndex: source.pageIndex, line: valueLine)
                ))
            }
            guard
                  let valueText = firstCapture(
                    #"^(?:\s*)(?:anniversary|settlement|true[\s-]*up)\s+month\s*[:\-]?\s*(\d{1,2})\b"#,
                    in: line.text
                  ),
                  let value = Int(valueText),
                  (1...12).contains(value) else {
                return nil
            }
            return Candidate(value: value, provenance: provenance(
                pageIndex: source.pageIndex,
                line: line
            ))
        }
        let splitCandidates = splitCandidates(
            in: lines,
            valueLines: lines,
            labelMatches: isSettlementMonthLabel,
            valueParser: standaloneSettlementMonth
        )
        return unique(directCandidates + splitCandidates)
    }

    /// Distributed-energy tables use short, repeated rows. Match by vertical
    /// overlap first, otherwise by center distance measured in text heights.
    /// A match must be mutually closest, clearly separated by 0.35 line height
    /// from a runner-up, and a value can therefore belong to only one row.
    private func distributedEnergySplitCandidates(
        in lines: [SourceLine],
        labelMatches: (String) -> Bool,
        valueParser: (String) -> EnergyValue?
    ) -> [Candidate<EnergyValue>] {
        let allLabels = lines.filter {
            isEligibleCurrentLine($0.line.text)
                && isDistributedEnergyRowLabel($0.line.text)
                && $0.line.rowRefinement == nil
        }
        let targetLabels = allLabels.filter { labelMatches($0.line.text) }
        let values = lines.compactMap { source -> (SourceLine, EnergyValue)? in
            guard isEligibleCurrentLine(source.line.text),
                  let value = valueParser(source.line.text) else { return nil }
            return (source, value)
        }

        return targetLabels.compactMap { label in
            let matches = values.compactMap { value -> (SourceLine, EnergyValue, RowScore)? in
                guard value.0.pageIndex == label.pageIndex,
                      let score = distributedEnergyRowScore(
                        label: label.line.normalizedBoundingBox,
                        value: value.0.line.normalizedBoundingBox
                      ) else { return nil }
                return (value.0, value.1, score)
            }.sorted { $0.2 < $1.2 }
            guard let best = matches.first,
                  matches.count == 1 || best.2.isClearlyBetter(than: matches[1].2) else {
                return nil
            }
            let competingLabels = allLabels.compactMap { other -> (SourceLine, RowScore)? in
                guard other.pageIndex == best.0.pageIndex,
                      let score = distributedEnergyRowScore(
                        label: other.line.normalizedBoundingBox,
                        value: best.0.line.normalizedBoundingBox
                      ) else { return nil }
                return (other, score)
            }.sorted { $0.1 < $1.1 }
            guard let owner = competingLabels.first,
                  isSameSourceLine(owner.0, label),
                  competingLabels.count == 1 || owner.1.isClearlyBetter(than: competingLabels[1].1)
            else { return nil }
            return Candidate(value: best.1, provenance: combinedProvenance(label: label, value: best.0))
        }
    }

    private struct RowScore: Comparable {
        let overlapRank: Int
        let normalizedCenterDistance: CGFloat

        static func < (lhs: RowScore, rhs: RowScore) -> Bool {
            (lhs.overlapRank, lhs.normalizedCenterDistance)
                < (rhs.overlapRank, rhs.normalizedCenterDistance)
        }

        func isClearlyBetter(than other: RowScore) -> Bool {
            overlapRank < other.overlapRank
                || (overlapRank == other.overlapRank
                    && other.normalizedCenterDistance - normalizedCenterDistance >= 0.35)
        }
    }

    private func distributedEnergyRowScore(label: CGRect, value: CGRect) -> RowScore? {
        guard value.midX >= label.midX - LayoutAssociationRule.leadingTolerance,
              max(0, value.minX - label.maxX) <= LayoutAssociationRule.maximumHorizontalGap else {
            return nil
        }
        let overlap = max(0, min(label.maxY, value.maxY) - max(label.minY, value.minY))
        let scale = max(min(label.height, value.height), 0.0001)
        let distance = abs(label.midY - value.midY) / scale
        if overlap > 0 {
            return RowScore(overlapRank: 0, normalizedCenterDistance: distance)
        }
        guard distance <= 1.75 else { return nil }
        return RowScore(overlapRank: 1, normalizedCenterDistance: distance)
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

    private func isNetMeteredLabel(_ text: String) -> Bool {
        matches(#"^\s*net\s+metered\b"#, in: text)
    }

    private func isNetMeteringCreditLabel(_ text: String) -> Bool {
        matches(#"^\s*net\s+met(?:ering)?\s+cr(?:edit)?\b"#, in: text)
    }

    private func isNetMeteringContextLabel(_ text: String) -> Bool {
        isNetMeteredLabel(text) || isNetMeteringCreditLabel(text)
    }

    private func isPriorEnergyCreditLabel(_ text: String) -> Bool {
        matches(#"^\s*cumulative\s+(?:energy\s+)?credit\b"#, in: text)
    }

    private func isNewEnergyCreditLabel(_ text: String) -> Bool {
        matches(#"^\s*new\s+cumulative\s+(?:energy\s+)?credit\b"#, in: text)
    }

    private func isSettlementMonthLabel(_ text: String) -> Bool {
        matches(
            #"^\s*(?:anniversary|settlement|true[\s-]*up)\s+month\b"#,
            in: text
        )
    }

    private func isTotalUsageLabel(_ text: String) -> Bool {
        matches(#"^\s*total\s+usage\b"#, in: text)
    }

    private func isDistributedEnergyRowLabel(_ text: String) -> Bool {
        isNetMeteringContextLabel(text)
            || isPriorEnergyCreditLabel(text)
            || isNewEnergyCreditLabel(text)
            || isTotalUsageLabel(text)
    }

    private func energyValue(in text: String) -> EnergyValue? {
        let values = allMatches(
            #"[+-]?[0-9]+(?:,[0-9]{3})*(?:\.\d+)?\s*kwh\b"#,
            in: text
        )
        guard values.count == 1,
              let valueText = values.first,
              let quantityText = firstCapture(
                #"([+-]?[0-9]+(?:,[0-9]{3})*(?:\.\d+)?)\s*kwh\b"#,
                in: valueText
              ),
              let quantity = Decimal(
                string: quantityText.replacingOccurrences(of: ",", with: ""),
                locale: Locale(identifier: "en_US_POSIX")
              ) else {
            return nil
        }
        return EnergyValue(quantity: quantity, unit: "kWh")
    }

    private func standaloneEnergyValue(in text: String) -> EnergyValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard matches(
            #"^[+-]?[0-9]+(?:,[0-9]{3})*(?:\.\d+)?\s*kwh$"#,
            in: trimmed
        ) else {
            return nil
        }
        return energyValue(in: trimmed)
    }

    private func explicitlySignedEnergyValue(in text: String) -> EnergyValue? {
        guard matches(
            #"[+-][0-9]+(?:,[0-9]{3})*(?:\.\d+)?\s*kwh\b"#,
            in: text
        ) else {
            return nil
        }
        return energyValue(in: text)
    }

    private func standaloneExplicitlySignedEnergyValue(in text: String) -> EnergyValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard matches(
            #"^[+-][0-9]+(?:,[0-9]{3})*(?:\.\d+)?\s*kwh$"#,
            in: trimmed
        ) else {
            return nil
        }
        return energyValue(in: trimmed)
    }

    private func standaloneSettlementMonth(in text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard matches(#"^\d{1,2}$"#, in: trimmed),
              let value = Int(trimmed),
              (1...12).contains(value) else {
            return nil
        }
        return value
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
        explicitlyScopedService: UtilityServiceType? = nil,
        reservedSameRowLabelMatches: ((String) -> Bool)? = nil
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
                if tier == .stacked,
                   let reservedSameRowLabelMatches,
                   candidateValueLines.contains(where: { otherLabel in
                       !isSameSourceLine(otherLabel, labelSource)
                           && otherLabel.pageIndex == valueSource.pageIndex
                           && reservedSameRowLabelMatches(otherLabel.line.text)
                           && layoutAssociationTier(
                            label: otherLabel.line.normalizedBoundingBox,
                            value: valueSource.line.normalizedBoundingBox
                           ) == .sameRow
                   }) {
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

    private func isSameSourceLine(_ lhs: SourceLine, _ rhs: SourceLine) -> Bool {
        lhs.pageIndex == rhs.pageIndex && lhs.line == rhs.line
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

    private func distributedEnergyProposal(
        _ field: BillDistributedEnergyFieldName,
        _ value: BillProposedValue,
        _ provenance: BillSourceProvenance,
        origin: BillProposalOrigin = .extracted
    ) -> BillDistributedEnergyFieldProposal {
        BillDistributedEnergyFieldProposal(
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

    private func appendDistributedEnergy<Value>(
        _ candidate: Candidate<Value>?,
        field: BillDistributedEnergyFieldName,
        to proposals: inout [BillDistributedEnergyFieldProposal],
        value: (Value) -> BillProposedValue
    ) {
        guard let candidate else { return }
        proposals.append(distributedEnergyProposal(
            field,
            value(candidate.value),
            candidate.provenance
        ))
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
