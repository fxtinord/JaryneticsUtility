import CoreGraphics
import Foundation

enum SemanticGuidedAssociationReason: Sendable, Equatable {
    case sameLine
    case sameRow
    case adjacentInSemanticRegion
}

struct SemanticGuidedServiceAssociation: Sendable, Equatable, Identifiable {
    var id: UtilityServiceType { serviceType }

    let serviceType: UtilityServiceType
    let proposals: [BillServiceFieldProposal]
    let reasons: [BillServiceFieldName: SemanticGuidedAssociationReason]

    func proposal(for field: BillServiceFieldName) -> BillServiceFieldProposal? {
        proposals.first { $0.field == field }
    }
}

struct SemanticGuidedAssociationResult: Sendable, Equatable {
    let serviceAssociations: [SemanticGuidedServiceAssociation]

    func serviceAssociation(
        for serviceType: UtilityServiceType
    ) -> SemanticGuidedServiceAssociation? {
        serviceAssociations.first { $0.serviceType == serviceType }
    }
}

/// Uses semantic evidence only to bound a source region. Numeric values, units,
/// ownership, and ambiguity are established independently from recognized text.
struct SemanticGuidedBillValueAssociator {
    private struct SourceLine: Equatable {
        let pageIndex: Int
        let sequenceIndex: Int
        let line: RecognizedDocumentLine
    }

    private struct Anchor: Equatable {
        let serviceType: UtilityServiceType
        let field: BillServiceFieldName
        let evidence: BillSemanticEvidence
    }

    private struct ParsedValue: Equatable {
        let value: BillProposedValue
        let unit: String?
    }

    private struct Match: Equatable {
        let anchor: Anchor
        let source: SourceLine
        let parsed: ParsedValue
        let tier: Int
        let distance: CGFloat
        let reason: SemanticGuidedAssociationReason
    }

    private enum GeometryRule {
        static let minimumRowOverlap: CGFloat = 0.5
        static let rowCenterTolerance: CGFloat = 0.025
        static let maximumRowGap: CGFloat = 0.35
        static let leadingTolerance: CGFloat = 0.02
        static let maximumAdjacentSequenceDistance = 2
        static let maximumAdjacentCenterDistance: CGFloat = 0.08
    }

    func associate(
        recognition: DocumentRecognitionResult,
        semantics: BillSemanticClassification
    ) -> SemanticGuidedAssociationResult {
        let lines = recognition.pages.flatMap { page in
            page.lines.enumerated().map {
                SourceLine(pageIndex: page.pageIndex, sequenceIndex: $0.offset, line: $0.element)
            }
        }
        let anchors = semanticAnchors(from: semantics, lines: lines)
        let matches = candidateMatches(lines: lines, anchors: anchors)
        let owned = uniquelyOwned(matches)

        let associations: [SemanticGuidedServiceAssociation] = [
            UtilityServiceType.electricity, .naturalGas,
        ].compactMap { service -> SemanticGuidedServiceAssociation? in
            let serviceMatches = owned.filter { $0.anchor.serviceType == service }
            var proposals: [BillServiceFieldProposal] = []
            var reasons: [BillServiceFieldName: SemanticGuidedAssociationReason] = [:]

            if let usage = uniqueMatch(serviceMatches, field: .usageQuantity),
               let unit = usage.parsed.unit {
                proposals.append(proposal(.usageQuantity, usage.parsed.value, usage))
                proposals.append(proposal(.usageUnit, .text(unit), usage))
                reasons[.usageQuantity] = usage.reason
                reasons[.usageUnit] = usage.reason
            }
            if let charges = uniqueMatch(serviceMatches, field: .currentPeriodCharges) {
                proposals.append(proposal(.currentPeriodCharges, charges.parsed.value, charges))
                reasons[.currentPeriodCharges] = charges.reason
            }
            guard !proposals.isEmpty else { return nil }
            return SemanticGuidedServiceAssociation(
                serviceType: service,
                proposals: proposals,
                reasons: reasons
            )
        }
        return SemanticGuidedAssociationResult(serviceAssociations: associations)
    }

    private func semanticAnchors(
        from semantics: BillSemanticClassification,
        lines: [SourceLine]
    ) -> [Anchor] {
        var anchors: [Anchor] = []
        func append(
            concept: BillSemanticConcept,
            service: UtilityServiceType,
            field: BillServiceFieldName
        ) {
            guard let candidate = semantics.candidate(for: concept) else { return }
            anchors += candidate.supportingEvidence.map {
                Anchor(serviceType: service, field: field, evidence: $0)
            }
        }
        append(concept: .electricityUsage, service: .electricity, field: .usageQuantity)
        append(concept: .naturalGasUsage, service: .naturalGas, field: .usageQuantity)
        anchors += explicitStructuralAnchors(semantics: semantics, lines: lines)

        if let charges = semantics.candidate(for: .currentCharges) {
            for evidence in charges.supportingEvidence {
                let owners = nearbyServices(for: evidence, semantics: semantics)
                if owners.count == 1, let service = owners.first {
                    anchors.append(Anchor(
                        serviceType: service,
                        field: .currentPeriodCharges,
                        evidence: evidence
                    ))
                }
            }
        }
        for (concept, service) in [
            (BillSemanticConcept.electricityService, UtilityServiceType.electricity),
            (.naturalGasService, .naturalGas),
        ] {
            guard let candidate = semantics.candidate(for: concept) else { continue }
            for evidence in candidate.supportingEvidence
            where normalized(evidence.sourceText).contains("current charges") {
                anchors.append(Anchor(
                    serviceType: service,
                    field: .currentPeriodCharges,
                    evidence: evidence
                ))
            }
        }
        return anchors.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    /// Semantic evidence gates which service concepts are available, while an
    /// explicit provider-neutral label on another page establishes the actual
    /// bounded source region. Values are still parsed only from that local row.
    private func explicitStructuralAnchors(
        semantics: BillSemanticClassification,
        lines: [SourceLine]
    ) -> [Anchor] {
        let electricitySupported = semantics.candidate(for: .electricityUsage) != nil
            || semantics.candidate(for: .electricityService) != nil
        let gasSupported = semantics.candidate(for: .naturalGasUsage) != nil
            || semantics.candidate(for: .naturalGasService) != nil
        var anchors: [Anchor] = []

        for source in lines where !isNonCurrentUsageContext(source.line.text) {
            let text = normalized(source.line.text)
            let evidence = semanticEvidence(for: source)
            if text.range(
                of: #"^(?:total|current)\s+(?:electric(?:ity)?\s+)?usage\b|^usage\s+this\s+period\b"#,
                options: .regularExpression
            ) != nil, electricitySupported {
                anchors.append(Anchor(
                    serviceType: .electricity,
                    field: .usageQuantity,
                    evidence: evidence
                ))
            }
            if text.range(
                of: #"^(?:total|current)\s+(?:(?:natural\s+gas|gas)\s+)?usage\b|^(?:natural\s+gas|gas)\s+usage(?:\s+this\s+period)?\b"#,
                options: .regularExpression
            ) != nil, gasSupported {
                anchors.append(Anchor(
                    serviceType: .naturalGas,
                    field: .usageQuantity,
                    evidence: evidence
                ))
            }
            if electricitySupported,
               text.range(
                   of: #"^(?:current|total)\s+electric(?:ity)?\s+charges\b"#,
                   options: .regularExpression
               ) != nil {
                anchors.append(Anchor(
                    serviceType: .electricity,
                    field: .currentPeriodCharges,
                    evidence: evidence
                ))
            }
            if gasSupported,
               text.range(
                   of: #"^(?:current|total)\s+(?:natural\s+gas|gas)\s+charges\b"#,
                   options: .regularExpression
               ) != nil {
                anchors.append(Anchor(
                    serviceType: .naturalGas,
                    field: .currentPeriodCharges,
                    evidence: evidence
                ))
            }
        }
        return anchors
    }

    private func semanticEvidence(for source: SourceLine) -> BillSemanticEvidence {
        BillSemanticEvidence(
            pageIndex: source.pageIndex,
            sequenceIndex: source.sequenceIndex,
            sourceText: source.line.text,
            region: BillEvidenceRegion(normalizedBoundingBox: source.line.normalizedBoundingBox)
        )
    }

    private func nearbyServices(
        for evidence: BillSemanticEvidence,
        semantics: BillSemanticClassification
    ) -> Set<UtilityServiceType> {
        let serviceConcepts: [(BillSemanticConcept, UtilityServiceType)] = [
            (.electricityService, .electricity),
            (.naturalGasService, .naturalGas),
        ]
        return serviceConcepts.reduce(into: Set<UtilityServiceType>()) { result, pair in
            guard let candidate = semantics.candidate(for: pair.0) else { return }
            if candidate.supportingEvidence.contains(where: {
                $0.pageIndex == evidence.pageIndex
                    && sequenceDistance($0.sequenceIndex, evidence.sequenceIndex) <= 3
            }) {
                result.insert(pair.1)
            }
        }
    }

    private func candidateMatches(lines: [SourceLine], anchors: [Anchor]) -> [Match] {
        anchors.flatMap { anchor in
            lines.compactMap { source in
                guard source.pageIndex == anchor.evidence.pageIndex,
                      let parsed = parsedValue(in: source.line.text, for: anchor),
                      let association = association(anchor: anchor, source: source) else {
                    return nil
                }
                return Match(
                    anchor: anchor,
                    source: source,
                    parsed: parsed,
                    tier: association.tier,
                    distance: association.distance,
                    reason: association.reason
                )
            }
        }
    }

    private func parsedValue(in text: String, for anchor: Anchor) -> ParsedValue? {
        switch anchor.field {
        case .usageQuantity:
            guard !isNonCurrentUsageContext(text) else { return nil }
            let unitPattern: String
            let canonicalUnit: (String) -> String
            switch anchor.serviceType {
            case .electricity:
                unitPattern = "kwh"
                canonicalUnit = { _ in "kWh" }
            case .naturalGas:
                unitPattern = "therms?|dth"
                canonicalUnit = { $0.lowercased() == "dth" ? "DTH" : "therms" }
            default:
                return nil
            }
            let pattern = #"(?<![\w.])([+-]?[0-9]+(?:,[0-9]{3})*(?:\.[0-9]+)?)\s*("#
                + unitPattern + #")\b"#
            guard let match = firstMatch(pattern, in: text),
                  match.numberOfRanges == 3,
                  let quantityText = substring(text, range: match.range(at: 1)),
                  let unitText = substring(text, range: match.range(at: 2)),
                  let quantity = Decimal(string: quantityText.replacingOccurrences(of: ",", with: ""))
            else { return nil }
            return ParsedValue(value: .decimal(quantity), unit: canonicalUnit(unitText))
        case .currentPeriodCharges:
            let normalizedText = normalized(text)
            guard !normalizedText.contains("amount due"),
                  !normalizedText.contains("tax"),
                  !normalizedText.contains("fee"),
                  !normalizedText.contains("surcharge") else { return nil }
            let labeled = normalizedText.contains("current charges")
                || normalizedText.range(
                    of: #"\btotal\s+(?:electric(?:ity)?|natural\s+gas|gas)\s+charges\b"#,
                    options: .regularExpression
                ) != nil
            let pattern = labeled
                ? #"\$\s*([0-9]+(?:,[0-9]{3})*\.\d{2})\b"#
                : #"^\s*\$\s*([0-9]+(?:,[0-9]{3})*\.\d{2})\s*$"#
            guard let match = firstMatch(pattern, in: text),
                  let amountText = substring(text, range: match.range(at: 1)),
                  let amount = Decimal(string: amountText.replacingOccurrences(of: ",", with: ""))
            else { return nil }
            return ParsedValue(value: .decimal(amount), unit: nil)
        default:
            return nil
        }
    }

    private func association(
        anchor: Anchor,
        source: SourceLine
    ) -> (tier: Int, distance: CGFloat, reason: SemanticGuidedAssociationReason)? {
        if anchor.evidence.sequenceIndex == source.sequenceIndex {
            return (0, 0, .sameLine)
        }
        guard let anchorBox = anchor.evidence.region?.normalizedBoundingBox else { return nil }
        let valueBox = source.line.normalizedBoundingBox
        let overlap = verticalOverlap(anchorBox, valueBox)
        let rowCenterDistance = abs(anchorBox.midY - valueBox.midY)
        let horizontalGap = max(0, valueBox.minX - anchorBox.maxX)
        if valueBox.midX >= anchorBox.midX - GeometryRule.leadingTolerance,
           horizontalGap <= GeometryRule.maximumRowGap,
           overlap >= GeometryRule.minimumRowOverlap
                || rowCenterDistance <= GeometryRule.rowCenterTolerance {
            return (0, horizontalGap, .sameRow)
        }
        guard sequenceDistance(anchor.evidence.sequenceIndex, source.sequenceIndex)
                <= GeometryRule.maximumAdjacentSequenceDistance,
              abs(anchorBox.midY - valueBox.midY) <= GeometryRule.maximumAdjacentCenterDistance
        else { return nil }
        return (
            1,
            abs(anchorBox.midY - valueBox.midY),
            .adjacentInSemanticRegion
        )
    }

    /// A source observation belongs only to its unique best service/field anchor.
    /// Equal best ownership across services is a conflict and is discarded.
    private func uniquelyOwned(_ matches: [Match]) -> [Match] {
        Dictionary(grouping: matches) {
            "\($0.source.pageIndex):\($0.source.sequenceIndex):\($0.anchor.field.rawValue)"
        }.values.flatMap { group -> [Match] in
            let ranked = group.sorted {
                ($0.tier, $0.distance) < ($1.tier, $1.distance)
            }
            guard let best = ranked.first else { return [] }
            let tied = ranked.filter {
                $0.tier == best.tier && abs($0.distance - best.distance) < 0.001
            }
            guard Set(tied.map(\.anchor.serviceType)).count == 1 else { return [] }
            return [best]
        }
    }

    private func uniqueMatch(
        _ matches: [Match],
        field: BillServiceFieldName
    ) -> Match? {
        let candidates = matches.filter { $0.anchor.field == field }
        guard let bestTier = candidates.map(\.tier).min() else { return nil }
        let best = candidates.filter { $0.tier == bestTier }
        let values = Set(best.map { String(describing: $0.parsed.value) })
        guard values.count == 1 else { return nil }
        return best.min { $0.distance < $1.distance }
    }

    private func proposal(
        _ field: BillServiceFieldName,
        _ value: BillProposedValue,
        _ match: Match
    ) -> BillServiceFieldProposal {
        let label = match.anchor.evidence.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let valueText = match.source.line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let snippet = label == valueText ? valueText : "\(label) · \(valueText)"
        return BillServiceFieldProposal(
            field: field,
            value: value,
            provenance: BillSourceProvenance(
                pageIndex: match.source.pageIndex,
                snippet: snippet,
                normalizedBoundingBox: match.source.line.normalizedBoundingBox,
                sequenceIndex: match.source.sequenceIndex
            ),
            origin: .extracted
        )
    }

    private func firstMatch(_ pattern: String, in text: String) -> NSTextCheckingResult? {
        try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            .firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private func substring(_ text: String, range: NSRange) -> String? {
        Range(range, in: text).map { String(text[$0]) }
    }

    private func normalized(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func isNonCurrentUsageContext(_ text: String) -> Bool {
        normalized(text).range(
            of: #"\b(?:previous|prior|historical|history|average|daily|comparison|last\s+(?:month|period|year)|meter\s+(?:read|reading))\b"#,
            options: .regularExpression
        ) != nil
    }

    private func sequenceDistance(_ lhs: Int?, _ rhs: Int?) -> Int {
        guard let lhs, let rhs else { return .max }
        return abs(lhs - rhs)
    }

    private func verticalOverlap(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, min(lhs.height, rhs.height) > 0 else { return 0 }
        return intersection.height / min(lhs.height, rhs.height)
    }
}
