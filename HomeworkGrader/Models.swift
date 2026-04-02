import Foundation
import SwiftData

enum ModelCatalog {
    static let suggestions = [
        "gpt-5.4",
        "gpt-5.4-mini",
        "gpt-5.4-nano",
        "gpt-5-mini",
        "gpt-4.1",
        "gpt-4.1-mini",
    ]

    static let defaultAnswerModel = "gpt-5.4"
    static let defaultGradingModel = "gpt-5.4-mini"
}

@Model
final class GradingSession {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var answerModelID: String
    var gradingModelID: String
    var estimatedCostUSD: Double?
    var apiKeyFingerprint: String?
    var integerPointsOnly: Bool?
    var isFinished: Bool
    var rubricApprovedAt: Date?
    @Attribute(.externalStorage) var masterScanArchive: Data?

    @Relationship(deleteRule: .cascade, inverse: \QuestionRubric.session)
    var questions: [QuestionRubric]

    @Relationship(deleteRule: .cascade, inverse: \StudentSubmission.session)
    var submissions: [StudentSubmission]

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = .now,
        answerModelID: String,
        gradingModelID: String,
        estimatedCostUSD: Double? = nil,
        apiKeyFingerprint: String? = nil,
        integerPointsOnly: Bool = false,
        isFinished: Bool = false,
        rubricApprovedAt: Date? = nil,
        masterScanArchive: Data? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.answerModelID = answerModelID
        self.gradingModelID = gradingModelID
        self.estimatedCostUSD = estimatedCostUSD
        self.apiKeyFingerprint = apiKeyFingerprint
        self.integerPointsOnly = integerPointsOnly
        self.isFinished = isFinished
        self.rubricApprovedAt = rubricApprovedAt
        self.masterScanArchive = masterScanArchive
        self.questions = []
        self.submissions = []
    }
}

@Model
final class QuestionRubric {
    @Attribute(.unique) var id: UUID
    var orderIndex: Int
    var questionID: String
    var displayLabel: String
    var promptText: String
    var idealAnswer: String
    var gradingCriteria: String
    var maxPoints: Double
    var session: GradingSession?

    init(
        id: UUID = UUID(),
        orderIndex: Int,
        questionID: String,
        displayLabel: String,
        promptText: String,
        idealAnswer: String,
        gradingCriteria: String,
        maxPoints: Double,
        session: GradingSession? = nil
    ) {
        self.id = id
        self.orderIndex = orderIndex
        self.questionID = questionID
        self.displayLabel = displayLabel
        self.promptText = promptText
        self.idealAnswer = idealAnswer
        self.gradingCriteria = gradingCriteria
        self.maxPoints = maxPoints
        self.session = session
    }
}

@Model
final class StudentSubmission {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var studentName: String
    var overallNotes: String
    var teacherReviewed: Bool
    var totalScore: Double
    var maxScore: Double
    var session: GradingSession?
    @Attribute(.externalStorage) var scanArchive: Data?
    @Attribute(.externalStorage) var gradeArchive: Data?

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        studentName: String,
        overallNotes: String,
        teacherReviewed: Bool,
        totalScore: Double,
        maxScore: Double,
        session: GradingSession? = nil,
        scanArchive: Data? = nil,
        gradeArchive: Data? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.studentName = studentName
        self.overallNotes = overallNotes
        self.teacherReviewed = teacherReviewed
        self.totalScore = totalScore
        self.maxScore = maxScore
        self.session = session
        self.scanArchive = scanArchive
        self.gradeArchive = gradeArchive
    }
}

extension GradingSession {
    var integerPointsOnlyEnabled: Bool {
        integerPointsOnly ?? false
    }

    var sortedQuestions: [QuestionRubric] {
        questions.sorted { lhs, rhs in
            lhs.orderIndex < rhs.orderIndex
        }
    }

    var sortedSubmissions: [StudentSubmission] {
        submissions.sorted { lhs, rhs in
            lhs.createdAt > rhs.createdAt
        }
    }

    var totalPossiblePoints: Double {
        sortedQuestions.reduce(0) { $0 + $1.maxPoints }
    }

    var pointModeLabel: String {
        integerPointsOnlyEnabled ? "Integers only" : "Fractional allowed"
    }

    var sessionCostLabel: String {
        CostFormatting.usdString(estimatedCostUSD)
    }

    func masterScans() -> [Data] {
        guard let masterScanArchive else { return [] }
        return (try? JSONDecoder().decode([Data].self, from: masterScanArchive)) ?? []
    }

    func setMasterScans(_ pages: [Data]) {
        masterScanArchive = try? JSONEncoder().encode(pages)
    }
}

extension StudentSubmission {
    func scans() -> [Data] {
        guard let scanArchive else { return [] }
        return (try? JSONDecoder().decode([Data].self, from: scanArchive)) ?? []
    }

    func setScans(_ pages: [Data]) {
        scanArchive = try? JSONEncoder().encode(pages)
    }

    func questionGrades() -> [QuestionGradeRecord] {
        guard let gradeArchive else { return [] }
        return (try? JSONDecoder().decode([QuestionGradeRecord].self, from: gradeArchive)) ?? []
    }

    func setQuestionGrades(_ grades: [QuestionGradeRecord]) {
        gradeArchive = try? JSONEncoder().encode(grades)
        totalScore = grades.reduce(0) { $0 + $1.awardedPoints }
        maxScore = grades.reduce(0) { $0 + $1.maxPoints }
    }
}

struct RubricQuestionDraft: Identifiable, Hashable {
    var id = UUID()
    var questionID: String
    var displayLabel: String
    var promptText: String
    var idealAnswer: String
    var gradingCriteria: String
    var maxPointsText: String
}

struct RubricReviewState: Identifiable {
    var id = UUID()
    var pageData: [Data]
    var questionDrafts: [RubricQuestionDraft]
}

struct QuestionGradeRecord: Codable, Hashable, Identifiable {
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

struct SubmissionDraft: Identifiable {
    var id = UUID()
    var studentName: String
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
        studentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || grades.contains(where: \.needsReview)
    }
}

struct RubricSnapshot: Codable {
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

struct MasterExamPayload: Decodable {
    let assignmentTitle: String
    let questions: [GeneratedQuestionPayload]

    enum CodingKeys: String, CodingKey {
        case assignmentTitle = "assignment_title"
        case questions
    }
}

struct GeneratedQuestionPayload: Decodable {
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

struct SubmissionPayload: Decodable {
    let studentName: String
    let questionResults: [SubmissionQuestionPayload]
    let overallNotes: String

    enum CodingKeys: String, CodingKey {
        case studentName = "student_name"
        case questionResults = "question_results"
        case overallNotes = "overall_notes"
    }
}

struct SubmissionQuestionPayload: Decodable {
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

        return RubricReviewState(pageData: pageData, questionDrafts: questionDrafts)
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

enum CSVExporter {
    static func csvString(for session: GradingSession) -> String {
        let questions = session.sortedQuestions
        let headers = ["Student Name", "Total Score", "Max Score", "Reviewed", "Saved At"] + questions.map(\.displayLabel)
        let headerLine = headers.map(escapeCSV).joined(separator: ",")

        let rows = session.sortedSubmissions.map { submission in
            let gradeByQuestion = Dictionary(uniqueKeysWithValues: submission.questionGrades().map { ($0.questionID, $0) })
            let values = [
                submission.studentName,
                formatCSVScore(submission.totalScore),
                formatCSVScore(submission.maxScore),
                submission.teacherReviewed ? "Yes" : "No",
                ISO8601DateFormatter().string(from: submission.createdAt),
            ] + questions.map { question in
                if let grade = gradeByQuestion[question.questionID] {
                    return "\(formatCSVScore(grade.awardedPoints))/\(formatCSVScore(grade.maxPoints))"
                }
                return ""
            }

            return values.map(escapeCSV).joined(separator: ",")
        }

        return ([headerLine] + rows).joined(separator: "\n")
    }

    static func temporaryFileURL(for session: GradingSession) throws -> URL {
        let timestamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let sanitizedTitle = session.title.replacingOccurrences(of: "/", with: "-")
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(sanitizedTitle)-\(timestamp).csv")
        try csvString(for: session).write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    private static func escapeCSV(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private static func formatCSVScore(_ value: Double) -> String {
        ScoreFormatting.scoreString(value)
    }
}

enum ScoreFormatting {
    static func scoreString(_ value: Double) -> String {
        if value.rounded(.towardZero) == value {
            return String(Int(value))
        }

        return value.formatted(.number.precision(.fractionLength(0...2)))
    }
}
