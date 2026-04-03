import Foundation

struct RubricQuestionDraft: Identifiable, Hashable, Sendable {
    var id = UUID()
    var questionID: String
    var displayLabel: String
    var promptText: String
    var idealAnswer: String
    var gradingCriteria: String
    var maxPointsText: String
}

struct RubricReviewState: Identifiable, Sendable {
    var id = UUID()
    var pageData: [Data]
    var overallGradingRules: String
    var questionDrafts: [RubricQuestionDraft]
}

struct QuestionGradeRecord: Codable, Hashable, Identifiable, Sendable {
    var questionID: String
    var displayLabel: String
    var awardedPoints: Double
    var maxPoints: Double
    var isAnswerCorrect: Bool
    var isProcessCorrect: Bool
    var feedback: String
    var needsReview: Bool

    var id: String { questionID }
}

struct SubmissionDraft: Identifiable, Sendable {
    var id = UUID()
    var studentName: String
    var nameNeedsReview: Bool
    var overallNotes: String
    var grades: [QuestionGradeRecord]
    var pageData: [Data]

    var totalScore: Double {
        grades.reduce(0) { $0 + $1.awardedPoints }
    }

    var maxScore: Double {
        grades.reduce(0) { $0 + $1.maxPoints }
    }

    var requiresAttention: Bool {
        studentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || nameNeedsReview || grades.contains(where: \.needsReview)
    }

    var isPerfectScore: Bool {
        abs(totalScore - maxScore) < 0.001
    }
}

struct RubricSnapshot: Codable, Sendable {
    var questionID: String
    var displayLabel: String
    var promptText: String
    var idealAnswer: String
    var gradingCriteria: String
    var maxPoints: Double
}

enum PointPolicy {
    static func parse(_ text: String, integerOnly: Bool) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if integerOnly {
            guard let value = Int(trimmed), value > 0 else { return nil }
            return Double(value)
        }

        guard let value = Double(trimmed), value > 0 else { return nil }
        return value
    }

    static func step(integerOnly: Bool) -> Double {
        integerOnly ? 1 : 0.5
    }

    static func normalize(_ value: Double, maxPoints: Double? = nil, integerOnly: Bool) -> Double {
        let upperBound = maxPoints ?? value
        let clamped = min(max(value, 0), upperBound)
        return integerOnly ? clamped.rounded() : clamped
    }

    static func displayText(for value: Double, integerOnly: Bool) -> String {
        integerOnly ? String(Int(value.rounded())) : ScoreFormatting.scoreString(value)
    }
}

extension QuestionRubric {
    var snapshot: RubricSnapshot {
        RubricSnapshot(
            questionID: questionID,
            displayLabel: displayLabel,
            promptText: promptText,
            idealAnswer: idealAnswer,
            gradingCriteria: gradingCriteria,
            maxPoints: maxPoints
        )
    }
}

struct MasterExamPayload: Decodable, Sendable {
    let assignmentTitle: String
    let questions: [GeneratedQuestionPayload]

    enum CodingKeys: String, CodingKey {
        case assignmentTitle = "assignment_title"
        case questions
    }
}

struct GeneratedQuestionPayload: Decodable, Sendable {
    let questionId: String
    let displayLabel: String
    let promptText: String
    let idealAnswer: String
    let gradingCriteria: String
    let pageReferences: [Int]

    enum CodingKeys: String, CodingKey {
        case questionId = "question_id"
        case displayLabel = "display_label"
        case promptText = "prompt_text"
        case idealAnswer = "ideal_answer"
        case gradingCriteria = "grading_criteria"
        case pageReferences = "page_references"
    }
}

struct SubmissionPayload: Codable, Sendable {
    let studentName: String
    let studentNameNeedsReview: Bool
    let questionResults: [SubmissionQuestionPayload]
    let overallNotes: String

    enum CodingKeys: String, CodingKey {
        case studentName = "student_name"
        case studentNameNeedsReview = "student_name_needs_review"
        case questionResults = "question_results"
        case overallNotes = "overall_notes"
    }
}

struct SubmissionQuestionPayload: Codable, Sendable {
    let questionId: String
    let awardedPoints: Double
    let maxPoints: Double
    let isAnswerCorrect: Bool
    let isProcessCorrect: Bool
    let feedback: String
    let needsReview: Bool

    enum CodingKeys: String, CodingKey {
        case questionId = "question_id"
        case awardedPoints = "awarded_points"
        case maxPoints = "max_points"
        case isAnswerCorrect = "is_answer_correct"
        case isProcessCorrect = "is_process_correct"
        case feedback
        case needsReview = "needs_review"
    }
}

extension RubricReviewState {
    static func from(payload: MasterExamPayload, pageData: [Data], integerPointsOnly: Bool) -> RubricReviewState {
        let questionDrafts = payload.questions.enumerated().map { index, item in
            RubricQuestionDraft(
                questionID: item.questionId.isEmpty ? "q\(index + 1)" : item.questionId,
                displayLabel: item.displayLabel.isEmpty ? "Question \(index + 1)" : item.displayLabel,
                promptText: item.promptText,
                idealAnswer: item.idealAnswer,
                gradingCriteria: item.gradingCriteria,
                maxPointsText: integerPointsOnly ? "1" : "1"
            )
        }

        return RubricReviewState(
            pageData: pageData,
            overallGradingRules: "Apply the approved rubric consistently across all questions. Give partial credit when justified by the shown work, and mark uncertain cases for teacher review.",
            questionDrafts: questionDrafts
        )
    }

    func normalized(integerPointsOnly: Bool) -> RubricReviewState {
        guard integerPointsOnly else { return self }

        var copy = self
        copy.questionDrafts = copy.questionDrafts.map { draft in
            var adjusted = draft
            if let parsed = PointPolicy.parse(draft.maxPointsText, integerOnly: false) {
                adjusted.maxPointsText = PointPolicy.displayText(for: parsed, integerOnly: true)
            }
            return adjusted
        }
        return copy
    }
}

extension SubmissionDraft {
    static func fromStoredSubmission(_ submission: StudentSubmission) -> SubmissionDraft {
        SubmissionDraft(
            studentName: submission.studentName,
            nameNeedsReview: submission.nameNeedsReviewEnabled,
            overallNotes: submission.overallNotes,
            grades: submission.questionGrades(),
            pageData: submission.scans()
        )
    }

    static func from(payload: SubmissionPayload, rubric: [QuestionRubric], pageData: [Data], integerPointsOnly: Bool) -> SubmissionDraft {
        let payloadByQuestionID = Dictionary(uniqueKeysWithValues: payload.questionResults.map { ($0.questionId, $0) })

        let grades = rubric.map { question -> QuestionGradeRecord in
            if let result = payloadByQuestionID[question.questionID] {
                let normalizedAwardedPoints = PointPolicy.normalize(
                    result.awardedPoints,
                    maxPoints: question.maxPoints,
                    integerOnly: integerPointsOnly
                )

                return QuestionGradeRecord(
                    questionID: question.questionID,
                    displayLabel: question.displayLabel,
                    awardedPoints: normalizedAwardedPoints,
                    maxPoints: question.maxPoints,
                    isAnswerCorrect: result.isAnswerCorrect,
                    isProcessCorrect: result.isProcessCorrect,
                    feedback: result.feedback,
                    needsReview: result.needsReview ||
                        abs(result.maxPoints - question.maxPoints) > 0.001 ||
                        (integerPointsOnly && abs(result.awardedPoints.rounded() - result.awardedPoints) > 0.001)
                )
            }

            return QuestionGradeRecord(
                questionID: question.questionID,
                displayLabel: question.displayLabel,
                awardedPoints: 0,
                maxPoints: question.maxPoints,
                isAnswerCorrect: false,
                isProcessCorrect: false,
                feedback: "No model result was returned for this question. Teacher review is required.",
                needsReview: true
            )
        }

        return SubmissionDraft(
            studentName: payload.studentName.trimmingCharacters(in: .whitespacesAndNewlines),
            nameNeedsReview: payload.studentNameNeedsReview || payload.studentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            overallNotes: payload.overallNotes,
            grades: grades,
            pageData: pageData
        )
    }

    static func from(payload: SubmissionPayload, rubricSnapshots: [RubricSnapshot], pageData: [Data], integerPointsOnly: Bool) -> SubmissionDraft {
        let payloadByQuestionID = Dictionary(uniqueKeysWithValues: payload.questionResults.map { ($0.questionId, $0) })

        let grades = rubricSnapshots.map { question -> QuestionGradeRecord in
            if let result = payloadByQuestionID[question.questionID] {
                let normalizedAwardedPoints = PointPolicy.normalize(
                    result.awardedPoints,
                    maxPoints: question.maxPoints,
                    integerOnly: integerPointsOnly
                )

                return QuestionGradeRecord(
                    questionID: question.questionID,
                    displayLabel: question.displayLabel,
                    awardedPoints: normalizedAwardedPoints,
                    maxPoints: question.maxPoints,
                    isAnswerCorrect: result.isAnswerCorrect,
                    isProcessCorrect: result.isProcessCorrect,
                    feedback: result.feedback,
                    needsReview: result.needsReview ||
                        abs(result.maxPoints - question.maxPoints) > 0.001 ||
                        (integerPointsOnly && abs(result.awardedPoints.rounded() - result.awardedPoints) > 0.001)
                )
            }

            return QuestionGradeRecord(
                questionID: question.questionID,
                displayLabel: question.displayLabel,
                awardedPoints: 0,
                maxPoints: question.maxPoints,
                isAnswerCorrect: false,
                isProcessCorrect: false,
                feedback: "No model result was returned for this question. Teacher review is required.",
                needsReview: true
            )
        }

        return SubmissionDraft(
            studentName: payload.studentName.trimmingCharacters(in: .whitespacesAndNewlines),
            nameNeedsReview: payload.studentNameNeedsReview || payload.studentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            overallNotes: payload.overallNotes,
            grades: grades,
            pageData: pageData
        )
    }

    func normalized(integerPointsOnly: Bool) -> SubmissionDraft {
        guard integerPointsOnly else { return self }

        var copy = self
        copy.grades = copy.grades.map { grade in
            var adjusted = grade
            adjusted.maxPoints = PointPolicy.normalize(adjusted.maxPoints, integerOnly: true)
            adjusted.awardedPoints = PointPolicy.normalize(adjusted.awardedPoints, maxPoints: adjusted.maxPoints, integerOnly: true)
            return adjusted
        }
        return copy
    }
}

enum SubmissionBatchOrganizerError: LocalizedError, Equatable {
    case invalidPagesPerSubmission
    case emptyScan
    case pageCountMismatch(totalPages: Int, pagesPerSubmission: Int)

    var errorDescription: String? {
        switch self {
        case .invalidPagesPerSubmission:
            return "Enter a valid number of pages per submission before starting the batch scan."
        case .emptyScan:
            return "The batch scan did not contain any pages."
        case .pageCountMismatch(let totalPages, let pagesPerSubmission):
            return "The scan captured \(totalPages) pages, which cannot be split into groups of \(pagesPerSubmission). Rescan the stack so every submission has exactly \(pagesPerSubmission) pages."
        }
    }
}

enum SubmissionBatchOrganizer {
    static func split(pages: [Data], pagesPerSubmission: Int) throws -> [[Data]] {
        guard pagesPerSubmission > 0 else {
            throw SubmissionBatchOrganizerError.invalidPagesPerSubmission
        }

        guard !pages.isEmpty else {
            throw SubmissionBatchOrganizerError.emptyScan
        }

        guard pages.count % pagesPerSubmission == 0 else {
            throw SubmissionBatchOrganizerError.pageCountMismatch(
                totalPages: pages.count,
                pagesPerSubmission: pagesPerSubmission
            )
        }

        return stride(from: 0, to: pages.count, by: pagesPerSubmission).map { start in
            Array(pages[start..<(start + pagesPerSubmission)])
        }
    }
}
