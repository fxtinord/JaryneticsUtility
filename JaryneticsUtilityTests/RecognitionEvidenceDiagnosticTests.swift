import CoreGraphics
import Foundation
import Testing
@testable import JaryneticsUtility

@MainActor
struct RecognitionEvidenceDiagnosticTests {
    private let assembler = RecognitionEvidenceDiagnosticAssembler()

    @Test(arguments: ["Bill Date", "Statement Date", "Total Due", "Amount Due"])
    func discoversSupportedLabelCandidates(_ label: String) throws {
        let diagnostic = assembler.assemble(from: recognition(page(0, label, "value")))
        let window = try #require(diagnostic.candidateWindows.first)

        #expect(diagnostic.candidateWindows.count == 1)
        #expect(window.sequenceIndex == 0)
        #expect(window.observations.first?.text == label)
        #expect(window.observations.first?.role == .labelCandidate)
    }

    @Test(arguments: ["Bil Date", "Statemant Date", "Totai Due", "Amout Due"])
    func discoversModestlyCorruptedLabels(_ label: String) {
        let diagnostic = assembler.assemble(from: recognition(page(0, label)))
        #expect(diagnostic.candidateWindows.count == 1)
    }

    @Test func boundsPrecedingAndFollowingObservations() throws {
        let texts = (0..<12).map { $0 == 5 ? "Bill Date" : "Line \($0)" }
        let window = try #require(assembler.assemble(from: recognition(page(0, texts))).candidateWindows.first)

        #expect(window.observations.map(\.sequenceIndex) == Array(2...10))
        #expect(window.observations.count == 9)
    }

    @Test func candidateWindowDoesNotCrossPages() throws {
        let diagnostic = assembler.assemble(from: recognition(
            page(0, "Before", "Bill Date"),
            page(1, "June-03-2021", "After")
        ))
        let window = try #require(diagnostic.candidateWindows.first)

        #expect(window.observations.map(\.text) == ["Before", "Bill Date"])
        #expect(window.observations.allSatisfy { $0.pageIndex == 0 })
    }

    @Test func preservesOrderTextPageSequenceAndGeometry() throws {
        let firstBox = CGRect(x: 0.12, y: 0.83, width: 0.21, height: 0.031)
        let secondBox = CGRect(x: 0.52, y: 0.82, width: 0.17, height: 0.029)
        let result = DocumentRecognitionResult(pages: [
            RecognizedDocumentPage(pageIndex: 4, lines: [
                line("Total Due", box: firstBox),
                line("  $123.45 ", box: secondBox),
            ], warnings: []),
        ])
        let observations = try #require(
            assembler.assemble(from: result).candidateWindows.first
        ).observations

        #expect(observations.map(\.text) == ["Total Due", "  $123.45 "])
        #expect(observations.map(\.pageIndex) == [4, 4])
        #expect(observations.map(\.sequenceIndex) == [0, 1])
        #expect(observations.map(\.normalizedBoundingBox) == [firstBox, secondBox])
        #expect(observations.map(\.role) == [.labelCandidate, .possibleValue])
    }

    @Test func earlyPageFallbackUsesPhysicalPageZeroWhenAvailable() {
        let diagnostic = assembler.assemble(from: recognition(
            page(2, "Later page"),
            page(0, "First", "Second")
        ))

        #expect(diagnostic.earlyPageObservations.map(\.text) == ["First", "Second"])
        #expect(diagnostic.earlyPageObservations.map(\.sequenceIndex) == [0, 1])
        #expect(diagnostic.earlyPageObservations.allSatisfy { $0.role == .earlyPageObservation })
    }

    @Test func earlyPageFallbackIsBoundedToFortyObservations() {
        let diagnostic = assembler.assemble(from: recognition(page(0, (0..<55).map { "Line \($0)" })))
        #expect(diagnostic.earlyPageObservations.count == 40)
        #expect(diagnostic.earlyPageObservations.last?.sequenceIndex == 39)
    }

    @Test func noCandidateStillProvidesEarlyPageFallback() {
        let diagnostic = assembler.assemble(from: recognition(page(0, "Account", "Billing Summary")))
        #expect(diagnostic.candidateWindows.isEmpty)
        #expect(diagnostic.earlyPageObservations.map(\.text) == ["Account", "Billing Summary"])
    }

    @Test func oneObservationMatchingMultipleLabelsProducesOneWindow() {
        let diagnostic = assembler.assemble(from: recognition(page(0, "Bill Date Total Due")))
        #expect(diagnostic.candidateWindows.count == 1)
    }

    @Test func diagnosticProjectionDoesNotMutateRecognitionOrNormalizedOutputs() {
        let recognition = recognition(page(
            0,
            "Bill Date",
            "June-03-2021",
            "Total Due $123.45"
        ))
        let originalRecognition = recognition
        let extraction = BillFieldExtractor().extract(from: recognition)
        let guided = SemanticGuidedAssociationResult(serviceAssociations: [])
        let normalizedBefore = NormalizedBillRecordAssembler().assemble(
            recognition: recognition,
            extraction: extraction,
            semanticGuided: guided
        )
        let firstSummaryBefore = FirstBillSummaryAssembler().assemble(from: normalizedBefore)
        let comparisonBefore = NormalizedBillComparisonAssembler().assemble(
            normalizedBefore,
            normalizedBefore
        )
        let changeSummaryBefore = BillChangeSummaryAssembler().assemble(
            from: NormalizedBillChangeAssembler().assemble(from: comparisonBefore)
        )

        _ = assembler.assemble(from: recognition)

        let normalizedAfter = NormalizedBillRecordAssembler().assemble(
            recognition: recognition,
            extraction: extraction,
            semanticGuided: guided
        )
        let firstSummaryAfter = FirstBillSummaryAssembler().assemble(from: normalizedAfter)
        let comparisonAfter = NormalizedBillComparisonAssembler().assemble(
            normalizedAfter,
            normalizedAfter
        )
        let changeSummaryAfter = BillChangeSummaryAssembler().assemble(
            from: NormalizedBillChangeAssembler().assemble(from: comparisonAfter)
        )

        #expect(recognition == originalRecognition)
        #expect(normalizedAfter == normalizedBefore)
        #expect(firstSummaryAfter == firstSummaryBefore)
        #expect(changeSummaryAfter == changeSummaryBefore)
    }

    private func recognition(_ pages: RecognizedDocumentPage...) -> DocumentRecognitionResult {
        .init(pages: pages)
    }

    private func page(_ pageIndex: Int, _ texts: String...) -> RecognizedDocumentPage {
        page(pageIndex, texts)
    }

    private func page(_ pageIndex: Int, _ texts: [String]) -> RecognizedDocumentPage {
        .init(pageIndex: pageIndex, lines: texts.enumerated().map { index, text in
            line(
                text,
                box: CGRect(
                    x: 0.08,
                    y: 0.92 - CGFloat(index) * 0.04,
                    width: 0.50,
                    height: 0.03
                )
            )
        }, warnings: [])
    }

    private func line(_ text: String, box: CGRect) -> RecognizedDocumentLine {
        .init(text: text, normalizedBoundingBox: box)
    }
}
