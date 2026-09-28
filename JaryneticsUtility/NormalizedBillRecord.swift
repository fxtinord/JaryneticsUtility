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
        let rawCandidates = lines.compactMap { source -> Candidate? in
            guard let issuer = organizationName(in: source.line.text) else { return nil }
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
            var score = 3
            if source.line.normalizedBoundingBox.maxY >= 0.72 { score += 2 }
            if source.sequenceIndex <= 7 { score += 1 }
            if repeated.count > 1 { score += 2 }
            if !domainEvidence.isEmpty { score += 2 }
            if billingAdjacency { score += 1 }
            return Candidate(
                issuer: issuer,
                primary: source,
                score: score,
                supporting: repeated + domainEvidence
            )
        }
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
                $0.pageIndex == source.pageIndex && $0.sequenceIndex == source.sequenceIndex
            }) { result.append(source) }
        }
        return ProviderNeutralBillIdentity(
            issuer: best.issuer,
            provenance: provenance(for: best.primary),
            supportingEvidence: support.map(provenance)
        )
    }

    private func organizationName(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRejectedIdentityText(trimmed),
              !trimmed.contains(where: \.isNumber),
              trimmed.count <= 80 else { return nil }
        let rolePattern = #"^([\p{L}][\p{L}&'. -]{2,60}?)\s+(?:provides|delivers|supplies)\b"#
        let wholePattern = #"^[\p{L}][\p{L}&'. -]{2,60}\b(?:utility|utilities|electric|electricity|gas|energy|power|cooperative|company|municipal|authority|department|district|corporation|corp|inc)\.?$"#
        let candidate: String
        if let match = firstMatch(rolePattern, in: trimmed),
           let range = Range(match.range(at: 1), in: trimmed) {
            candidate = String(trimmed[range])
        } else if firstMatch(wholePattern, in: trimmed) != nil {
            candidate = trimmed
        } else {
            return nil
        }
        let cleaned = candidate.trimmingCharacters(in: CharacterSet(charactersIn: " .,-"))
        guard cleaned.split(whereSeparator: \.isWhitespace).count >= 2,
              !isGenericHeading(cleaned) else { return nil }
        return cleaned
    }

    private func isRejectedIdentityText(_ text: String) -> Bool {
        text.range(
            of: #"\b(?:customer|customer\s+name|service\s+address|mailing\s+address|account\s+(?:number|summary)|current\s+charges|amount\s+due|payment|emergency|outage|contact|phone|telephone)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
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

struct NormalizedBillRecordAssembler {
    private let identityResolver = ProviderNeutralBillIdentityResolver()

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
            statementDate: extraction.statementProposal(for: .statementDate),
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
