import CoreGraphics
import Foundation

struct ProviderNeutralBillIdentity: Sendable, Equatable {
    let issuer: String
    let provenance: BillSourceProvenance
    let supportingEvidence: [BillSourceProvenance]
}

/// Resolves only evidence-backed organization text present in the document.
/// It performs no provider lookup, canonicalization, or external entity resolution.
struct ProviderNeutralBillIdentityResolver {
    private struct SourceLine {
        let pageIndex: Int
        let sequenceIndex: Int
        let line: RecognizedDocumentLine
    }

    private struct Candidate {
        let issuer: String
        let primary: SourceLine
        let score: Int
        let supporting: [SourceLine]
    }

    func resolve(from recognition: DocumentRecognitionResult) -> ProviderNeutralBillIdentity? {
        guard let firstPage = recognition.pages.first else { return nil }
        let lines = firstPage.lines.enumerated().map {
            SourceLine(pageIndex: firstPage.pageIndex, sequenceIndex: $0.offset, line: $0.element)
        }
        let domains = lines.filter { domain(in: $0.line.text) != nil }
        let directCandidates = lines.compactMap { source -> Candidate? in
            guard let issuer = organizationName(in: source.line.text) else { return nil }
            return candidate(for: issuer, source: source, lines: lines, domains: domains)
        }
        let composedCandidates = zip(lines, lines.dropFirst()).compactMap { first, second in
            composedCandidate(first: first, second: second, lines: lines, domains: domains)
        }
        let rawCandidates = directCandidates + composedCandidates
        let grouped = Dictionary(grouping: rawCandidates, by: { normalizedOrganization($0.issuer) })
        let candidates = grouped.values.compactMap { group -> Candidate? in
            group.max { $0.score < $1.score }
        }.filter { $0.score >= 5 }.sorted { $0.score > $1.score }

        guard let best = candidates.first,
              candidates.count == 1 || best.score - candidates[1].score >= 2 else {
            return nil
        }
        let support = ([best.primary] + best.supporting).reduce(into: [SourceLine]()) {
            result, source in
            if !result.contains(where: {
                $0.pageIndex == source.pageIndex
                    && $0.sequenceIndex == source.sequenceIndex
                    && $0.line.text == source.line.text
            }) { result.append(source) }
        }
        return ProviderNeutralBillIdentity(
            issuer: best.issuer,
            provenance: provenance(for: best.primary),
            supportingEvidence: support.map(provenance)
        )
    }

    private func candidate(
        for issuer: String,
        source: SourceLine,
        lines: [SourceLine],
        domains: [SourceLine],
        additionalSupport: [SourceLine] = [],
        compositionBonus: Int = 0
    ) -> Candidate {
        let repeated = lines.filter {
            normalizedOrganization($0.line.text) == normalizedOrganization(issuer)
        }
        let domainEvidence = domains.filter {
            domainCorroborates($0.line.text, organization: issuer)
        }
        let billingAdjacency = lines.contains {
            abs($0.sequenceIndex - source.sequenceIndex) <= 3
                && isBillingContext($0.line.text)
        }
        let tokenCount = issuer.split(whereSeparator: \.isWhitespace).count
        var score = tokenCount == 1 ? 2 : 3
        if source.line.normalizedBoundingBox.maxY >= 0.72 { score += 2 }
        if source.sequenceIndex <= 7 { score += 1 }
        if repeated.count > 1 { score += 2 }
        if !domainEvidence.isEmpty { score += 2 }
        if billingAdjacency { score += 1 }
        if hasSeparatedOrganizationRole(near: source, in: lines) { score -= 4 }
        score += compositionBonus
        return Candidate(
            issuer: issuer,
            primary: source,
            score: score,
            supporting: repeated + domainEvidence + additionalSupport
        )
    }

    private func composedCandidate(
        first: SourceLine,
        second: SourceLine,
        lines: [SourceLine],
        domains: [SourceLine]
    ) -> Candidate? {
        guard first.pageIndex == second.pageIndex,
              first.sequenceIndex <= 7,
              second.sequenceIndex == first.sequenceIndex + 1,
              fragmentsCanCompose(first.line.text, second.line.text),
              geometricallyAdjacent(first.line.normalizedBoundingBox,
                                      second.line.normalizedBoundingBox) else {
            return nil
        }

        let combinedText = [first.line.text, second.line.text]
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " .,\n\t")) }
            .joined(separator: " ")
        guard let issuer = organizationName(in: combinedText) else { return nil }
        let combinedSource = SourceLine(
            pageIndex: first.pageIndex,
            sequenceIndex: first.sequenceIndex,
            line: RecognizedDocumentLine(
                text: issuer,
                normalizedBoundingBox: first.line.normalizedBoundingBox
                    .union(second.line.normalizedBoundingBox)
            )
        )
        return candidate(
            for: issuer,
            source: combinedSource,
            lines: lines,
            domains: domains,
            additionalSupport: [first, second],
            compositionBonus: 1
        )
    }

    private func fragmentsCanCompose(_ first: String, _ second: String) -> Bool {
        let firstNormalized = normalizedOrganization(first)
        guard !identityContinuationStopWords.contains(firstNormalized) else { return false }
        return [first, second].allSatisfy { fragment in
            let trimmed = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
            return !isRejectedIdentityText(trimmed)
                && domain(in: trimmed) == nil
                && !trimmed.contains(where: \.isNumber)
                && trimmed.count >= 3
                && trimmed.count <= 35
                && trimmed.split(whereSeparator: \.isWhitespace).count <= 3
                && firstMatch(#"^[\p{L}&'. -]+$"#, in: trimmed) != nil
                && !isGenericHeading(trimmed)
        }
    }

    private func geometricallyAdjacent(_ first: CGRect, _ second: CGRect) -> Bool {
        let maximumCenterDistance = max(first.height, second.height) * 2.5
        let verticalOrderIsPlausible = first.midY >= second.midY
        let horizontalOverlap = first.intersection(second).width > 0
        let compatibleLeadingEdges = abs(first.minX - second.minX) <= 0.20
        return verticalOrderIsPlausible
            && first.midY - second.midY <= maximumCenterDistance
            && (horizontalOverlap || compatibleLeadingEdges)
    }

    private func organizationName(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRejectedIdentityText(trimmed),
              domain(in: trimmed) == nil,
              !trimmed.contains(where: \.isNumber),
              trimmed.count <= 80 else { return nil }
        let rolePattern = #"^([\p{L}][\p{L}&'. -]{2,60}?)\s+(?:provides|delivers|supplies)\b"#
        let wholePattern = #"^[\p{L}][\p{L}&'. -]{2,60}\b(?:utility|utilities|electric|electricity|gas|energy|power|cooperative|company|municipal|authority|department|district|corporation|corp|inc)\.?$"#
        let brandPattern = #"^[\p{L}][\p{L}'.-]{2,29}$"#
        let candidate: String
        if let match = firstMatch(rolePattern, in: trimmed),
           let range = Range(match.range(at: 1), in: trimmed) {
            candidate = String(trimmed[range])
        } else if firstMatch(wholePattern, in: trimmed) != nil {
            candidate = trimmed
        } else if firstMatch(brandPattern, in: trimmed) != nil,
                  !genericBrandWords.contains(trimmed.lowercased()) {
            candidate = trimmed
        } else {
            return nil
        }
        let cleaned = candidate.trimmingCharacters(in: CharacterSet(charactersIn: " .,-"))
        guard !isGenericHeading(cleaned) else { return nil }
        return cleaned
    }

    private func isRejectedIdentityText(_ text: String) -> Bool {
        let generalRejection = text.range(
            of: #"\b(?:customer|customer\s+name|service\s+address|mailing\s+address|account\s+(?:number|summary)|current\s+charges|amount\s+due|payment|emergency|outage|contact|phone|telephone)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
        let corporateDescriptor = text.range(
            of: #"^(?:an?|the)\s+.+\s+compan(?:y|ies)\.?$|\b(?:subsidiary|member|division|affiliate)\s+of\b|\bparent\s+compan(?:y|ies)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
        return generalRejection || corporateDescriptor
    }

    private func hasSeparatedOrganizationRole(
        near source: SourceLine,
        in lines: [SourceLine]
    ) -> Bool {
        lines.contains { nearby in
            abs(nearby.sequenceIndex - source.sequenceIndex) <= 2
                && nearby.line.text.range(
                    of: #"\b(?:energy\s+supplier|retail\s+supplier|supply\s+charges|provides\s+(?:your\s+)?energy|payment\s+processor|remittance|regulator|public\s+service\s+commission|assistance\s+program)\b"#,
                    options: [.regularExpression, .caseInsensitive]
                ) != nil
        }
    }

    private func isGenericHeading(_ text: String) -> Bool {
        text.range(
            of: #"^(?:electric|electricity|natural\s+gas|gas|utility)?\s*(?:bill|billing)?\s*(?:statement|summary|details?)$|^(?:account\s+summary|current\s+charges)$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private func isBillingContext(_ text: String) -> Bool {
        text.range(
            of: #"\b(?:bill|billing|statement|account|amount\s+due|service)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private func domain(in text: String) -> String? {
        guard let match = firstMatch(
            #"\b(?:https?://)?(?:www\.)?([a-z0-9][a-z0-9-]*(?:\.[a-z0-9-]+)+)\b"#,
            in: text
        ), let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range]).lowercased()
    }

    private func domainCorroborates(_ text: String, organization: String) -> Bool {
        guard let domain = domain(in: text) else { return false }
        let domainStem = domain.split(separator: ".").first.map(String.init) ?? domain
        let organizationTokens = normalizedOrganization(organization).split(separator: " ")
            .map(String.init)
            .filter { !organizationStopWords.contains($0) }
        let joined = organizationTokens.joined()
        return organizationTokens.count >= 2
            && (joined.contains(domainStem) || domainStem.contains(joined)
                || organizationTokens.filter(domainStem.contains).count >= 2)
    }

    private var organizationStopWords: Set<String> {
        ["the", "company", "corporation", "corp", "inc", "utility", "utilities"]
    }

    private var genericBrandWords: Set<String> {
        [
            "account", "bill", "billing", "charges", "company", "customer", "electric",
            "electricity", "energy", "gas", "help", "payment", "service", "statement",
            "summary", "utility",
        ]
    }

    private var identityContinuationStopWords: Set<String> {
        ["hello", "save", "thank you", "thanks", "welcome", "your"]
    }

    private func normalizedOrganization(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private func provenance(for source: SourceLine) -> BillSourceProvenance {
        BillSourceProvenance(
            pageIndex: source.pageIndex,
            snippet: source.line.text,
            normalizedBoundingBox: source.line.normalizedBoundingBox,
            sequenceIndex: source.sequenceIndex
        )
    }

    private func firstMatch(_ pattern: String, in text: String) -> NSTextCheckingResult? {
        try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            .firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }
}

enum NormalizedBillRecordState: Sendable, Equatable {
    case proposedUnverified
}

enum NormalizedBillRecordWarning: Sendable, Equatable {
    case conflictingIssuerEvidence(direct: String, providerNeutral: String)
}

struct NormalizedBillServiceRecord: Sendable, Equatable, Identifiable {
    var id: UtilityServiceType { serviceType }

    let serviceType: UtilityServiceType
    let billingPeriodStart: BillServiceFieldProposal?
    let billingPeriodEnd: BillServiceFieldProposal?
    let billingDays: BillServiceFieldProposal?
    let currentPeriodCharges: BillServiceFieldProposal?
    let usageQuantity: BillServiceFieldProposal?
    let usageUnit: BillServiceFieldProposal?
    let distributedEnergy: BillDistributedEnergyProposalGroup?
}

struct NormalizedBillRecord: Sendable, Equatable {
    let billIssuer: BillStatementFieldProposal?
    let statementDate: BillStatementFieldProposal?
    let totalAmountDue: BillStatementFieldProposal?
    let services: [NormalizedBillServiceRecord]
    let state: NormalizedBillRecordState
    let warnings: [NormalizedBillRecordWarning]
}

/// Resolves only the bounded bill-level relationship where an exact statement-date
/// label is followed by one date-only OCR row. It does not search arbitrary dates.
private struct AdjacentStatementDateResolver {
    private struct Candidate: Equatable {
        let date: Date
        let provenance: BillSourceProvenance
    }

    private static let datePattern = #"(?:\d{1,2}/\d{1,2}/(?:\d{4}|\d{2})|(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\s+\d{1,2},\s+\d{4})"#

    func resolve(from recognition: DocumentRecognitionResult) -> BillStatementFieldProposal? {
        let candidates = recognition.pages.flatMap { page in
            zip(page.lines.indices, page.lines).compactMap { index, label -> Candidate? in
                guard isExactStatementDateLabel(label.text),
                      page.lines.indices.contains(index + 1) else { return nil }
                let value = page.lines[index + 1]
                guard geometricallyAssociated(label.normalizedBoundingBox,
                                               value.normalizedBoundingBox),
                      let dateText = completeDateText(in: value.text),
                      let date = parseDate(dateText) else { return nil }
                return Candidate(
                    date: date,
                    provenance: BillSourceProvenance(
                        pageIndex: page.pageIndex,
                        snippet: boundedSnippet("\(label.text) · \(value.text)"),
                        normalizedBoundingBox: label.normalizedBoundingBox
                            .union(value.normalizedBoundingBox),
                        sequenceIndex: index + 1
                    )
                )
            }
        }
        let distinctDates = Dictionary(grouping: candidates, by: \.date)
        guard distinctDates.count == 1,
              let candidate = distinctDates.values.first?.first else { return nil }
        return BillStatementFieldProposal(
            field: .statementDate,
            value: .date(candidate.date),
            provenance: candidate.provenance,
            origin: .extracted
        )
    }

    private func isExactStatementDateLabel(_ text: String) -> Bool {
        text.range(
            of: #"^\s*(?:statement|bill)\s+date\s*:?\s*$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private func completeDateText(in text: String) -> String? {
        guard let expression = try? NSRegularExpression(
            pattern: #"^\s*("# + Self.datePattern + #")\s*[.]?\s*$"#,
            options: [.caseInsensitive]
        ), let match = expression.firstMatch(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        ), let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private func geometricallyAssociated(_ label: CGRect, _ value: CGRect) -> Bool {
        let maximumCenterDistance = max(label.height, value.height) * 3
        let followsBelow = label.midY >= value.midY
        let horizontalOverlap = label.intersection(value).width > 0
        let compatibleLeadingEdges = abs(label.minX - value.minX) <= 0.25
        return followsBelow
            && label.midY - value.midY <= maximumCenterDistance
            && (horizontalOverlap || compatibleLeadingEdges)
    }

    private func parseDate(_ text: String) -> Date? {
        for format in ["M/d/yyyy", "M/d/yy", "MMMM d, yyyy", "MMM d, yyyy"] {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            formatter.isLenient = false
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    private func boundedSnippet(_ text: String) -> String {
        String(text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(240))
    }
}

struct NormalizedBillRecordAssembler {
    private let identityResolver = ProviderNeutralBillIdentityResolver()
    private let adjacentStatementDateResolver = AdjacentStatementDateResolver()

    func assemble(
        recognition: DocumentRecognitionResult,
        extraction: BillExtractionResult,
        semanticGuided: SemanticGuidedAssociationResult
    ) -> NormalizedBillRecord {
        let resolvedIdentity = identityResolver.resolve(from: recognition)
        let directIssuer = extraction.statementProposal(for: .billIssuer)
        let issuer = directIssuer ?? resolvedIdentity.map { identity in
            BillStatementFieldProposal(
                field: .billIssuer,
                value: .text(identity.issuer),
                provenance: identity.provenance,
                origin: .extracted
            )
        }
        var warnings: [NormalizedBillRecordWarning] = []
        if let directIssuer,
           case .text(let directName) = directIssuer.value,
           let resolvedIdentity,
           normalizedIdentity(directName) != normalizedIdentity(resolvedIdentity.issuer) {
            warnings.append(.conflictingIssuerEvidence(
                direct: directName,
                providerNeutral: resolvedIdentity.issuer
            ))
        }

        let serviceTypes = (
            extraction.serviceGroups.map(\.serviceType)
                + semanticGuided.serviceAssociations.map(\.serviceType)
        ).reduce(into: [UtilityServiceType]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        let services = serviceTypes.map { serviceType in
            let extracted = extraction.serviceGroup(for: serviceType)
            let guided = semanticGuided.serviceAssociation(for: serviceType)
            func proposal(_ field: BillServiceFieldName) -> BillServiceFieldProposal? {
                extracted?.proposal(for: field) ?? guided?.proposal(for: field)
            }
            return NormalizedBillServiceRecord(
                serviceType: serviceType,
                billingPeriodStart: proposal(.billingPeriodStart),
                billingPeriodEnd: proposal(.billingPeriodEnd),
                billingDays: proposal(.billingDays),
                currentPeriodCharges: proposal(.currentPeriodCharges),
                usageQuantity: proposal(.usageQuantity),
                usageUnit: proposal(.usageUnit),
                distributedEnergy: extracted?.distributedEnergy
            )
        }
        return NormalizedBillRecord(
            billIssuer: issuer,
            statementDate: extraction.statementProposal(for: .statementDate)
                ?? adjacentStatementDateResolver.resolve(from: recognition),
            totalAmountDue: extraction.statementProposal(for: .amountDue),
            services: services,
            state: .proposedUnverified,
            warnings: warnings
        )
    }

    private func normalizedIdentity(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: "", options: .regularExpression)
    }
}
