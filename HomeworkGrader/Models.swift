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

struct APIRequestTuningOption: Identifiable, Hashable {
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

@Model
final class GradingSession {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var answerModelID: String
    var gradingModelID: String
    var validationModelID: String?
    var answerReasoningEffort: String?
    var gradingReasoningEffort: String?
    var answerVerbosity: String?
    var gradingVerbosity: String?
    var answerServiceTier: String?
    var gradingServiceTier: String?
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
        answerReasoningEffort: String? = nil,
        gradingReasoningEffort: String? = nil,
        answerVerbosity: String? = nil,
        gradingVerbosity: String? = nil,
        answerServiceTier: String? = nil,
        gradingServiceTier: String? = nil,
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
        self.answerReasoningEffort = answerReasoningEffort
        self.gradingReasoningEffort = gradingReasoningEffort
        self.answerVerbosity = answerVerbosity
        self.gradingVerbosity = gradingVerbosity
        self.answerServiceTier = answerServiceTier
        self.gradingServiceTier = gradingServiceTier
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
        self.session = session
        self.scanArchive = scanArchive
        self.gradeArchive = gradeArchive
    }
}

extension GradingSession {
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

    var answerVerbosityLabel: String {
        APIRequestTuningCatalog.label(for: answerVerbosity, in: APIRequestTuningCatalog.verbosityOptions)
    }

    var gradingVerbosityLabel: String {
        APIRequestTuningCatalog.label(for: gradingVerbosity, in: APIRequestTuningCatalog.verbosityOptions)
    }

    var answerServiceTierLabel: String {
        APIRequestTuningCatalog.label(for: answerServiceTier, in: APIRequestTuningCatalog.serviceTierOptions)
    }

    var gradingServiceTierLabel: String {
        APIRequestTuningCatalog.label(for: gradingServiceTier, in: APIRequestTuningCatalog.serviceTierOptions)
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
    var overallGradingRules: String
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

struct SubmissionPayload: Codable {
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

struct SubmissionQuestionPayload: Codable {
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

enum SessionExporter {
    static func temporaryPackageURL(for session: GradingSession) throws -> URL {
        let timestamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let rootName = "\(safeName(session.title))-\(timestamp)"
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(rootName, isDirectory: true)
        let zipURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(rootName).zip")

        if FileManager.default.fileExists(atPath: rootURL.path) {
            try FileManager.default.removeItem(at: rootURL)
        }
        if FileManager.default.fileExists(atPath: zipURL.path) {
            try FileManager.default.removeItem(at: zipURL)
        }

        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let csvURL = rootURL.appendingPathComponent("session.csv")
        try CSVExporter.csvString(for: session).write(to: csvURL, atomically: true, encoding: .utf8)

        let rubricURL = rootURL.appendingPathComponent("rubric.json")
        let rubricData = try JSONEncoder.prettyPrinted.encode(session.sortedQuestions.map(\.snapshot))
        try rubricData.write(to: rubricURL)

        let summaryURL = rootURL.appendingPathComponent("session-summary.json")
        let summary = SessionPackageSummary(
            title: session.title,
            createdAt: session.createdAt,
            answerModelID: session.answerModelID,
            gradingModelID: session.gradingModelID,
            overallGradingRules: session.overallGradingRules,
            questionCount: session.sortedQuestions.count,
            submissionCount: session.sortedSubmissions.count,
            totalPoints: session.totalPossiblePoints,
            estimatedCostUSD: session.estimatedCostUSD,
            integerPointsOnly: session.integerPointsOnlyEnabled
        )
        try JSONEncoder.prettyPrinted.encode(summary).write(to: summaryURL)

        let masterDir = rootURL.appendingPathComponent("master_scans", isDirectory: true)
        try FileManager.default.createDirectory(at: masterDir, withIntermediateDirectories: true)
        for (index, data) in session.masterScans().enumerated() {
            try data.write(to: masterDir.appendingPathComponent("page-\(index + 1).jpg"))
        }

        let submissionsDir = rootURL.appendingPathComponent("submissions", isDirectory: true)
        try FileManager.default.createDirectory(at: submissionsDir, withIntermediateDirectories: true)

        for submission in session.sortedSubmissions {
            let childName = "\(safeName(submission.studentName))-\(submission.id.uuidString.prefix(8))"
            let childDir = submissionsDir.appendingPathComponent(childName, isDirectory: true)
            try FileManager.default.createDirectory(at: childDir, withIntermediateDirectories: true)

            let stored = StoredSubmissionSummary(
                id: submission.id,
                studentName: submission.studentName,
                nameNeedsReview: submission.nameNeedsReviewEnabled,
                createdAt: submission.createdAt,
                teacherReviewed: submission.teacherReviewed,
                totalScore: submission.totalScore,
                maxScore: submission.maxScore,
                overallNotes: submission.overallNotes,
                grades: submission.questionGrades()
            )
            try JSONEncoder.prettyPrinted.encode(stored).write(to: childDir.appendingPathComponent("summary.json"))

            let scansDir = childDir.appendingPathComponent("scans", isDirectory: true)
            try FileManager.default.createDirectory(at: scansDir, withIntermediateDirectories: true)
            for (index, data) in submission.scans().enumerated() {
                try data.write(to: scansDir.appendingPathComponent("page-\(index + 1).jpg"))
            }
        }

        try SimpleZipWriter.createZip(fromDirectory: rootURL, to: zipURL)
        return zipURL
    }

    private static func safeName(_ value: String) -> String {
        let invalid = CharacterSet.alphanumerics.union(.whitespaces).inverted
        let cleaned = value.components(separatedBy: invalid).joined(separator: "")
            .replacingOccurrences(of: " ", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return cleaned.isEmpty ? "session" : cleaned
    }
}

private enum SimpleZipWriter {
    private static let localFileHeaderSignature: UInt32 = 0x04034b50
    private static let centralDirectoryHeaderSignature: UInt32 = 0x02014b50
    private static let endOfCentralDirectorySignature: UInt32 = 0x06054b50

    static func createZip(fromDirectory directoryURL: URL, to zipURL: URL) throws {
        let fileManager = FileManager.default
        let fileURLs = try fileManager
            .subpathsOfDirectory(atPath: directoryURL.path)
            .map { directoryURL.appendingPathComponent($0) }
            .filter { url in
                var isDirectory: ObjCBool = false
                fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
                return !isDirectory.boolValue
            }
            .sorted { $0.path < $1.path }

        var archive = Data()
        var centralDirectory = Data()
        var entryCount: UInt16 = 0

        for fileURL in fileURLs {
            let relativePath = directoryURL.lastPathComponent + "/" + fileURL.path.replacingOccurrences(of: directoryURL.path + "/", with: "")
            let fileNameData = Data(relativePath.utf8)
            let fileData = try Data(contentsOf: fileURL)
            let crc = CRC32.checksum(fileData)
            let modDate = try fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .now
            let dos = DOSDateTime(date: modDate)
            let localHeaderOffset = UInt32(archive.count)

            archive.appendLE(localFileHeaderSignature)
            archive.appendLE(UInt16(20))
            archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0))
            archive.appendLE(dos.time)
            archive.appendLE(dos.date)
            archive.appendLE(crc)
            archive.appendLE(UInt32(fileData.count))
            archive.appendLE(UInt32(fileData.count))
            archive.appendLE(UInt16(fileNameData.count))
            archive.appendLE(UInt16(0))
            archive.append(fileNameData)
            archive.append(fileData)

            centralDirectory.appendLE(centralDirectoryHeaderSignature)
            centralDirectory.appendLE(UInt16(20))
            centralDirectory.appendLE(UInt16(20))
            centralDirectory.appendLE(UInt16(0))
            centralDirectory.appendLE(UInt16(0))
            centralDirectory.appendLE(dos.time)
            centralDirectory.appendLE(dos.date)
            centralDirectory.appendLE(crc)
            centralDirectory.appendLE(UInt32(fileData.count))
            centralDirectory.appendLE(UInt32(fileData.count))
            centralDirectory.appendLE(UInt16(fileNameData.count))
            centralDirectory.appendLE(UInt16(0))
            centralDirectory.appendLE(UInt16(0))
            centralDirectory.appendLE(UInt16(0))
            centralDirectory.appendLE(UInt16(0))
            centralDirectory.appendLE(UInt32(0))
            centralDirectory.appendLE(localHeaderOffset)
            centralDirectory.append(fileNameData)

            entryCount += 1
        }

        let centralDirectoryOffset = UInt32(archive.count)
        archive.append(centralDirectory)

        archive.appendLE(endOfCentralDirectorySignature)
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(0))
        archive.appendLE(entryCount)
        archive.appendLE(entryCount)
        archive.appendLE(UInt32(centralDirectory.count))
        archive.appendLE(centralDirectoryOffset)
        archive.appendLE(UInt16(0))

        try archive.write(to: zipURL, options: .atomic)
    }
}

private struct DOSDateTime {
    let time: UInt16
    let date: UInt16

    init(date: Date) {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max((components.year ?? 1980) - 1980, 0)
        let month = components.month ?? 1
        let day = components.day ?? 1
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        let second = (components.second ?? 0) / 2

        self.time = UInt16((hour << 11) | (minute << 5) | second)
        self.date = UInt16((year << 9) | (month << 5) | day)
    }
}

private enum CRC32 {
    private static let table: [UInt32] = {
        (0..<256).map { index in
            var value = UInt32(index)
            for _ in 0..<8 {
                if value & 1 == 1 {
                    value = 0xEDB88320 ^ (value >> 1)
                } else {
                    value >>= 1
                }
            }
            return value
        }
    }()

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = table[index] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { rawBuffer in
            append(rawBuffer.bindMemory(to: UInt8.self))
        }
    }

    mutating func appendLE(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { rawBuffer in
            append(rawBuffer.bindMemory(to: UInt8.self))
        }
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

private struct SessionPackageSummary: Codable {
    let title: String
    let createdAt: Date
    let answerModelID: String
    let gradingModelID: String
    let overallGradingRules: String?
    let questionCount: Int
    let submissionCount: Int
    let totalPoints: Double
    let estimatedCostUSD: Double?
    let integerPointsOnly: Bool
}

private struct StoredSubmissionSummary: Codable {
    let id: UUID
    let studentName: String
    let nameNeedsReview: Bool
    let createdAt: Date
    let teacherReviewed: Bool
    let totalScore: Double
    let maxScore: Double
    let overallNotes: String
    let grades: [QuestionGradeRecord]
}

enum ScoreFormatting {
    static func scoreString(_ value: Double) -> String {
        if value.rounded(.towardZero) == value {
            return String(Int(value))
        }

        return value.formatted(.number.precision(.fractionLength(0...2)))
    }
}

extension JSONEncoder {
    static var prettyPrinted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
