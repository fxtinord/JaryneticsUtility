import CoreGraphics
import Foundation

#if DEBUG
enum RecognitionEvidenceDiagnosticRole: String, Sendable, Equatable {
    case labelCandidate = "Label candidate"
    case possibleValue = "Possible value"
    case neighbor = "Neighbor"
    case earlyPageObservation = "Early page observation"
}

struct RecognitionEvidenceDiagnosticObservation: Identifiable, Sendable, Equatable {
    struct ID: Hashable, Sendable {
        let pageIndex: Int
        let sequenceIndex: Int
        let role: RecognitionEvidenceDiagnosticRole
    }

    var id: ID { ID(pageIndex: pageIndex, sequenceIndex: sequenceIndex, role: role) }

    let pageIndex: Int
    let sequenceIndex: Int
    let text: String
    let normalizedBoundingBox: CGRect
    let role: RecognitionEvidenceDiagnosticRole
}

struct RecognitionEvidenceDiagnosticWindow: Identifiable, Sendable, Equatable {
    struct ID: Hashable, Sendable {
        let pageIndex: Int
        let sequenceIndex: Int
    }

    var id: ID { ID(pageIndex: pageIndex, sequenceIndex: sequenceIndex) }

    let pageIndex: Int
    let sequenceIndex: Int
    let observations: [RecognitionEvidenceDiagnosticObservation]
}

struct RecognitionEvidenceDiagnostic: Sendable, Equatable {
    let candidateWindows: [RecognitionEvidenceDiagnosticWindow]
    let earlyPageObservations: [RecognitionEvidenceDiagnosticObservation]
}

/// Builds a bounded, read-only view of OCR evidence for local Development inspection.
/// Diagnostic classifications never participate in bill extraction or normalization.
struct RecognitionEvidenceDiagnosticAssembler {
    static let precedingObservationLimit = 3
    static let followingObservationLimit = 5
    static let earlyPageObservationLimit = 40

    func assemble(from recognition: DocumentRecognitionResult) -> RecognitionEvidenceDiagnostic {
        let windows = recognition.pages.flatMap { page in
            page.lines.indices.compactMap { index -> RecognitionEvidenceDiagnosticWindow? in
                guard isCandidateLabel(page.lines[index].text) else { return nil }
                let lowerBound = max(page.lines.startIndex, index - Self.precedingObservationLimit)
                let upperBound = min(page.lines.index(before: page.lines.endIndex),
                                     index + Self.followingObservationLimit)
                let observations = (lowerBound...upperBound).map { observationIndex in
                    observation(
                        page: page,
                        index: observationIndex,
                        role: role(for: page.lines[observationIndex].text,
                                   isAnchor: observationIndex == index)
                    )
                }
                return RecognitionEvidenceDiagnosticWindow(
                    pageIndex: page.pageIndex,
                    sequenceIndex: index,
                    observations: observations
                )
            }
        }

        let firstPage = recognition.pages.first { $0.pageIndex == 0 }
            ?? recognition.pages.min { $0.pageIndex < $1.pageIndex }
        let early = firstPage.map { page in
            page.lines.prefix(Self.earlyPageObservationLimit).enumerated().map { index, line in
                RecognitionEvidenceDiagnosticObservation(
                    pageIndex: page.pageIndex,
                    sequenceIndex: index,
                    text: line.text,
                    normalizedBoundingBox: line.normalizedBoundingBox,
                    role: .earlyPageObservation
                )
            }
        } ?? []

        return RecognitionEvidenceDiagnostic(
            candidateWindows: windows,
            earlyPageObservations: early
        )
    }

    private func observation(
        page: RecognizedDocumentPage,
        index: Int,
        role: RecognitionEvidenceDiagnosticRole
    ) -> RecognitionEvidenceDiagnosticObservation {
        let line = page.lines[index]
        return RecognitionEvidenceDiagnosticObservation(
            pageIndex: page.pageIndex,
            sequenceIndex: index,
            text: line.text,
            normalizedBoundingBox: line.normalizedBoundingBox,
            role: role
        )
    }

    private func role(for text: String, isAnchor: Bool) -> RecognitionEvidenceDiagnosticRole {
        if isAnchor { return .labelCandidate }
        return containsPossibleValue(text) ? .possibleValue : .neighbor
    }

    private func isCandidateLabel(_ text: String) -> Bool {
        let tokens = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let compactCandidates = [tokens.joined()] + zip(tokens, tokens.dropFirst()).map { $0 + $1 }
        return compactCandidates.contains { candidate in
            diagnosticLabels.contains { label in
                let allowance = label.count >= 8 ? 2 : 1
                return abs(candidate.count - label.count) <= allowance
                    && editDistance(candidate, label, limit: allowance) <= allowance
            }
        }
    }

    private var diagnosticLabels: [String] {
        ["billdate", "statementdate", "totaldue", "amountdue"]
    }

    private func containsPossibleValue(_ text: String) -> Bool {
        let datePattern = #"\b(?:\d{1,2}/\d{1,2}/(?:\d{2}|\d{4})|(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)(?:\s+\d{1,2},\s+|-\d{1,2}-)\d{4})\b"#
        let moneyPattern = #"\$\s*[+-]?(?:\d{1,3}(?:,\d{3})*|\d+)\.\d{2}\b|[+-]?\$\s*(?:\d{1,3}(?:,\d{3})*|\d+)\.\d{2}\b"#
        return text.range(of: datePattern, options: [.regularExpression, .caseInsensitive]) != nil
            || text.range(of: moneyPattern, options: .regularExpression) != nil
    }

    private func editDistance(_ first: String, _ second: String, limit: Int) -> Int {
        let lhs = Array(first)
        let rhs = Array(second)
        guard abs(lhs.count - rhs.count) <= limit else { return limit + 1 }
        var previous = Array(0...rhs.count)
        for (row, left) in lhs.enumerated() {
            var current = [row + 1]
            for (column, right) in rhs.enumerated() {
                current.append(min(
                    current[column] + 1,
                    previous[column + 1] + 1,
                    previous[column] + (left == right ? 0 : 1)
                ))
            }
            previous = current
        }
        return previous[rhs.count]
    }
}
#endif
