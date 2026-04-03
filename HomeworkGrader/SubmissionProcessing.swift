import Foundation

enum SubmissionProcessingStage: Sendable {
    case grading
    case validating(attempt: Int)
    case regrading(attempt: Int)

    var singleSubmissionDetail: String {
        switch self {
        case .grading:
            return "Initial grading pass"
        case .validating(let attempt):
            return "Validation pass \(attempt)"
        case .regrading(let attempt):
            return "Regrading pass \(attempt) after validation"
        }
    }

    var batchStage: BatchSubmissionStage {
        switch self {
        case .grading:
            return .grading
        case .validating:
            return .validating
        case .regrading:
            return .regrading
        }
    }
}

struct SubmissionProcessorConfig: Sendable {
    let apiKey: String
    let gradingModelID: String
    let validationModelID: String?
    let rubricSnapshots: [RubricSnapshot]
    let overallRules: String?
    let integerPointsOnly: Bool
    let relaxedGradingMode: Bool
    let gradingReasoningEffort: String?
    let gradingVerbosity: String?
    let gradingServiceTier: String?
    let validationReasoningEffort: String?
    let validationVerbosity: String?
    let validationServiceTier: String?
}

struct ProcessedSubmission: Sendable {
    let draft: SubmissionDraft
    let usageSummaries: [OpenAIUsageSummary]
}

struct SubmissionRequestStreamEvent: Sendable {
    let requestID: String
    let title: String
    let event: OpenAIStreamEvent
}

struct SubmissionProcessor: Sendable {
    let config: SubmissionProcessorConfig

    func grade(
        pageData: [Data],
        requestNamespace: String,
        requestLabelPrefix: String,
        progress: (@Sendable (SubmissionProcessingStage) async -> Void)? = nil,
        transcript: (@Sendable (SubmissionRequestStreamEvent) async -> Void)? = nil
    ) async throws -> ProcessedSubmission {
        var usageSummaries: [OpenAIUsageSummary] = []

        func makeTranscriptHandler(
            requestID: String,
            title: String
        ) -> (@Sendable (OpenAIStreamEvent) async -> Void)? {
            guard let transcript else { return nil }
            return { event in
                await transcript(
                    SubmissionRequestStreamEvent(
                        requestID: requestID,
                        title: title,
                        event: event
                    )
                )
            }
        }

        if let progress {
            await progress(.grading)
        }
        var gradingResult = try await OpenAIService.shared.gradeSubmission(
            apiKey: config.apiKey,
            modelID: config.gradingModelID,
            rubric: config.rubricSnapshots,
            overallRules: config.overallRules,
            pageData: pageData,
            integerPointsOnly: config.integerPointsOnly,
            relaxedGradingMode: config.relaxedGradingMode,
            reasoningEffort: config.gradingReasoningEffort,
            verbosity: config.gradingVerbosity,
            serviceTier: config.gradingServiceTier,
            streamHandler: makeTranscriptHandler(
                requestID: "\(requestNamespace)-grade",
                title: "\(requestLabelPrefix) • Grade"
            )
        )
        if let usage = gradingResult.usage {
            usageSummaries.append(usage)
        }

        var draft = SubmissionDraft.from(
            payload: gradingResult.payload,
            rubricSnapshots: config.rubricSnapshots,
            pageData: pageData,
            integerPointsOnly: config.integerPointsOnly
        )

        let trimmedValidationModelID = config.validationModelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedValidationModelID.isEmpty else {
            return ProcessedSubmission(draft: draft, usageSummaries: usageSummaries)
        }

        let maxValidationAttempts = 3
        var validationApproved = false

        for attempt in 1...maxValidationAttempts {
            if let progress {
                await progress(.validating(attempt: attempt))
            }
            let validationResult = try await OpenAIService.shared.validateSubmissionGrade(
                apiKey: config.apiKey,
                modelID: trimmedValidationModelID,
                rubric: config.rubricSnapshots,
                overallRules: config.overallRules,
                candidateGrading: gradingResult.payload,
                pageData: pageData,
                integerPointsOnly: config.integerPointsOnly,
                relaxedGradingMode: config.relaxedGradingMode,
                reasoningEffort: config.validationReasoningEffort,
                verbosity: config.validationVerbosity,
                serviceTier: config.validationServiceTier,
                streamHandler: makeTranscriptHandler(
                    requestID: "\(requestNamespace)-validate-\(attempt)",
                    title: "\(requestLabelPrefix) • Validate \(attempt)"
                )
            )
            if let usage = validationResult.usage {
                usageSummaries.append(usage)
            }

            if validationResult.payload.isGradingCorrect {
                validationApproved = true
                break
            }

            if attempt == maxValidationAttempts {
                break
            }

            if let progress {
                await progress(.regrading(attempt: attempt))
            }
            gradingResult = try await OpenAIService.shared.gradeSubmission(
                apiKey: config.apiKey,
                modelID: config.gradingModelID,
                rubric: config.rubricSnapshots,
                overallRules: config.overallRules,
                pageData: pageData,
                integerPointsOnly: config.integerPointsOnly,
                relaxedGradingMode: config.relaxedGradingMode,
                previousGrading: gradingResult.payload,
                validatorFeedback: validationResult.payload,
                reasoningEffort: config.gradingReasoningEffort,
                verbosity: config.gradingVerbosity,
                serviceTier: config.gradingServiceTier,
                streamHandler: makeTranscriptHandler(
                    requestID: "\(requestNamespace)-regrade-\(attempt)",
                    title: "\(requestLabelPrefix) • Regrade \(attempt)"
                )
            )
            if let usage = gradingResult.usage {
                usageSummaries.append(usage)
            }

            draft = SubmissionDraft.from(
                payload: gradingResult.payload,
                rubricSnapshots: config.rubricSnapshots,
                pageData: pageData,
                integerPointsOnly: config.integerPointsOnly
            )
        }

        if !validationApproved {
            var adjusted = draft
            adjusted.overallNotes = [
                "Automated validation could not fully confirm this grading after multiple attempts.",
                adjusted.overallNotes,
            ]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
            adjusted.grades = adjusted.grades.map { grade in
                var copy = grade
                copy.needsReview = true
                return copy
            }
            adjusted.nameNeedsReview = true
            draft = adjusted
        }

        return ProcessedSubmission(draft: draft, usageSummaries: usageSummaries)
    }
}

enum BatchSubmissionStage: Sendable {
    case queued
    case grading
    case validating
    case regrading
    case completed
    case failed
}

struct BatchProgressSnapshot: Sendable {
    let total: Int
    let queued: Int
    let grading: Int
    let validating: Int
    let regrading: Int
    let completed: Int
    let failed: Int
}

actor BatchProgressTracker {
    private var stages: [Int: BatchSubmissionStage]

    init(total: Int) {
        self.stages = Dictionary(uniqueKeysWithValues: (0..<total).map { ($0, .queued) })
    }

    func setStage(_ stage: BatchSubmissionStage, for index: Int) -> BatchProgressSnapshot {
        stages[index] = stage
        return snapshot()
    }

    func snapshot() -> BatchProgressSnapshot {
        BatchProgressSnapshot(
            total: stages.count,
            queued: stages.values.filter { $0 == .queued }.count,
            grading: stages.values.filter { $0 == .grading }.count,
            validating: stages.values.filter { $0 == .validating }.count,
            regrading: stages.values.filter { $0 == .regrading }.count,
            completed: stages.values.filter { $0 == .completed }.count,
            failed: stages.values.filter { $0 == .failed }.count
        )
    }
}

struct BatchSubmissionOutcome: Sendable {
    let index: Int
    let processedSubmission: ProcessedSubmission?
    let errorMessage: String?
}

struct BatchSubmissionFailure: Identifiable {
    let id = UUID()
    let submissionNumber: Int
    let message: String
}

struct BatchSubmissionReviewState: Identifiable {
    let id = UUID()
    var drafts: [SubmissionDraft]
    let failures: [BatchSubmissionFailure]
}

enum BusyTranscriptKind {
    case outgoing
    case incoming
    case status
    case error
}

struct BusyTranscriptEntry: Identifiable {
    let id: String
    var title: String
    var body: String
    var kind: BusyTranscriptKind
    var isStreaming: Bool
}

struct BusyOverlayState {
    var title: String
    var detail: String?
    var progressLabel: String?
    var progressValue: Double?
    var transcriptEntries: [BusyTranscriptEntry] = []

    init(title: String, detail: String? = nil, progressLabel: String? = nil, progressValue: Double? = nil) {
        self.title = title
        self.detail = detail
        self.progressLabel = progressLabel
        self.progressValue = Self.normalizedProgress(progressValue)
    }

    init(snapshot: BatchProgressSnapshot) {
        self.init(title: "Batch grading submissions")
        apply(snapshot: snapshot)
    }

    mutating func setPresentation(title: String, detail: String? = nil, progressLabel: String? = nil, progressValue: Double? = nil) {
        self.title = title
        self.detail = detail
        self.progressLabel = progressLabel
        self.progressValue = Self.normalizedProgress(progressValue)
    }

    mutating func apply(snapshot: BatchProgressSnapshot) {
        let processedCount = snapshot.completed + snapshot.failed
        let progressValue = snapshot.total == 0 ? nil : Double(processedCount) / Double(snapshot.total)
        let detailParts = [
            snapshot.queued > 0 ? "\(snapshot.queued) queued" : nil,
            snapshot.grading > 0 ? "\(snapshot.grading) grading" : nil,
            snapshot.validating > 0 ? "\(snapshot.validating) validating" : nil,
            snapshot.regrading > 0 ? "\(snapshot.regrading) regrading" : nil,
            snapshot.failed > 0 ? "\(snapshot.failed) failed" : nil,
        ]
        .compactMap { $0 }

        setPresentation(
            title: "Batch grading submissions",
            detail: detailParts.isEmpty ? "Preparing results..." : detailParts.joined(separator: " • "),
            progressLabel: "Completed \(processedCount) of \(snapshot.total)",
            progressValue: progressValue
        )
    }

    private static func normalizedProgress(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(max(value, 0), 1)
    }

    mutating func applyStreamEvent(_ event: OpenAIStreamEvent, sourceID: String, sourceTitle: String) {
        switch event {
        case .preparing(let preview):
            upsertEntry(
                id: "\(sourceID)-request",
                title: "\(sourceTitle) • Sending",
                body: clip(preview.formattedText, limit: 2600),
                kind: .outgoing,
                isStreaming: false
            )
        case .status(let message):
            upsertEntry(
                id: "\(sourceID)-status",
                title: "\(sourceTitle) • Status",
                body: clip(message, limit: 500),
                kind: .status,
                isStreaming: false
            )
        case .responseCreated(let responseID):
            upsertEntry(
                id: "\(sourceID)-status",
                title: "\(sourceTitle) • Status",
                body: "OpenAI response \(responseID) created.",
                kind: .status,
                isStreaming: false
            )
        case .outputTextDelta(let delta):
            appendToEntry(
                id: "\(sourceID)-response",
                title: "\(sourceTitle) • Receiving",
                delta: delta,
                kind: .incoming,
                isStreaming: true
            )
        case .outputTextDone(let text):
            upsertEntry(
                id: "\(sourceID)-response",
                title: "\(sourceTitle) • Receiving",
                body: clip(text, limit: 4200),
                kind: .incoming,
                isStreaming: false
            )
        case .completed:
            upsertEntry(
                id: "\(sourceID)-status",
                title: "\(sourceTitle) • Status",
                body: "Stream completed.",
                kind: .status,
                isStreaming: false
            )
        case .error(let message):
            upsertEntry(
                id: "\(sourceID)-error",
                title: "\(sourceTitle) • Error",
                body: clip(message, limit: 600),
                kind: .error,
                isStreaming: false
            )
        }

        trimEntriesIfNeeded()
    }

    private mutating func appendToEntry(
        id: String,
        title: String,
        delta: String,
        kind: BusyTranscriptKind,
        isStreaming: Bool
    ) {
        if let index = transcriptEntries.firstIndex(where: { $0.id == id }) {
            transcriptEntries[index].title = title
            transcriptEntries[index].kind = kind
            transcriptEntries[index].isStreaming = isStreaming
            transcriptEntries[index].body = clip(transcriptEntries[index].body + delta, limit: 4200)
            moveEntryToEnd(at: index)
            return
        }

        transcriptEntries.append(
            BusyTranscriptEntry(
                id: id,
                title: title,
                body: clip(delta, limit: 4200),
                kind: kind,
                isStreaming: isStreaming
            )
        )
    }

    private mutating func upsertEntry(
        id: String,
        title: String,
        body: String,
        kind: BusyTranscriptKind,
        isStreaming: Bool
    ) {
        if let index = transcriptEntries.firstIndex(where: { $0.id == id }) {
            transcriptEntries[index].title = title
            transcriptEntries[index].body = body
            transcriptEntries[index].kind = kind
            transcriptEntries[index].isStreaming = isStreaming
            moveEntryToEnd(at: index)
            return
        }

        transcriptEntries.append(
            BusyTranscriptEntry(
                id: id,
                title: title,
                body: body,
                kind: kind,
                isStreaming: isStreaming
            )
        )
    }

    private mutating func moveEntryToEnd(at index: Int) {
        let entry = transcriptEntries.remove(at: index)
        transcriptEntries.append(entry)
    }

    private mutating func trimEntriesIfNeeded() {
        let maxEntries = 14
        if transcriptEntries.count > maxEntries {
            transcriptEntries.removeFirst(transcriptEntries.count - maxEntries)
        }
    }

    private func clip(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return "...\n" + String(text.suffix(limit))
    }
}
