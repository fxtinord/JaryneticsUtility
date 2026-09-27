import CoreGraphics
import Foundation

/// Provider-neutral meanings that may be supported by recognized bill evidence.
/// These concepts classify source meaning only; they never carry trusted values.
enum BillSemanticConcept: String, CaseIterable, Sendable, Hashable {
    case statementIdentity
    case billIssuer
    case statementDate
    case dueDate
    case amountDue

    case electricityService
    case naturalGasService
    case waterService
    case wastewaterService

    case billingPeriod
    case currentUsage
    case electricityUsage
    case naturalGasUsage
    case waterUsage
    case wastewaterUsage
    case currentCharges

    case supplyCharges
    case deliveryCharges
    case distributionCharges
    case taxesFeesAndOtherCredits

    case energySupplier
    case deliveryUtility

    case meterInformation
    case meterReading

    case budgetBilling
    case paymentPlan

    case netMetering
    case netEnergy
    case generation
    case energyCreditBalance
    case settlementTrueUp
}

enum BillSemanticConfidence: Int, Sendable, Comparable {
    case weak
    case moderate
    case strong

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum BillSemanticReason: String, Sendable, Equatable {
    case explicitServiceLabel
    case serviceDescription
    case usageHeading
    case usageStatement
    case chargeSectionHeading
    case explicitProgramLabel
    case normalizedConceptEvidence
    case semanticSimilarity
    case hybridCorroboration
}

struct BillEvidenceRegion: Sendable, Equatable {
    let normalizedBoundingBox: CGRect
}

struct BillSemanticEvidence: Sendable, Equatable {
    let pageIndex: Int
    let sequenceIndex: Int?
    let sourceText: String
    let region: BillEvidenceRegion?
}

struct BillSemanticCandidate: Sendable, Equatable {
    let concept: BillSemanticConcept
    let confidence: BillSemanticConfidence
    let supportingEvidence: [BillSemanticEvidence]
    let reasons: [BillSemanticReason]
}

struct BillSemanticClassification: Sendable, Equatable {
    let evidence: [BillSemanticEvidence]
    let candidates: [BillSemanticCandidate]

    func candidate(for concept: BillSemanticConcept) -> BillSemanticCandidate? {
        candidates.first { $0.concept == concept }
    }
}

protocol BillSemanticClassifying {
    func classify(_ evidence: [BillSemanticEvidence]) -> BillSemanticClassification
}

extension BillSemanticClassifying {
    func classify(_ recognition: DocumentRecognitionResult) -> BillSemanticClassification {
        classify(BillSemanticEvidenceAdapter().evidence(from: recognition))
    }
}

/// Converts recognition output into transient semantic evidence without adding
/// interpretation, trusted values, persistence, or provider knowledge.
struct BillSemanticEvidenceAdapter {
    func evidence(from recognition: DocumentRecognitionResult) -> [BillSemanticEvidence] {
        recognition.pages.flatMap { page in
            page.lines.enumerated().map { sequenceIndex, line in
                BillSemanticEvidence(
                    pageIndex: page.pageIndex,
                    sequenceIndex: sequenceIndex,
                    sourceText: line.text,
                    region: BillEvidenceRegion(
                        normalizedBoundingBox: line.normalizedBoundingBox
                    )
                )
            }
        }
    }
}

/// A deliberately small deterministic baseline proving that multiple source
/// phrasings can map to provider-neutral meaning before value extraction.
struct DeterministicBillSemanticClassifier: BillSemanticClassifying {
    private struct Contribution {
        let concept: BillSemanticConcept
        let confidence: BillSemanticConfidence
        let evidence: BillSemanticEvidence
        let reason: BillSemanticReason
    }

    func classify(_ evidence: [BillSemanticEvidence]) -> BillSemanticClassification {
        var contributions = evidence.flatMap(classify)
        contributions += groupedRoleContributions(in: evidence)
        let concepts = contributions.map(\.concept).reduce(into: [BillSemanticConcept]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        let candidates = concepts.map { concept in
            let matches = contributions.filter { $0.concept == concept }
            let supportingEvidence = matches.map(\.evidence).reduce(
                into: [BillSemanticEvidence]()
            ) {
                if !$0.contains($1) { $0.append($1) }
            }
            let reasons = matches.map(\.reason).reduce(into: [BillSemanticReason]()) {
                if !$0.contains($1) { $0.append($1) }
            }
            return BillSemanticCandidate(
                concept: concept,
                confidence: matches.map(\.confidence).max() ?? .weak,
                supportingEvidence: supportingEvidence,
                reasons: reasons
            )
        }
        let supportingEvidence = contributions.map(\.evidence).reduce(
            into: [BillSemanticEvidence]()
        ) {
            if !$0.contains($1) { $0.append($1) }
        }
        return BillSemanticClassification(
            evidence: supportingEvidence,
            candidates: candidates
        )
    }

    private func classify(_ evidence: BillSemanticEvidence) -> [Contribution] {
        let text = evidence.sourceText
        guard !matches(
            #"\b(?:emergenc(?:y|ies)|outage|safety|customer[\s-]+service|telephone|phone|contact|call|means|definition|defined|glossary|explanatory)\b|\bfor\s+example\b"#,
            in: text
        ) else {
            return []
        }

        var result: [Contribution] = []
        func add(
            _ concept: BillSemanticConcept,
            _ confidence: BillSemanticConfidence,
            _ reason: BillSemanticReason
        ) {
            result.append(Contribution(
                concept: concept,
                confidence: confidence,
                evidence: evidence,
                reason: reason
            ))
        }

        if matches(#"^\s*(?:electric|electricity)\s+service\b"#, in: text) {
            add(.electricityService, .strong, .explicitServiceLabel)
        }
        if matches(#"\bdelivers\s+electricity\s+to\s+(?:your|the|a)\s+home\b"#, in: text) {
            add(.electricityService, .strong, .serviceDescription)
            add(.deliveryUtility, .strong, .serviceDescription)
            add(.deliveryCharges, .strong, .serviceDescription)
        }
        if matches(#"^\s*total\s+usage\s*\(\s*kwh\s*\)\s*$"#, in: text) {
            add(.electricityUsage, .strong, .usageHeading)
            add(.currentUsage, .moderate, .usageHeading)
        }
        if matches(#"^\s*natural\s+gas\s+service\b"#, in: text) {
            add(.naturalGasService, .strong, .explicitServiceLabel)
        }
        if matches(#"^\s*gas\s+usage\s+this\s+period\b"#, in: text) {
            add(.naturalGasService, .moderate, .usageStatement)
            add(.naturalGasUsage, .strong, .usageStatement)
            add(.currentUsage, .moderate, .usageStatement)
        }
        if matches(#"^\s*water\s+service\b"#, in: text) {
            add(.waterService, .strong, .explicitServiceLabel)
        }
        if matches(#"^\s*wastewater\s+service\b"#, in: text) {
            add(.wastewaterService, .strong, .explicitServiceLabel)
        }
        if matches(#"^\s*supply\s*$"#, in: text) {
            add(.supplyCharges, .moderate, .chargeSectionHeading)
        }
        if matches(#"^\s*delivery\s*$"#, in: text) {
            add(.deliveryCharges, .moderate, .chargeSectionHeading)
        }
        if matches(#"^\s*distribution\s*$"#, in: text) {
            add(.distributionCharges, .strong, .chargeSectionHeading)
        }
        if matches(#"^\s*taxes\s*,\s*fees\s*&\s*other\s+credits\s*$"#, in: text) {
            add(.taxesFeesAndOtherCredits, .strong, .chargeSectionHeading)
        }
        if matches(#"\bprovides\s+(?:your\s+)?energy\b"#, in: text) {
            add(.energySupplier, .strong, .serviceDescription)
            add(.supplyCharges, .strong, .serviceDescription)
        }
        if matches(#"^\s*service\s+from\s+\S+\s+through\s+\S+\s*$"#, in: text) {
            add(.billingPeriod, .strong, .serviceDescription)
        }
        if matches(#"^\s*current\s+charges\s+summary\s*$"#, in: text) {
            add(.currentCharges, .strong, .chargeSectionHeading)
        }
        if matches(#"^\s*meter\s+information\s*$"#, in: text) {
            add(.meterInformation, .strong, .chargeSectionHeading)
        }
        if matches(#"^\s*budget\s+billing(?:\s+details)?\s*$"#, in: text) {
            add(.budgetBilling, .strong, .explicitProgramLabel)
        }
        if matches(#"^\s*(?:net\s+metered|net\s+metering|net\s+met(?:ering)?\s+cr(?:edit)?)\b"#, in: text) {
            add(.netMetering, .strong, .explicitProgramLabel)
        }
        return result
    }

    private func groupedRoleContributions(
        in evidence: [BillSemanticEvidence]
    ) -> [Contribution] {
        var result: [Contribution] = []
        for roleEvidence in evidence {
            let role: (heading: String, concepts: [BillSemanticConcept])?
            if matches(#"\bprovides\s+(?:your\s+)?energy\b"#, in: roleEvidence.sourceText) {
                role = ("supply", [.supplyCharges, .energySupplier])
            } else if matches(
                #"\bdelivers\s+electricity\s+to\s+(?:your|the|a)\s+home\b"#,
                in: roleEvidence.sourceText
            ) {
                role = ("delivery", [.deliveryCharges, .deliveryUtility])
            } else {
                role = nil
            }
            guard let role,
                  let roleSequence = roleEvidence.sequenceIndex,
                  let heading = evidence.last(where: {
                      $0.pageIndex == roleEvidence.pageIndex
                          && ($0.sequenceIndex ?? Int.min) < roleSequence
                          && roleSequence - ($0.sequenceIndex ?? roleSequence) <= 3
                          && matches(#"^\s*\#(role.heading)\s*$"#, in: $0.sourceText)
                  }) else { continue }
            for concept in role.concepts {
                result.append(Contribution(
                    concept: concept,
                    confidence: .strong,
                    evidence: heading,
                    reason: .chargeSectionHeading
                ))
            }
        }
        return result
    }

    private func matches(_ pattern: String, in text: String) -> Bool {
        text.range(
            of: pattern,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }
}
