import Foundation
import NaturalLanguage

struct NormalizedBillLanguage: Sendable, Equatable {
    let text: String
    let tokens: Set<String>
}

struct BillLanguageNormalizer {
    func normalize(_ source: String) -> NormalizedBillLanguage {
        let compatible = source.precomposedStringWithCompatibilityMapping.lowercased()
        let separated = compatible.replacingOccurrences(
            of: #"[^\p{L}\p{N}+\-$]+"#,
            with: " ",
            options: .regularExpression
        )
        let collapsed = separated.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let defragmented = joinFragmentedLetters(in: collapsed)
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = defragmented
        var tokens = Set<String>()
        tokenizer.enumerateTokens(in: defragmented.startIndex..<defragmented.endIndex) {
            range, _ in
            tokens.insert(String(defragmented[range]))
            return true
        }

        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = defragmented
        tagger.enumerateTags(
            in: defragmented.startIndex..<defragmented.endIndex,
            unit: .word,
            scheme: .lemma,
            options: [.omitWhitespace, .omitPunctuation]
        ) { tag, _ in
            if let lemma = tag?.rawValue.lowercased(), !lemma.isEmpty {
                tokens.insert(lemma)
            }
            return true
        }
        return NormalizedBillLanguage(text: defragmented, tokens: tokens)
    }

    private func joinFragmentedLetters(in text: String) -> String {
        let parts = text.split(separator: " ").map(String.init)
        var result: [String] = []
        var fragments: [String] = []
        func flush() {
            if fragments.count >= 4 {
                result.append(fragments.joined())
            } else {
                result.append(contentsOf: fragments)
            }
            fragments.removeAll(keepingCapacity: true)
        }
        for part in parts {
            if part.count == 1, part.first?.isLetter == true {
                fragments.append(part)
            } else {
                flush()
                result.append(part)
            }
        }
        flush()
        return result.joined(separator: " ")
    }
}

protocol BillSemanticSimilarityProviding {
    func distance(between source: String, and canonicalDescription: String) -> Double?
}

/// Uses Apple's system-provided English sentence embedding. The embedding and
/// comparison operate locally; absence of the model produces semantic abstention.
struct AppleLocalBillSemanticSimilarity: BillSemanticSimilarityProviding {
    private let embedding = NLEmbedding.sentenceEmbedding(for: .english)

    func distance(between source: String, and canonicalDescription: String) -> Double? {
        guard let embedding,
              embedding.vector(for: source) != nil,
              embedding.vector(for: canonicalDescription) != nil else { return nil }
        return embedding.distance(
            between: source,
            and: canonicalDescription,
            distanceType: .cosine
        )
    }
}

struct HybridBillSemanticClassifier: BillSemanticClassifying {
    private struct ScoredConcept {
        let concept: BillSemanticConcept
        let score: Int
    }

    private struct CanonicalDescription {
        let concept: BillSemanticConcept
        let text: String
    }

    private let deterministic: DeterministicBillSemanticClassifier
    private let normalizer: BillLanguageNormalizer
    private let similarity: any BillSemanticSimilarityProviding

    init(
        deterministic: DeterministicBillSemanticClassifier = .init(),
        normalizer: BillLanguageNormalizer = .init(),
        similarity: any BillSemanticSimilarityProviding = AppleLocalBillSemanticSimilarity()
    ) {
        self.deterministic = deterministic
        self.normalizer = normalizer
        self.similarity = similarity
    }

    func classify(_ evidence: [BillSemanticEvidence]) -> BillSemanticClassification {
        let eligibleEvidence = evidenceExcludingNonBillingContexts(evidence)
        let direct = deterministic.classify(eligibleEvidence)
        var additions: [BillSemanticCandidate] = []
        for item in eligibleEvidence {
            let normalized = normalizer.normalize(item.sourceText)
            let scored = scoredConcepts(for: normalized)
            additions += scored.compactMap { scoredConcept in
                guard scoredConcept.score >= 2 else { return nil }
                return candidate(
                    scoredConcept.concept,
                    confidence: scoredConcept.score >= 4 ? .strong : .moderate,
                    evidence: item,
                    reason: .normalizedConceptEvidence
                )
            }
            if scored.isEmpty,
               isSimilarityEligible(normalized),
               let similar = similarityConcept(for: normalized.text) {
                additions.append(candidate(
                    similar,
                    confidence: .moderate,
                    evidence: item,
                    reason: .semanticSimilarity
                ))
            }
        }
        return merged(direct.candidates + additions)
    }

    /// Removes clearly non-billing sections before either composed classifier
    /// can treat their vocabulary as current-bill evidence. A direct current
    /// billing marker ends inherited explanatory context on the same page.
    private func evidenceExcludingNonBillingContexts(
        _ evidence: [BillSemanticEvidence]
    ) -> [BillSemanticEvidence] {
        var excludedContextPages = Set<Int>()
        var result: [BillSemanticEvidence] = []

        for item in evidence {
            let normalized = normalizer.normalize(item.sourceText)
            if beginsExcludedContext(normalized) {
                excludedContextPages.insert(item.pageIndex)
                continue
            }
            if isExcluded(item.sourceText) {
                continue
            }
            if isDirectCurrentBillEvidence(normalized) {
                excludedContextPages.remove(item.pageIndex)
            }
            guard !excludedContextPages.contains(item.pageIndex) else { continue }
            result.append(item)
        }
        return result
    }

    private func beginsExcludedContext(_ language: NormalizedBillLanguage) -> Bool {
        let text = language.text
        return text.range(
            of: #"\bunderstanding\s+(?:your|the)\s+(?:electricity|electric|gas|utility)?\s*bill\b|\b(?:glossary|definitions?)\b|\b(?:what\s+(?:does|is)|this\s+means|the\s+term)\b|\bpayment\s+(?:help|assistance|options?)\b|\b(?:customer\s+service|need\s+help|contact\s+us)\b|\benergy[\s-]+efficien(?:cy|t)\b|\b(?:emergenc(?:y|ies)|outage|safety)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private func isDirectCurrentBillEvidence(_ language: NormalizedBillLanguage) -> Bool {
        let text = language.text
        return text.range(
            of: #"^(?:your\s+(?:electricity|electric|gas)\s+bill|(?:electric|electricity|natural\s+gas|residential\s+gas)\s+service|current\s+charges\s*-?\s*(?:electric|electricity|gas)\s+service|(?:your\s+)?(?:electricity|electric|gas)\s+breakdown|(?:electric|gas)\s+meter\s+detail|supply|delivery|distribution|taxes\s+fees\s+(?:and\s+)?other\s+credits)$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private func scoredConcepts(for language: NormalizedBillLanguage) -> [ScoredConcept] {
        let tokens = language.tokens
        let electricity = tokens.contains("electric") || tokens.contains("electricity")
        let gas = tokens.contains("gas")
        let gasUnit = !tokens.isDisjoint(with: ["therm", "therms", "dth"])
        let contextual = !tokens.isDisjoint(with: [
            "bill", "service", "charge", "charges", "breakdown", "meter", "detail", "usage", "cost",
        ])
        var scores: [BillSemanticConcept: Int] = [:]
        func add(_ concept: BillSemanticConcept, _ score: Int) {
            scores[concept] = max(scores[concept] ?? 0, score)
        }

        // A line naming both incompatible services without distinct structure
        // is deliberately ambiguous and establishes neither service identity.
        if electricity != gas {
            if electricity, contextual { add(.electricityService, 4) }
            if gas, contextual { add(.naturalGasService, 4) }
        }
        if tokens.contains("usage") || tokens.contains("consumption") {
            if electricity || tokens.contains("kwh") {
                add(.electricityUsage, 4)
                add(.currentUsage, 3)
            } else if gas || gasUnit {
                add(.naturalGasUsage, 4)
                add(.currentUsage, 3)
            }
        }
        if tokens.contains("meter") && !tokens.isDisjoint(with: ["detail", "details", "information", "reading"]) {
            add(.meterInformation, 4)
        }
        if tokens.contains("supply") && !tokens.isDisjoint(with: ["charge", "charges", "summary", "section"]) {
            add(.supplyCharges, 4)
        }
        if !tokens.isDisjoint(with: ["delivery", "distribution"])
            && !tokens.isDisjoint(with: ["charge", "charges", "summary", "section"]) {
            add(.deliveryCharges, 4)
        }
        if tokens.contains("taxes") && (tokens.contains("fees") || tokens.contains("credits")) {
            add(.taxesFeesAndOtherCredits, 4)
        }
        if tokens.contains("service") && tokens.contains("from") && tokens.contains("through") {
            add(.billingPeriod, 4)
        }
        if tokens.contains("budget") && tokens.contains("billing") {
            add(.budgetBilling, 4)
        }
        return scores.map { ScoredConcept(concept: $0.key, score: $0.value) }
    }

    private func similarityConcept(for source: String) -> BillSemanticConcept? {
        let descriptions = [
            CanonicalDescription(concept: .electricityService, text: "electricity service bill"),
            CanonicalDescription(concept: .naturalGasService, text: "natural gas service bill"),
            CanonicalDescription(concept: .currentUsage, text: "current utility usage consumption"),
            CanonicalDescription(concept: .supplyCharges, text: "energy supply charges section"),
            CanonicalDescription(concept: .deliveryCharges, text: "utility delivery distribution charges"),
            CanonicalDescription(concept: .meterInformation, text: "utility meter information details"),
            CanonicalDescription(concept: .billingPeriod, text: "utility service billing period"),
            CanonicalDescription(concept: .taxesFeesAndOtherCredits, text: "taxes fees and other credits"),
            CanonicalDescription(concept: .energySupplier, text: "company supplying energy"),
            CanonicalDescription(concept: .deliveryUtility, text: "utility delivering electricity"),
        ]
        let ranked = descriptions.compactMap { description -> (BillSemanticConcept, Double)? in
            similarity.distance(between: source, and: description.text).map {
                (description.concept, $0)
            }
        }.sorted { $0.1 < $1.1 }
        guard let best = ranked.first,
              best.1 <= 0.30,
              ranked.count == 1 || ranked[1].1 - best.1 >= 0.08 else { return nil }
        return best.0
    }

    private func isSimilarityEligible(_ language: NormalizedBillLanguage) -> Bool {
        let anchors: Set<String> = [
            "service", "bill", "charge", "charges", "usage", "consumption", "meter",
            "supply", "delivery", "distribution", "taxes", "fees", "credits", "period",
            "electric", "electricity", "gas",
        ]
        return language.tokens.intersection(anchors).count >= 2
    }

    private func isExcluded(_ text: String) -> Bool {
        text.range(
            of: #"\b(?:emergenc(?:y|ies)|outage|safety|customer[\s-]+service|telephone|phone|contact|call|payment\s+(?:help|assistance)|energy[\s-]+efficien(?:cy|t)|tips?|advice|means|definition|defined|glossary|explanatory|solar\s+choice|renewable|green[\s-]+energy)\b|\bfor\s+example\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private func candidate(
        _ concept: BillSemanticConcept,
        confidence: BillSemanticConfidence,
        evidence: BillSemanticEvidence,
        reason: BillSemanticReason
    ) -> BillSemanticCandidate {
        BillSemanticCandidate(
            concept: concept,
            confidence: confidence,
            supportingEvidence: [evidence],
            reasons: [reason]
        )
    }

    private func merged(_ candidates: [BillSemanticCandidate]) -> BillSemanticClassification {
        var candidates = candidates
        let specificUsage = Set(candidates.map(\.concept)).intersection([
            .electricityUsage, .naturalGasUsage, .waterUsage, .wastewaterUsage,
        ])
        if specificUsage.count > 1 {
            candidates.removeAll { $0.concept == .currentUsage }
        }
        let concepts = candidates.map(\.concept).reduce(into: [BillSemanticConcept]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        let merged = concepts.map { concept in
            let matches = candidates.filter { $0.concept == concept }
            var reasons = matches.flatMap(\.reasons).reduce(into: [BillSemanticReason]()) {
                if !$0.contains($1) { $0.append($1) }
            }
            if reasons.count > 1, !reasons.contains(.hybridCorroboration) {
                reasons.append(.hybridCorroboration)
            }
            let evidence = matches.flatMap(\.supportingEvidence).reduce(
                into: [BillSemanticEvidence]()
            ) {
                if !$0.contains($1) { $0.append($1) }
            }
            return BillSemanticCandidate(
                concept: concept,
                confidence: matches.map(\.confidence).max() ?? .weak,
                supportingEvidence: evidence,
                reasons: reasons
            )
        }
        let evidence = merged.flatMap(\.supportingEvidence).reduce(
            into: [BillSemanticEvidence]()
        ) {
            if !$0.contains($1) { $0.append($1) }
        }
        return BillSemanticClassification(evidence: evidence, candidates: merged)
    }
}
