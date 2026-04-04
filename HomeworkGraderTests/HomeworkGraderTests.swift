import XCTest
import SwiftData
@testable import HomeworkGrader

final class HomeworkGraderTests: XCTestCase {
    func testMasterPayloadDecodesExpectedQuestionCount() throws {
        let json = """
        {
          "assignment_title": "Quiz 1",
          "questions": [
            {
              "question_id": "q1",
              "display_label": "Question 1",
              "prompt_text": "2 + 2",
              "ideal_answer": "4",
              "grading_criteria": "Award full credit for 4.",
              "page_references": [1]
            },
            {
              "question_id": "q2",
              "display_label": "Question 2",
              "prompt_text": "State Newton's second law.",
              "ideal_answer": "F = ma.",
              "grading_criteria": "Require force, mass, and acceleration relationship.",
              "page_references": [1]
            }
          ]
        }
        """

        let payload = try JSONDecoder().decode(MasterExamPayload.self, from: Data(json.utf8))
        XCTAssertEqual(payload.questions.count, 2)
        XCTAssertEqual(payload.questions[0].questionId, "q1")
    }

    func testCSVExporterIncludesPerQuestionScores() throws {
        let container = try ModelContainer(
            for: GradingSession.self,
            QuestionRubric.self,
            StudentSubmission.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)

        let session = GradingSession(
            title: "Biology Test",
            answerModelID: "gpt-5.4",
            gradingModelID: "gpt-5.4-mini"
        )
        context.insert(session)

        let q1 = QuestionRubric(orderIndex: 0, questionID: "q1", displayLabel: "Q1", promptText: "Cell", idealAnswer: "Cell", gradingCriteria: "Name the organelle.", maxPoints: 2)
        let q2 = QuestionRubric(orderIndex: 1, questionID: "q2", displayLabel: "Q2", promptText: "DNA", idealAnswer: "DNA", gradingCriteria: "Define DNA.", maxPoints: 3)
        context.insert(q1)
        context.insert(q2)
        session.questions = [q1, q2]

        let submission = StudentSubmission(
            studentName: "Alex",
            overallNotes: "Good work",
            teacherReviewed: true,
            totalScore: 4,
            maxScore: 5
        )
        context.insert(submission)
        submission.setQuestionGrades([
            QuestionGradeRecord(questionID: "q1", displayLabel: "Q1", awardedPoints: 2, maxPoints: 2, isAnswerCorrect: true, isProcessCorrect: true, feedback: "Correct", needsReview: false),
            QuestionGradeRecord(questionID: "q2", displayLabel: "Q2", awardedPoints: 2, maxPoints: 3, isAnswerCorrect: false, isProcessCorrect: true, feedback: "Missing detail", needsReview: true),
        ])
        session.submissions = [submission]
        try context.save()

        let csv = CSVExporter.csvString(for: session)

        XCTAssertTrue(csv.contains("\"Alex\""))
        XCTAssertTrue(csv.contains("\"2/2\""))
        XCTAssertTrue(csv.contains("\"2/3\""))
    }

    func testSubmissionBatchOrganizerSplitsPagesIntoEqualGroups() throws {
        let pages = [
            Data([0x01]),
            Data([0x02]),
            Data([0x03]),
            Data([0x04]),
            Data([0x05]),
            Data([0x06]),
        ]

        let groups = try SubmissionBatchOrganizer.split(pages: pages, pagesPerSubmission: 2)

        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups[0], [Data([0x01]), Data([0x02])])
        XCTAssertEqual(groups[2], [Data([0x05]), Data([0x06])])
    }

    func testSubmissionBatchOrganizerRejectsUnevenPageCounts() {
        let pages = [
            Data([0x01]),
            Data([0x02]),
            Data([0x03]),
        ]

        XCTAssertThrowsError(try SubmissionBatchOrganizer.split(pages: pages, pagesPerSubmission: 2)) { error in
            XCTAssertEqual(
                error as? SubmissionBatchOrganizerError,
                .pageCountMismatch(totalPages: 3, pagesPerSubmission: 2)
            )
        }
    }
}
