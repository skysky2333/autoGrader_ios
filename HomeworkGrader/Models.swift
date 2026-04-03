import Foundation
import SwiftData

private enum ArchiveDecodeCache {
    private static let lock = NSLock()
    private static var pageEntries: [String: PageCacheEntry] = [:]
    private static var gradeEntries: [String: GradeCacheEntry] = [:]

    private struct PageCacheEntry {
        var pages: [Data]?
        let fileURLs: [URL]?
    }

    private struct GradeCacheEntry {
        let grades: [QuestionGradeRecord]
        let hasQuestionNeedingReview: Bool
    }

    static func pages(ownerID: UUID, archive: Data?) -> [Data] {
        let key = cacheKey(ownerID: ownerID, archive: archive)
        let entry = cachedPageEntry(for: key, archive: archive)
        if let pages = entry.pages {
            return pages
        }
        guard let fileURLs = entry.fileURLs else { return [] }

        let loadedPages = fileURLs.compactMap { fileURL in
            try? Data(contentsOf: fileURL, options: .mappedIfSafe)
        }
        lock.lock()
        if var cachedEntry = pageEntries[key] {
            cachedEntry.pages = loadedPages
            pageEntries[key] = cachedEntry
        }
        lock.unlock()
        return loadedPages
    }

    static func pageFileURLs(ownerID: UUID, archive: Data?) -> [URL]? {
        let key = cacheKey(ownerID: ownerID, archive: archive)
        return cachedPageEntry(for: key, archive: archive).fileURLs
    }

    static func grades(ownerID: UUID, archive: Data?) -> [QuestionGradeRecord] {
        let key = cacheKey(ownerID: ownerID, archive: archive)
        return cachedGradeEntry(for: key, archive: archive).grades
    }

    static func gradeNeedsReview(ownerID: UUID, archive: Data?) -> Bool {
        let key = cacheKey(ownerID: ownerID, archive: archive)
        return cachedGradeEntry(for: key, archive: archive).hasQuestionNeedingReview
    }

    static func storePages(_ pages: [Data], ownerID: UUID, archive: Data?) {
        let key = cacheKey(ownerID: ownerID, archive: archive)
        lock.lock()
        defer { lock.unlock() }
        removeEntriesLocked(for: ownerID, from: &pageEntries)
        pageEntries[key] = PageCacheEntry(pages: pages, fileURLs: nil)
    }

    static func storePageFiles(_ fileURLs: [URL], ownerID: UUID, archive: Data?) {
        let key = cacheKey(ownerID: ownerID, archive: archive)
        lock.lock()
        defer { lock.unlock() }
        removeEntriesLocked(for: ownerID, from: &pageEntries)
        pageEntries[key] = PageCacheEntry(pages: nil, fileURLs: fileURLs)
    }

    static func storeGrades(_ grades: [QuestionGradeRecord], ownerID: UUID, archive: Data?) {
        let key = cacheKey(ownerID: ownerID, archive: archive)
        lock.lock()
        defer { lock.unlock() }
        removeEntriesLocked(for: ownerID, from: &gradeEntries)
        gradeEntries[key] = GradeCacheEntry(
            grades: grades,
            hasQuestionNeedingReview: grades.contains(where: \.needsReview)
        )
    }

    private static func cachedValue<Value>(
        for key: String,
        store: inout [String: Value],
        decode: () -> Value
    ) -> Value {
        lock.lock()
        defer { lock.unlock() }

        if let existing = store[key] {
            return existing
        }

        let decoded = decode()
        store[key] = decoded
        return decoded
    }

    private static func removeEntriesLocked<Value>(for ownerID: UUID, from store: inout [String: Value]) {
        let prefix = ownerID.uuidString + "|"
        store.keys
            .filter { $0.hasPrefix(prefix) }
            .forEach { store.removeValue(forKey: $0) }
    }

    private static func cachedPageEntry(for key: String, archive: Data?) -> PageCacheEntry {
        cachedValue(for: key, store: &pageEntries) {
            guard let archive else {
                return PageCacheEntry(pages: [], fileURLs: nil)
            }
            if let stored = try? JSONDecoder().decode(StoredPageArchive.self, from: archive) {
                let fileURLs = stored.filePaths.map(URL.init(fileURLWithPath:))
                return PageCacheEntry(pages: nil, fileURLs: fileURLs)
            }
            let decodedPages = (try? JSONDecoder().decode([Data].self, from: archive)) ?? []
            return PageCacheEntry(pages: decodedPages, fileURLs: nil)
        }
    }

    private static func cachedGradeEntry(for key: String, archive: Data?) -> GradeCacheEntry {
        cachedValue(for: key, store: &gradeEntries) {
            guard let archive else {
                return GradeCacheEntry(grades: [], hasQuestionNeedingReview: false)
            }
            let decoded = (try? JSONDecoder().decode([QuestionGradeRecord].self, from: archive)) ?? []
            return GradeCacheEntry(
                grades: decoded,
                hasQuestionNeedingReview: decoded.contains(where: \.needsReview)
            )
        }
    }

    private static func cacheKey(ownerID: UUID, archive: Data?) -> String {
        let archiveHash = archive.map { ($0 as NSData).hash } ?? 0
        let archiveCount = archive?.count ?? 0
        return "\(ownerID.uuidString)|\(archiveCount)|\(archiveHash)"
    }
}

private struct StoredPageArchive: Codable {
    let filePaths: [String]
}

private enum PersistedPageStorage {
    static func persistPages(_ pages: [Data], ownerID: UUID, namespace: String) throws -> [URL] {
        let directory = try prepareDirectory(ownerID: ownerID, namespace: namespace)
        return try pages.enumerated().map { index, pageData in
            let fileURL = directory.appendingPathComponent(String(format: "page-%04d.jpg", index + 1))
            try pageData.write(to: fileURL, options: .atomic)
            return fileURL
        }
    }

    static func copyPages(from sourceFileURLs: [URL], ownerID: UUID, namespace: String) throws -> [URL] {
        let directory = try prepareDirectory(ownerID: ownerID, namespace: namespace)
        return try sourceFileURLs.enumerated().map { index, sourceFileURL in
            let pathExtension = sourceFileURL.pathExtension.isEmpty ? "jpg" : sourceFileURL.pathExtension
            let destinationURL = directory.appendingPathComponent(
                String(format: "page-%04d.%@", index + 1, pathExtension)
            )
            try FileManager.default.copyItem(at: sourceFileURL, to: destinationURL)
            return destinationURL
        }
    }

    private static func prepareDirectory(ownerID: UUID, namespace: String) throws -> URL {
        let root = try rootDirectory()
        let directory = root
            .appendingPathComponent(namespace, isDirectory: true)
            .appendingPathComponent(ownerID.uuidString, isDirectory: true)

        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func rootDirectory() throws -> URL {
        guard let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let rootURL = baseURL.appendingPathComponent("HomeworkGraderPersistedPages", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        return rootURL
    }
}

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
    static let defaultValidationModel = "gpt-5.4-mini"
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
    private static let persistedPageNamespace = "session-master-scans"

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
}

extension StudentSubmission {
    private static let persistedPageNamespace = "submission-scans"

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

    var hasQuestionNeedingReview: Bool {
        ArchiveDecodeCache.gradeNeedsReview(ownerID: id, archive: gradeArchive)
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
        gradeArchive = try? JSONEncoder().encode(grades)
        ArchiveDecodeCache.storeGrades(grades, ownerID: id, archive: gradeArchive)
        totalScore = grades.reduce(0) { $0 + $1.awardedPoints }
        maxScore = grades.reduce(0) { $0 + $1.maxPoints }
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
}
