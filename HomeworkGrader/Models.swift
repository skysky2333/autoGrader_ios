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
    static let defaultGradingModel = "gpt-5.4"
}

struct APIRequestTuningOption: Identifiable, Hashable, Sendable {
    let label: String
    let value: String?

    var id: String { "\(label)|\(value ?? "__nil__")" }
}

enum APIRequestTuningCatalog {
    static let reasoningEffortOptions = [
        APIRequestTuningOption(label: "API Default", value: nil),
        APIRequestTuningOption(label: "None", value: "none"),
        APIRequestTuningOption(label: "Minimal", value: "minimal"),
        APIRequestTuningOption(label: "Low", value: "low"),
        APIRequestTuningOption(label: "Medium", value: "medium"),
        APIRequestTuningOption(label: "High", value: "high"),
        APIRequestTuningOption(label: "XHigh", value: "xhigh"),
    ]

    static let verbosityOptions = [
        APIRequestTuningOption(label: "API Default", value: nil),
        APIRequestTuningOption(label: "Low", value: "low"),
        APIRequestTuningOption(label: "Medium", value: "medium"),
        APIRequestTuningOption(label: "High", value: "high"),
    ]

    static let serviceTierOptions = [
        APIRequestTuningOption(label: "Auto (API Default)", value: nil),
        APIRequestTuningOption(label: "Default", value: "default"),
        APIRequestTuningOption(label: "Flex", value: "flex"),
        APIRequestTuningOption(label: "Priority", value: "priority"),
    ]

    static func label(for value: String?, in options: [APIRequestTuningOption]) -> String {
        options.first(where: { $0.value == value })?.label ?? "API Default"
    }
}

enum StudentSubmissionProcessingState: String, Codable, Sendable {
    case completed
    case pending
    case failed
}

@Model
final class GradingSession {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var answerModelID: String
    var gradingModelID: String
    var validationModelID: String?
    var validationEnabled: Bool?
    var answerReasoningEffort: String?
    var gradingReasoningEffort: String?
    var validationReasoningEffort: String?
    var answerVerbosity: String?
    var gradingVerbosity: String?
    var validationVerbosity: String?
    var answerServiceTier: String?
    var gradingServiceTier: String?
    var validationServiceTier: String?
    var maxPagesPerSubmission: Int?
    var overallGradingRules: String?
    var relaxedGradingMode: Bool?
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
        validationModelID: String? = nil,
        validationEnabled: Bool = true,
        answerReasoningEffort: String? = nil,
        gradingReasoningEffort: String? = nil,
        validationReasoningEffort: String? = nil,
        answerVerbosity: String? = nil,
        gradingVerbosity: String? = nil,
        validationVerbosity: String? = nil,
        answerServiceTier: String? = nil,
        gradingServiceTier: String? = nil,
        validationServiceTier: String? = nil,
        maxPagesPerSubmission: Int? = nil,
        overallGradingRules: String? = nil,
        relaxedGradingMode: Bool = false,
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
        self.validationModelID = validationModelID
        self.validationEnabled = validationEnabled
        self.answerReasoningEffort = answerReasoningEffort
        self.gradingReasoningEffort = gradingReasoningEffort
        self.validationReasoningEffort = validationReasoningEffort
        self.answerVerbosity = answerVerbosity
        self.gradingVerbosity = gradingVerbosity
        self.validationVerbosity = validationVerbosity
        self.answerServiceTier = answerServiceTier
        self.gradingServiceTier = gradingServiceTier
        self.validationServiceTier = validationServiceTier
        self.maxPagesPerSubmission = maxPagesPerSubmission
        self.overallGradingRules = overallGradingRules
        self.relaxedGradingMode = relaxedGradingMode
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
    var nameNeedsReview: Bool?
    var overallNotes: String
    var teacherReviewed: Bool
    var totalScore: Double
    var maxScore: Double
    var processingStateRaw: String?
    var processingDetail: String?
    var remoteBatchID: String?
    var remoteBatchRequestID: String?
    var session: GradingSession?
    @Attribute(.externalStorage) var scanArchive: Data?
    @Attribute(.externalStorage) var gradeArchive: Data?

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        studentName: String,
        nameNeedsReview: Bool = false,
        overallNotes: String,
        teacherReviewed: Bool,
        totalScore: Double,
        maxScore: Double,
        processingStateRaw: String? = nil,
        processingDetail: String? = nil,
        remoteBatchID: String? = nil,
        remoteBatchRequestID: String? = nil,
        session: GradingSession? = nil,
        scanArchive: Data? = nil,
        gradeArchive: Data? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.studentName = studentName
        self.nameNeedsReview = nameNeedsReview
        self.overallNotes = overallNotes
        self.teacherReviewed = teacherReviewed
        self.totalScore = totalScore
        self.maxScore = maxScore
        self.processingStateRaw = processingStateRaw
        self.processingDetail = processingDetail
        self.remoteBatchID = remoteBatchID
        self.remoteBatchRequestID = remoteBatchRequestID
        self.session = session
        self.scanArchive = scanArchive
        self.gradeArchive = gradeArchive
    }
}

extension GradingSession {
    var validationEnabledResolved: Bool {
        validationEnabled ?? true
    }

    var integerPointsOnlyEnabled: Bool {
        integerPointsOnly ?? false
    }

    var relaxedGradingModeEnabled: Bool {
        relaxedGradingMode ?? false
    }

    var validationModelIDResolved: String {
        let trimmed = validationModelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? gradingModelID : trimmed
    }

    var validationModelLabel: String {
        validationEnabledResolved ? validationModelIDResolved : "Disabled"
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

    var relaxedModeLabel: String {
        relaxedGradingModeEnabled ? "On" : "Off"
    }

    var sessionCostLabel: String {
        CostFormatting.usdString(estimatedCostUSD)
    }

    var maxPagesLabel: String {
        if let maxPagesPerSubmission, maxPagesPerSubmission > 0 {
            return "\(maxPagesPerSubmission)"
        }
        return "Off"
    }

    var answerReasoningLabel: String {
        APIRequestTuningCatalog.label(for: answerReasoningEffort, in: APIRequestTuningCatalog.reasoningEffortOptions)
    }

    var gradingReasoningLabel: String {
        APIRequestTuningCatalog.label(for: gradingReasoningEffort, in: APIRequestTuningCatalog.reasoningEffortOptions)
    }

    var validationReasoningLabel: String {
        validationEnabledResolved
            ? APIRequestTuningCatalog.label(for: validationReasoningEffort, in: APIRequestTuningCatalog.reasoningEffortOptions)
            : "Disabled"
    }

    var answerVerbosityLabel: String {
        APIRequestTuningCatalog.label(for: answerVerbosity, in: APIRequestTuningCatalog.verbosityOptions)
    }

    var gradingVerbosityLabel: String {
        APIRequestTuningCatalog.label(for: gradingVerbosity, in: APIRequestTuningCatalog.verbosityOptions)
    }

    var validationVerbosityLabel: String {
        validationEnabledResolved
            ? APIRequestTuningCatalog.label(for: validationVerbosity, in: APIRequestTuningCatalog.verbosityOptions)
            : "Disabled"
    }

    var answerServiceTierLabel: String {
        APIRequestTuningCatalog.label(for: answerServiceTier, in: APIRequestTuningCatalog.serviceTierOptions)
    }

    var gradingServiceTierLabel: String {
        APIRequestTuningCatalog.label(for: gradingServiceTier, in: APIRequestTuningCatalog.serviceTierOptions)
    }

    var validationServiceTierLabel: String {
        validationEnabledResolved
            ? APIRequestTuningCatalog.label(for: validationServiceTier, in: APIRequestTuningCatalog.serviceTierOptions)
            : "Disabled"
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
    var processingState: StudentSubmissionProcessingState {
        StudentSubmissionProcessingState(rawValue: processingStateRaw ?? "") ?? .completed
    }

    var isProcessingPending: Bool {
        processingState == .pending
    }

    var isProcessingFailed: Bool {
        processingState == .failed
    }

    var isProcessingCompleted: Bool {
        processingState == .completed
    }

    var listDisplayName: String {
        let trimmed = studentName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Unnamed Student" : trimmed
    }

    var nameNeedsReviewEnabled: Bool {
        nameNeedsReview ?? false
    }

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
