import Foundation
import SwiftData

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
    var validationMaxAttempts: Int?
    var maxPagesPerSubmission: Int?
    var overallGradingRules: String?
    var relaxedGradingMode: Bool?
    var estimatedCostUSD: Double?
    var apiKeyFingerprint: String?
    var integerPointsOnly: Bool?
    var isFinished: Bool
    var rubricApprovedAt: Date?
    var rubricProcessingStateRaw: String?
    var rubricProcessingDetail: String?
    var rubricRemoteBatchID: String?
    var rubricRemoteBatchRequestID: String?
    @Attribute(.externalStorage) var pendingRubricPayloadArchive: Data?
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
        validationMaxAttempts: Int? = 2,
        maxPagesPerSubmission: Int? = nil,
        overallGradingRules: String? = nil,
        relaxedGradingMode: Bool = false,
        estimatedCostUSD: Double? = nil,
        apiKeyFingerprint: String? = nil,
        integerPointsOnly: Bool = false,
        isFinished: Bool = false,
        rubricApprovedAt: Date? = nil,
        rubricProcessingStateRaw: String? = nil,
        rubricProcessingDetail: String? = nil,
        rubricRemoteBatchID: String? = nil,
        rubricRemoteBatchRequestID: String? = nil,
        pendingRubricPayloadArchive: Data? = nil,
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
        self.validationMaxAttempts = validationMaxAttempts
        self.maxPagesPerSubmission = maxPagesPerSubmission
        self.overallGradingRules = overallGradingRules
        self.relaxedGradingMode = relaxedGradingMode
        self.estimatedCostUSD = estimatedCostUSD
        self.apiKeyFingerprint = apiKeyFingerprint
        self.integerPointsOnly = integerPointsOnly
        self.isFinished = isFinished
        self.rubricApprovedAt = rubricApprovedAt
        self.rubricProcessingStateRaw = rubricProcessingStateRaw
        self.rubricProcessingDetail = rubricProcessingDetail
        self.rubricRemoteBatchID = rubricRemoteBatchID
        self.rubricRemoteBatchRequestID = rubricRemoteBatchRequestID
        self.pendingRubricPayloadArchive = pendingRubricPayloadArchive
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
        self.session = nil
    }
}

@Model
final class StudentSubmission {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var studentName: String
    var nameNeedsReview: Bool?
    var needsAttention: Bool?
    var attentionReasonsText: String?
    var validationNeedsReview: Bool?
    var overallNotes: String
    var teacherReviewed: Bool
    var totalScore: Double
    var maxScore: Double
    var processingStateRaw: String?
    var batchStageRaw: String?
    var batchAttemptNumber: Int?
    var processingDetail: String?
    var remoteBatchID: String?
    var remoteBatchRequestID: String?
    var session: GradingSession?
    @Attribute(.externalStorage) var scanArchive: Data?
    @Attribute(.externalStorage) var gradeArchive: Data?
    @Attribute(.externalStorage) var latestSubmissionPayloadArchive: Data?
    @Attribute(.externalStorage) var latestValidationPayloadArchive: Data?
    @Attribute(.externalStorage) var debugArchive: Data?

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        studentName: String,
        nameNeedsReview: Bool = false,
        needsAttention: Bool = false,
        attentionReasonsText: String? = nil,
        validationNeedsReview: Bool = false,
        overallNotes: String,
        teacherReviewed: Bool,
        totalScore: Double,
        maxScore: Double,
        processingStateRaw: String? = nil,
        batchStageRaw: String? = nil,
        batchAttemptNumber: Int? = nil,
        processingDetail: String? = nil,
        remoteBatchID: String? = nil,
        remoteBatchRequestID: String? = nil,
        session: GradingSession? = nil,
        scanArchive: Data? = nil,
        gradeArchive: Data? = nil,
        latestSubmissionPayloadArchive: Data? = nil,
        latestValidationPayloadArchive: Data? = nil,
        debugArchive: Data? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.studentName = studentName
        self.nameNeedsReview = nameNeedsReview
        self.needsAttention = needsAttention
        self.attentionReasonsText = attentionReasonsText
        self.validationNeedsReview = validationNeedsReview
        self.overallNotes = overallNotes
        self.teacherReviewed = teacherReviewed
        self.totalScore = totalScore
        self.maxScore = maxScore
        self.processingStateRaw = processingStateRaw
        self.batchStageRaw = batchStageRaw
        self.batchAttemptNumber = batchAttemptNumber
        self.processingDetail = processingDetail
        self.remoteBatchID = remoteBatchID
        self.remoteBatchRequestID = remoteBatchRequestID
        self.session = nil
        self.scanArchive = scanArchive
        self.gradeArchive = gradeArchive
        self.latestSubmissionPayloadArchive = latestSubmissionPayloadArchive
        self.latestValidationPayloadArchive = latestValidationPayloadArchive
        self.debugArchive = debugArchive
    }
}

extension GradingSession {
    private static let persistedPageNamespace = "session-master-scans"

    var rubricProcessingState: RubricGenerationProcessingState? {
        guard let raw = rubricProcessingStateRaw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return RubricGenerationProcessingState(rawValue: raw)
    }

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

    var validationMaxAttemptsResolved: Int {
        max(validationMaxAttempts ?? 2, 1)
    }

    var validationMaxAttemptsLabel: String {
        "\(validationMaxAttemptsResolved)"
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
        questions.reduce(0) { $0 + $1.maxPoints }
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

    var hasPendingRubricGeneration: Bool {
        rubricProcessingState == .pending &&
        !(rubricRemoteBatchID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    var hasFailedRubricGeneration: Bool {
        rubricProcessingState == .failed
    }

    var hasPendingRubricReview: Bool {
        pendingRubricPayload() != nil
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
        ArchiveDecodeCache.pages(ownerID: id, archive: masterScanArchive)
    }

    func masterScanFileURLs() -> [URL]? {
        ArchiveDecodeCache.pageFileURLs(ownerID: id, archive: masterScanArchive)
    }

    func setMasterScans(_ pages: [Data]) {
        if let storedArchive = try? archiveForPersistedPages(pages) {
            masterScanArchive = storedArchive.archive
            ArchiveDecodeCache.storePageFiles(storedArchive.fileURLs, ownerID: id, archive: masterScanArchive)
            return
        }
        masterScanArchive = try? JSONEncoder().encode(pages)
        ArchiveDecodeCache.storePages(pages, ownerID: id, archive: masterScanArchive)
    }

    func setMasterScans(from fileURLs: [URL]) {
        if let storedArchive = try? archiveForCopiedPages(fileURLs) {
            masterScanArchive = storedArchive.archive
            ArchiveDecodeCache.storePageFiles(storedArchive.fileURLs, ownerID: id, archive: masterScanArchive)
            return
        }
        let pages = fileURLs.compactMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }
        masterScanArchive = try? JSONEncoder().encode(pages)
        ArchiveDecodeCache.storePages(pages, ownerID: id, archive: masterScanArchive)
    }

    private func archiveForPersistedPages(_ pages: [Data]) throws -> (archive: Data, fileURLs: [URL]) {
        let fileURLs = try PersistedPageStorage.persistPages(
            pages,
            ownerID: id,
            namespace: Self.persistedPageNamespace
        )
        let archive = try JSONEncoder().encode(StoredPageArchive(filePaths: fileURLs.map(\.path)))
        return (archive, fileURLs)
    }

    private func archiveForCopiedPages(_ fileURLs: [URL]) throws -> (archive: Data, fileURLs: [URL]) {
        let persistedFileURLs = try PersistedPageStorage.copyPages(
            from: fileURLs,
            ownerID: id,
            namespace: Self.persistedPageNamespace
        )
        let archive = try JSONEncoder().encode(StoredPageArchive(filePaths: persistedFileURLs.map(\.path)))
        return (archive, persistedFileURLs)
    }

    func markRubricGenerationPending(batchID: String, requestID: String, detail: String) {
        rubricProcessingStateRaw = RubricGenerationProcessingState.pending.rawValue
        rubricProcessingDetail = detail
        rubricRemoteBatchID = batchID
        rubricRemoteBatchRequestID = requestID
    }

    func markRubricGenerationFailed(message: String) {
        rubricProcessingStateRaw = RubricGenerationProcessingState.failed.rawValue
        rubricProcessingDetail = message
        rubricRemoteBatchID = nil
        rubricRemoteBatchRequestID = nil
    }

    func clearRubricGenerationState() {
        rubricProcessingStateRaw = nil
        rubricProcessingDetail = nil
        rubricRemoteBatchID = nil
        rubricRemoteBatchRequestID = nil
    }

    func pendingRubricPayload() -> MasterExamPayload? {
        guard let pendingRubricPayloadArchive else { return nil }
        return try? JSONDecoder().decode(MasterExamPayload.self, from: pendingRubricPayloadArchive)
    }

    func setPendingRubricPayload(_ payload: MasterExamPayload?) {
        pendingRubricPayloadArchive = payload.flatMap { try? JSONEncoder().encode($0) }
    }
}

extension StudentSubmission {
    private static let persistedPageNamespace = "submission-scans"
    private static let persistedGradeNamespace = "submission-grades"

    var processingState: StudentSubmissionProcessingState {
        StudentSubmissionProcessingState(rawValue: processingStateRaw ?? "") ?? .completed
    }

    var batchStage: StudentSubmissionBatchStage? {
        guard let raw = batchStageRaw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return StudentSubmissionBatchStage(rawValue: raw)
    }

    var currentBatchAttemptNumber: Int {
        max(batchAttemptNumber ?? 1, 1)
    }

    var isQueuedForRubric: Bool {
        isProcessingPending && batchStage == .queued
    }

    var isAwaitingRemoteProcessing: Bool {
        isProcessingPending && batchStage != .queued
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

    var needsAttentionEnabled: Bool {
        needsAttention ?? false
    }

    var validationNeedsReviewEnabled: Bool {
        validationNeedsReview ?? false
    }

    var hasQuestionNeedingReview: Bool {
        ArchiveDecodeCache.gradeNeedsReview(ownerID: id, archive: gradeArchive)
    }

    var hasRemoteBatchInFlight: Bool {
        isProcessingPending && !(remoteBatchID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    var hasRemoteBatchReservation: Bool {
        isProcessingPending && !(remoteBatchRequestID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    func scans() -> [Data] {
        ArchiveDecodeCache.pages(ownerID: id, archive: scanArchive)
    }

    func scanFileURLs() -> [URL]? {
        ArchiveDecodeCache.pageFileURLs(ownerID: id, archive: scanArchive)
    }

    func setScans(_ pages: [Data]) {
        if let storedArchive = try? archiveForPersistedPages(pages) {
            scanArchive = storedArchive.archive
            ArchiveDecodeCache.storePageFiles(storedArchive.fileURLs, ownerID: id, archive: scanArchive)
            return
        }
        scanArchive = try? JSONEncoder().encode(pages)
        ArchiveDecodeCache.storePages(pages, ownerID: id, archive: scanArchive)
    }

    func setScans(from fileURLs: [URL]) {
        if let storedArchive = try? archiveForCopiedPages(fileURLs) {
            scanArchive = storedArchive.archive
            ArchiveDecodeCache.storePageFiles(storedArchive.fileURLs, ownerID: id, archive: scanArchive)
            return
        }
        let pages = fileURLs.compactMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }
        scanArchive = try? JSONEncoder().encode(pages)
        ArchiveDecodeCache.storePages(pages, ownerID: id, archive: scanArchive)
    }

    func questionGrades() -> [QuestionGradeRecord] {
        ArchiveDecodeCache.grades(ownerID: id, archive: gradeArchive)
    }

    func setQuestionGrades(_ grades: [QuestionGradeRecord]) {
        if let storedArchive = try? archiveForPersistedGrades(grades) {
            gradeArchive = storedArchive.archive
            ArchiveDecodeCache.storeGradeFile(
                storedArchive.fileURL,
                ownerID: id,
                archive: gradeArchive,
                hasQuestionNeedingReview: storedArchive.hasQuestionNeedingReview
            )
        } else {
            gradeArchive = try? JSONEncoder().encode(grades)
            ArchiveDecodeCache.storeGrades(grades, ownerID: id, archive: gradeArchive)
        }
        totalScore = grades.reduce(0) { $0 + $1.awardedPoints }
        maxScore = grades.reduce(0) { $0 + $1.maxPoints }
    }

    func latestSubmissionPayload() -> SubmissionPayload? {
        guard let latestSubmissionPayloadArchive else { return nil }
        return try? JSONDecoder().decode(SubmissionPayload.self, from: latestSubmissionPayloadArchive)
    }

    func setLatestSubmissionPayload(_ payload: SubmissionPayload?) {
        latestSubmissionPayloadArchive = payload.flatMap { try? JSONEncoder().encode($0) }
    }

    func latestValidationPayload() -> GradingValidationPayload? {
        guard let latestValidationPayloadArchive else { return nil }
        return try? JSONDecoder().decode(GradingValidationPayload.self, from: latestValidationPayloadArchive)
    }

    func setLatestValidationPayload(_ payload: GradingValidationPayload?) {
        latestValidationPayloadArchive = payload.flatMap { try? JSONEncoder().encode($0) }
    }

    func debugInfo() -> SubmissionDebugInfo? {
        guard let debugArchive else { return nil }
        return try? JSONDecoder().decode(SubmissionDebugInfo.self, from: debugArchive)
    }

    func setDebugInfo(_ info: SubmissionDebugInfo?) {
        debugArchive = info.flatMap { try? JSONEncoder().encode($0) }
    }

    func updateDebugInfo(_ mutate: (inout SubmissionDebugInfo) -> Void) {
        var info = debugInfo() ?? SubmissionDebugInfo()
        mutate(&info)
        setDebugInfo(info)
    }

    func debugDump() -> String {
        var sections: [String] = []

        let metadataLines = [
            "State: \(processingState.rawValue)",
            batchStage.map { "Pipeline: \($0.rawValue)" },
            remoteBatchID.map { "Remote batch id: \($0)" },
            remoteBatchRequestID.map { "Remote request id: \($0)" },
            processingDetail.map { "Processing detail: \($0)" },
        ]
        .compactMap { $0 }
        if !metadataLines.isEmpty {
            sections.append(metadataLines.joined(separator: "\n"))
        }

        if
            let latestSubmissionPayload = latestSubmissionPayload(),
            let data = try? JSONEncoder.prettyPrinted.encode(latestSubmissionPayload),
            let text = String(data: data, encoding: .utf8)
        {
            sections.append("Latest submission payload JSON:\n\(text)")
        }

        if
            let latestValidationPayload = latestValidationPayload(),
            let data = try? JSONEncoder.prettyPrinted.encode(latestValidationPayload),
            let text = String(data: data, encoding: .utf8)
        {
            sections.append("Latest validation payload JSON:\n\(text)")
        }

        if let info = debugInfo() {
            if let batchStatusJSON = info.batchStatusJSON, !batchStatusJSON.isEmpty {
                sections.append("Latest batch status JSON:\n\(batchStatusJSON)")
            }
            if let latestBatchOutputLineJSON = info.latestBatchOutputLineJSON, !latestBatchOutputLineJSON.isEmpty {
                sections.append("Latest batch output line JSON:\n\(latestBatchOutputLineJSON)")
            }
            if let latestBatchErrorLineJSON = info.latestBatchErrorLineJSON, !latestBatchErrorLineJSON.isEmpty {
                sections.append("Latest batch error line JSON:\n\(latestBatchErrorLineJSON)")
            }
            if let latestLookupSummary = info.latestLookupSummary, !latestLookupSummary.isEmpty {
                sections.append("Lookup summary:\n\(latestLookupSummary)")
            }
        }

        return sections.joined(separator: "\n\n")
    }

    func clearBatchPipelineState() {
        batchStageRaw = nil
        batchAttemptNumber = nil
        remoteBatchID = nil
        remoteBatchRequestID = nil
        latestSubmissionPayloadArchive = nil
    }

    private func archiveForPersistedPages(_ pages: [Data]) throws -> (archive: Data, fileURLs: [URL]) {
        let fileURLs = try PersistedPageStorage.persistPages(
            pages,
            ownerID: id,
            namespace: Self.persistedPageNamespace
        )
        let archive = try JSONEncoder().encode(StoredPageArchive(filePaths: fileURLs.map(\.path)))
        return (archive, fileURLs)
    }

    private func archiveForCopiedPages(_ fileURLs: [URL]) throws -> (archive: Data, fileURLs: [URL]) {
        let persistedFileURLs = try PersistedPageStorage.copyPages(
            from: fileURLs,
            ownerID: id,
            namespace: Self.persistedPageNamespace
        )
        let archive = try JSONEncoder().encode(StoredPageArchive(filePaths: persistedFileURLs.map(\.path)))
        return (archive, persistedFileURLs)
    }

    private func archiveForPersistedGrades(_ grades: [QuestionGradeRecord]) throws -> (archive: Data, fileURL: URL, hasQuestionNeedingReview: Bool) {
        let fileURL = try PersistedGradeStorage.persistGrades(
            grades,
            ownerID: id,
            namespace: Self.persistedGradeNamespace
        )
        let hasQuestionNeedingReview = grades.contains(where: \.needsReview)
        let archive = try JSONEncoder().encode(
            StoredGradeArchive(
                filePath: fileURL.path,
                hasQuestionNeedingReview: hasQuestionNeedingReview
            )
        )
        return (archive, fileURL, hasQuestionNeedingReview)
    }
}
