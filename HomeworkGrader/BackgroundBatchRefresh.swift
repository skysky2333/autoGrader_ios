import BackgroundTasks
import Foundation
import SwiftData

enum AppBackgroundTaskIDs {
    static let refreshPendingJobs = "com.example.HomeworkGrader.refreshPendingJobs"
}

@MainActor
enum AppBatchRefreshCoordinator {
    static func scheduleAppRefreshIfNeeded(container: ModelContainer) async {
        guard hasPendingWork(container: container) else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: AppBackgroundTaskIDs.refreshPendingJobs)
            return
        }

        let request = BGAppRefreshTaskRequest(identifier: AppBackgroundTaskIDs.refreshPendingJobs)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Ignore scheduling failures; iOS may reject duplicates or defer work.
        }
    }

    static func refreshPendingWork(container: ModelContainer, triggerNotifications: Bool) async {
        let apiKey = (KeychainStore.shared.string(for: AppSecrets.openAIKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { return }

        let context = ModelContext(container)
        let sessions = (try? context.fetch(FetchDescriptor<GradingSession>())) ?? []

        for session in sessions {
            if session.hasPendingRubricGeneration {
                await refreshPendingRubricGeneration(
                    for: session,
                    apiKey: apiKey,
                    triggerNotifications: triggerNotifications
                )
            }

            if session.submissions.contains(where: \.isProcessingPending) {
                await refreshPendingSubmissionBatches(
                    for: session,
                    apiKey: apiKey,
                    triggerNotifications: triggerNotifications
                )
            }
        }

        try? context.save()
        await scheduleAppRefreshIfNeeded(container: container)
    }

    private static func hasPendingWork(container: ModelContainer) -> Bool {
        let context = ModelContext(container)
        let sessions = (try? context.fetch(FetchDescriptor<GradingSession>())) ?? []
        return sessions.contains { session in
            session.hasPendingRubricGeneration || session.submissions.contains(where: \.isProcessingPending)
        }
    }

    private static func refreshPendingRubricGeneration(
        for session: GradingSession,
        apiKey: String,
        triggerNotifications: Bool
    ) async {
        guard
            let batchID = session.rubricRemoteBatchID,
            let requestID = session.rubricRemoteBatchRequestID
        else {
            session.markRubricGenerationFailed(message: "The saved answer key request is missing its batch metadata.")
            return
        }

        do {
            let snapshot = try await OpenAIService.shared.fetchBatchStatus(
                apiKey: apiKey,
                batchID: batchID
            )

            switch snapshot.status {
            case "completed":
                let results = try await fetchAnswerKeyBatchResults(
                    snapshot: snapshot,
                    modelID: session.answerModelID,
                    apiKey: apiKey
                )
                let errors = try await fetchBatchErrors(snapshot: snapshot, apiKey: apiKey)
                let result = results.first { $0.customID == requestID }
                let errorMessage = errors.first { $0.customID == requestID }?.message

                if let result {
                    recordUsage(result.usage, in: session, apiKey: apiKey)
                    guard !result.payload.questions.isEmpty else {
                        session.markRubricGenerationFailed(
                            message: "The model did not return any gradeable questions. Try rescanning the blank assignment."
                        )
                        return
                    }

                    session.setPendingRubricPayload(result.payload)
                    session.clearRubricGenerationState()

                    if triggerNotifications {
                        await AppNotificationCoordinator.shared.notifyAnswerKeyReady(sessionTitle: session.title)
                    }
                } else if let errorMessage {
                    session.markRubricGenerationFailed(message: errorMessage)
                } else {
                    session.markRubricGenerationFailed(
                        message: "OpenAI completed the answer key batch but did not return a result."
                    )
                }
            case "failed", "expired", "cancelled":
                let message = snapshot.errors.first ?? detailTextForBatchStatus(
                    status: snapshot.status,
                    requestCounts: snapshot.requestCounts
                )
                session.markRubricGenerationFailed(message: message)
            default:
                session.rubricProcessingDetail = detailTextForBatchStatus(
                    status: snapshot.status,
                    requestCounts: snapshot.requestCounts
                )
            }
        } catch {
            session.rubricProcessingDetail = "Unable to refresh answer key status. \(error.localizedDescription)"
        }
    }

    private static func refreshPendingSubmissionBatches(
        for session: GradingSession,
        apiKey: String,
        triggerNotifications: Bool
    ) async {
        let pendingBeforeRefresh = session.submissions.filter(\.isAwaitingRemoteProcessing).count
        let batchIDs = Array(Set(session.submissions.compactMap { submission in
            submission.hasRemoteBatchInFlight ? submission.remoteBatchID : nil
        }))

        for batchID in batchIDs {
            do {
                let snapshot = try await OpenAIService.shared.fetchBatchStatus(
                    apiKey: apiKey,
                    batchID: batchID
                )
                storeBatchStatusDebug(snapshot, session: session, batchID: batchID)
                try await applyBatchStatusSnapshot(snapshot, session: session, apiKey: apiKey)
            } catch {
                markBatchSubmissions(
                    in: session,
                    batchID: batchID,
                    detail: "Unable to refresh batch status. \(error.localizedDescription)"
                )
            }
        }

        if !session.submissions.contains(where: \.hasRemoteBatchInFlight) {
            do {
                try await submitQueuedBatchPipelineStages(for: session, apiKey: apiKey)
            } catch {
                for submission in session.submissions where submission.isAwaitingRemoteProcessing && !submission.hasRemoteBatchInFlight {
                    submission.processingDetail = "Automatic batch submission failed. \(error.localizedDescription)"
                }
            }
        }

        let pendingAfterRefresh = session.submissions.filter(\.isAwaitingRemoteProcessing).count
        if triggerNotifications && pendingBeforeRefresh > 0 && pendingAfterRefresh == 0 {
            await AppNotificationCoordinator.shared.notifyBatchGradingFinished(
                sessionTitle: session.title,
                completed: session.submissions.filter(\.isProcessingCompleted).count,
                failed: session.submissions.filter(\.isProcessingFailed).count
            )
        }
    }

    private static func applyBatchStatusSnapshot(
        _ snapshot: OpenAIBatchStatusSnapshot,
        session: GradingSession,
        apiKey: String
    ) async throws {
        switch snapshot.status {
        case "completed":
            try await finalizeCompletedBatch(snapshot, session: session, apiKey: apiKey)
        case "failed", "expired", "cancelled":
            let message = snapshot.errors.first ?? detailTextForBatchStatus(
                status: snapshot.status,
                requestCounts: snapshot.requestCounts
            )
            markBatchSubmissionsAsFailed(in: session, batchID: snapshot.batchID, message: message)
        default:
            markBatchSubmissions(
                in: session,
                batchID: snapshot.batchID,
                detail: detailTextForBatchStatus(
                    status: snapshot.status,
                    requestCounts: snapshot.requestCounts
                )
            )
        }
    }

    private static func finalizeCompletedBatch(
        _ snapshot: OpenAIBatchStatusSnapshot,
        session: GradingSession,
        apiKey: String
    ) async throws {
        let pendingSubmissions = session.submissions.filter {
            $0.isProcessingPending && $0.remoteBatchID == snapshot.batchID
        }
        guard !pendingSubmissions.isEmpty else { return }

        switch pendingSubmissions.compactMap(\.batchStage).first ?? .grading {
        case .queued:
            return
        case .grading:
            try await finalizeCompletedGradingBatch(
                snapshot,
                session: session,
                pendingSubmissions: pendingSubmissions,
                apiKey: apiKey
            )
        case .validating:
            try await finalizeCompletedValidationBatch(
                snapshot,
                session: session,
                pendingSubmissions: pendingSubmissions,
                apiKey: apiKey
            )
        case .regrading:
            try await finalizeCompletedRegradingBatch(
                snapshot,
                session: session,
                pendingSubmissions: pendingSubmissions,
                apiKey: apiKey
            )
        }
    }

    private static func finalizeCompletedGradingBatch(
        _ snapshot: OpenAIBatchStatusSnapshot,
        session: GradingSession,
        pendingSubmissions: [StudentSubmission],
        apiKey: String
    ) async throws {
        let results = try await fetchSubmissionBatchResults(
            snapshot: snapshot,
            modelID: session.gradingModelID,
            apiKey: apiKey
        )
        let errors = try await fetchBatchErrors(snapshot: snapshot, apiKey: apiKey)
        let resultsByID = Dictionary(uniqueKeysWithValues: results.map { ($0.customID, $0) })

        for submission in pendingSubmissions {
            guard let requestID = submission.remoteBatchRequestID else {
                markSubmissionFailed(
                    submission,
                    session: session,
                    message: "This batch submission is missing its request identifier."
                )
                continue
            }

            if let result = resultsByID[requestID] {
                recordUsage(result.usage, in: session, apiKey: apiKey)
                submission.setLatestSubmissionPayload(result.payload)
                submission.setLatestValidationPayload(nil)
                submission.updateDebugInfo { info in
                    info.latestBatchOutputLineJSON = result.rawLineJSON
                    info.latestBatchErrorLineJSON = nil
                    info.latestLookupSummary = nil
                }

                if session.validationEnabledResolved {
                    queueSubmissionForBatchStage(
                        submission,
                        stage: .validating,
                        attempt: 1,
                        detail: "Queued for validation pass 1."
                    )
                } else {
                    completeSubmission(
                        submission,
                        session: session,
                        from: result.payload,
                        validationNeedsReview: false,
                        reviewMessage: nil
                    )
                }
            } else if let error = errors.first(where: { $0.customID == requestID }) {
                markSubmissionFailed(submission, session: session, message: error.message)
                submission.updateDebugInfo { info in
                    info.latestBatchErrorLineJSON = error.rawLineJSON
                    info.latestLookupSummary = nil
                }
            } else {
                markSubmissionFailed(
                    submission,
                    session: session,
                    message: "OpenAI completed the batch but did not return a result for this submission."
                )
                submission.updateDebugInfo { info in
                    info.latestLookupSummary = missingBatchResultSummary(
                        requestID: requestID,
                        results: results.map(\.customID),
                        errors: errors.map(\.customID)
                    )
                }
            }
        }
    }

    private static func finalizeCompletedValidationBatch(
        _ snapshot: OpenAIBatchStatusSnapshot,
        session: GradingSession,
        pendingSubmissions: [StudentSubmission],
        apiKey: String
    ) async throws {
        let results = try await fetchValidationBatchResults(
            snapshot: snapshot,
            modelID: session.validationModelIDResolved,
            apiKey: apiKey
        )
        let errors = try await fetchBatchErrors(snapshot: snapshot, apiKey: apiKey)
        let resultsByID = Dictionary(uniqueKeysWithValues: results.map { ($0.customID, $0) })

        for submission in pendingSubmissions {
            guard let requestID = submission.remoteBatchRequestID else {
                finalizeSubmissionWithValidationReview(
                    submission,
                    session: session,
                    message: "This validation batch submission is missing its request identifier."
                )
                continue
            }

            if let result = resultsByID[requestID] {
                recordUsage(result.usage, in: session, apiKey: apiKey)
                submission.setLatestValidationPayload(result.payload)
                submission.updateDebugInfo { info in
                    info.latestBatchOutputLineJSON = result.rawLineJSON
                    info.latestBatchErrorLineJSON = nil
                    info.latestLookupSummary = nil
                }

                if result.payload.isGradingCorrect {
                    guard let payload = submission.latestSubmissionPayload() else {
                        markSubmissionFailed(
                            submission,
                            session: session,
                            message: "Validation completed but the latest grading payload was missing."
                        )
                        continue
                    }
                    completeSubmission(
                        submission,
                        session: session,
                        from: payload,
                        validationNeedsReview: false,
                        reviewMessage: nil
                    )
                } else if submission.currentBatchAttemptNumber >= session.validationMaxAttemptsResolved {
                    let validationAttemptLabel = session.validationMaxAttemptsResolved == 1
                        ? "1 validation attempt"
                        : "\(session.validationMaxAttemptsResolved) validation attempts"
                    finalizeSubmissionWithValidationReview(
                        submission,
                        session: session,
                        message: "Automated validation could not fully confirm this grading after \(validationAttemptLabel)."
                    )
                } else {
                    queueSubmissionForBatchStage(
                        submission,
                        stage: .regrading,
                        attempt: submission.currentBatchAttemptNumber,
                        detail: "Queued for regrade pass \(submission.currentBatchAttemptNumber) after validation pass \(submission.currentBatchAttemptNumber)."
                    )
                }
            } else if let error = errors.first(where: { $0.customID == requestID }) {
                finalizeSubmissionWithValidationReview(
                    submission,
                    session: session,
                    message: "Validation batch could not finish automatically. \(error.message)"
                )
                submission.updateDebugInfo { info in
                    info.latestBatchErrorLineJSON = error.rawLineJSON
                    info.latestLookupSummary = nil
                }
            } else {
                finalizeSubmissionWithValidationReview(
                    submission,
                    session: session,
                    message: "OpenAI completed the validation batch but did not return a result for this submission."
                )
                submission.updateDebugInfo { info in
                    info.latestLookupSummary = missingBatchResultSummary(
                        requestID: requestID,
                        results: results.map(\.customID),
                        errors: errors.map(\.customID)
                    )
                }
            }
        }
    }

    private static func finalizeCompletedRegradingBatch(
        _ snapshot: OpenAIBatchStatusSnapshot,
        session: GradingSession,
        pendingSubmissions: [StudentSubmission],
        apiKey: String
    ) async throws {
        let results = try await fetchSubmissionBatchResults(
            snapshot: snapshot,
            modelID: session.gradingModelID,
            apiKey: apiKey
        )
        let errors = try await fetchBatchErrors(snapshot: snapshot, apiKey: apiKey)
        let resultsByID = Dictionary(uniqueKeysWithValues: results.map { ($0.customID, $0) })

        for submission in pendingSubmissions {
            guard let requestID = submission.remoteBatchRequestID else {
                finalizeSubmissionWithValidationReview(
                    submission,
                    session: session,
                    message: "This regrade batch submission is missing its request identifier."
                )
                continue
            }

            if let result = resultsByID[requestID] {
                recordUsage(result.usage, in: session, apiKey: apiKey)
                submission.setLatestSubmissionPayload(result.payload)
                submission.setLatestValidationPayload(nil)
                submission.updateDebugInfo { info in
                    info.latestBatchOutputLineJSON = result.rawLineJSON
                    info.latestBatchErrorLineJSON = nil
                    info.latestLookupSummary = nil
                }
                queueSubmissionForBatchStage(
                    submission,
                    stage: .validating,
                    attempt: submission.currentBatchAttemptNumber + 1,
                    detail: "Queued for validation pass \(submission.currentBatchAttemptNumber + 1)."
                )
            } else if let error = errors.first(where: { $0.customID == requestID }) {
                finalizeSubmissionWithValidationReview(
                    submission,
                    session: session,
                    message: "Regrade batch could not finish automatically. \(error.message)"
                )
                submission.updateDebugInfo { info in
                    info.latestBatchErrorLineJSON = error.rawLineJSON
                    info.latestLookupSummary = nil
                }
            } else {
                finalizeSubmissionWithValidationReview(
                    submission,
                    session: session,
                    message: "OpenAI completed the regrade batch but did not return a result for this submission."
                )
                submission.updateDebugInfo { info in
                    info.latestLookupSummary = missingBatchResultSummary(
                        requestID: requestID,
                        results: results.map(\.customID),
                        errors: errors.map(\.customID)
                    )
                }
            }
        }
    }

    private static func submitQueuedBatchPipelineStages(
        for session: GradingSession,
        apiKey: String
    ) async throws {
        try await submitQueuedValidationBatch(for: session, apiKey: apiKey)
        try await submitQueuedRegradingBatch(for: session, apiKey: apiKey)
    }

    private static func submitQueuedValidationBatch(
        for session: GradingSession,
        apiKey: String
    ) async throws {
        let queued = session.submissions.filter {
            $0.isProcessingPending && !$0.hasRemoteBatchInFlight && $0.batchStage == .validating
        }
        guard !queued.isEmpty else { return }

        let inputs = queued.compactMap { submission -> OpenAIBatchValidationInput? in
            guard
                let pageFileURLs = ensureSubmissionScanFileURLs(for: submission),
                let payload = submission.latestSubmissionPayload()
            else {
                finalizeSubmissionWithValidationReview(
                    submission,
                    session: session,
                    message: "Validation batch could not be created because the saved grading payload or page scans were missing."
                )
                return nil
            }

            let requestID = "validate-\(submission.id.uuidString)-\(UUID().uuidString)"
            submission.remoteBatchRequestID = requestID
            return OpenAIBatchValidationInput(
                customID: requestID,
                pageFileURLs: pageFileURLs,
                candidateGrading: payload
            )
        }
        guard !inputs.isEmpty else { return }

        let creation = try await OpenAIService.shared.createSubmissionValidationBatch(
            apiKey: apiKey,
            modelID: session.validationModelIDResolved,
            rubric: session.sortedQuestions.map(\.snapshot),
            overallRules: session.overallGradingRules,
            submissions: inputs,
            integerPointsOnly: session.integerPointsOnlyEnabled,
            relaxedGradingMode: session.relaxedGradingModeEnabled,
            reasoningEffort: session.validationReasoningEffort,
            verbosity: session.validationVerbosity
        )

        for submission in queued where submission.remoteBatchRequestID != nil {
            submission.remoteBatchID = creation.batchID
            submission.processingDetail = "Validation pass \(submission.currentBatchAttemptNumber) batch submitted. \(detailTextForBatchStatus(status: creation.status, requestCounts: nil))"
        }
    }

    private static func submitQueuedRegradingBatch(
        for session: GradingSession,
        apiKey: String
    ) async throws {
        let queued = session.submissions.filter {
            $0.isProcessingPending && !$0.hasRemoteBatchInFlight && $0.batchStage == .regrading
        }
        guard !queued.isEmpty else { return }

        let inputs = queued.compactMap { submission -> OpenAIBatchRegradeInput? in
            guard
                let pageFileURLs = ensureSubmissionScanFileURLs(for: submission),
                let latestPayload = submission.latestSubmissionPayload(),
                let validationPayload = submission.latestValidationPayload()
            else {
                finalizeSubmissionWithValidationReview(
                    submission,
                    session: session,
                    message: "Regrade batch could not be created because the saved grading or validation context was missing."
                )
                return nil
            }

            let requestID = "regrade-\(submission.id.uuidString)-\(UUID().uuidString)"
            submission.remoteBatchRequestID = requestID
            return OpenAIBatchRegradeInput(
                customID: requestID,
                pageFileURLs: pageFileURLs,
                previousGrading: latestPayload,
                validatorFeedback: validationPayload
            )
        }
        guard !inputs.isEmpty else { return }

        let creation = try await OpenAIService.shared.createSubmissionRegradingBatch(
            apiKey: apiKey,
            modelID: session.gradingModelID,
            rubric: session.sortedQuestions.map(\.snapshot),
            overallRules: session.overallGradingRules,
            submissions: inputs,
            integerPointsOnly: session.integerPointsOnlyEnabled,
            relaxedGradingMode: session.relaxedGradingModeEnabled,
            reasoningEffort: session.gradingReasoningEffort,
            verbosity: session.gradingVerbosity
        )

        for submission in queued where submission.remoteBatchRequestID != nil {
            submission.remoteBatchID = creation.batchID
            submission.processingDetail = "Regrade pass \(submission.currentBatchAttemptNumber) batch submitted. \(detailTextForBatchStatus(status: creation.status, requestCounts: nil))"
        }
    }

    private static func queueSubmissionForBatchStage(
        _ submission: StudentSubmission,
        stage: StudentSubmissionBatchStage,
        attempt: Int,
        detail: String
    ) {
        submission.processingStateRaw = StudentSubmissionProcessingState.pending.rawValue
        submission.batchStageRaw = stage.rawValue
        submission.batchAttemptNumber = attempt
        submission.remoteBatchID = nil
        submission.remoteBatchRequestID = nil
        submission.processingDetail = detail
    }

    private static func completeSubmission(
        _ submission: StudentSubmission,
        session: GradingSession,
        from payload: SubmissionPayload,
        validationNeedsReview: Bool,
        reviewMessage: String?
    ) {
        var draft = SubmissionDraft.from(
            payload: payload,
            rubricSnapshots: session.sortedQuestions.map(\.snapshot),
            pageData: submission.scans(),
            integerPointsOnly: session.integerPointsOnlyEnabled
        )
        .normalized(integerPointsOnly: session.integerPointsOnlyEnabled)

        if validationNeedsReview {
            draft.validationNeedsReview = true
            draft.overallNotes = [
                reviewMessage,
                Optional(draft.overallNotes),
            ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        }

        submission.studentName = draft.studentName.trimmingCharacters(in: .whitespacesAndNewlines)
        submission.nameNeedsReview = draft.nameNeedsReview
        submission.validationNeedsReview = draft.validationNeedsReview
        submission.overallNotes = draft.overallNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        submission.teacherReviewed = false
        submission.processingStateRaw = StudentSubmissionProcessingState.completed.rawValue
        submission.processingDetail = nil
        submission.setQuestionGrades(draft.grades)
        submission.clearBatchPipelineState()
    }

    private static func finalizeSubmissionWithValidationReview(
        _ submission: StudentSubmission,
        session: GradingSession,
        message: String
    ) {
        if let payload = submission.latestSubmissionPayload() {
            completeSubmission(
                submission,
                session: session,
                from: payload,
                validationNeedsReview: true,
                reviewMessage: message
            )
        } else {
            markSubmissionFailed(submission, session: session, message: message)
        }
    }

    private static func ensureSubmissionScanFileURLs(for submission: StudentSubmission) -> [URL]? {
        if let existing = submission.scanFileURLs(), !existing.isEmpty {
            return existing
        }

        let pages = submission.scans()
        guard !pages.isEmpty else { return nil }
        submission.setScans(pages)
        return submission.scanFileURLs()
    }

    private static func markBatchSubmissions(
        in session: GradingSession,
        batchID: String,
        detail: String
    ) {
        for submission in session.submissions where submission.isProcessingPending && submission.remoteBatchID == batchID {
            submission.processingDetail = stagePrefixedDetail(for: submission, detail: detail)
        }
    }

    private static func markBatchSubmissionsAsFailed(
        in session: GradingSession,
        batchID: String,
        message: String
    ) {
        for submission in session.submissions where submission.isProcessingPending && submission.remoteBatchID == batchID {
            markSubmissionFailed(submission, session: session, message: message)
        }
    }

    private static func markSubmissionFailed(
        _ submission: StudentSubmission,
        session: GradingSession,
        message: String
    ) {
        submission.processingStateRaw = StudentSubmissionProcessingState.failed.rawValue
        submission.batchStageRaw = nil
        submission.batchAttemptNumber = nil
        submission.remoteBatchID = nil
        submission.remoteBatchRequestID = nil
        submission.processingDetail = message
        submission.overallNotes = message
        submission.teacherReviewed = false
        submission.validationNeedsReview = false
        submission.setLatestSubmissionPayload(nil)
        submission.setLatestValidationPayload(nil)
        submission.setQuestionGrades([])
        submission.totalScore = 0
        submission.maxScore = session.totalPossiblePoints
    }

    private static func fetchSubmissionBatchResults(
        snapshot: OpenAIBatchStatusSnapshot,
        modelID: String,
        apiKey: String
    ) async throws -> [OpenAIBatchSubmissionResult<SubmissionPayload>] {
        guard let outputFileID = snapshot.outputFileID else { return [] }
        return try await OpenAIService.shared.fetchSubmissionBatchResults(
            apiKey: apiKey,
            modelID: modelID,
            outputFileID: outputFileID
        )
    }

    private static func fetchAnswerKeyBatchResults(
        snapshot: OpenAIBatchStatusSnapshot,
        modelID: String,
        apiKey: String
    ) async throws -> [OpenAIBatchSubmissionResult<MasterExamPayload>] {
        guard let outputFileID = snapshot.outputFileID else { return [] }
        return try await OpenAIService.shared.fetchAnswerKeyBatchResults(
            apiKey: apiKey,
            modelID: modelID,
            outputFileID: outputFileID
        )
    }

    private static func fetchValidationBatchResults(
        snapshot: OpenAIBatchStatusSnapshot,
        modelID: String,
        apiKey: String
    ) async throws -> [OpenAIBatchSubmissionResult<GradingValidationPayload>] {
        guard let outputFileID = snapshot.outputFileID else { return [] }
        return try await OpenAIService.shared.fetchValidationBatchResults(
            apiKey: apiKey,
            modelID: modelID,
            outputFileID: outputFileID
        )
    }

    private static func fetchBatchErrors(
        snapshot: OpenAIBatchStatusSnapshot,
        apiKey: String
    ) async throws -> [OpenAIBatchSubmissionError] {
        guard let errorFileID = snapshot.errorFileID else { return [] }
        return try await OpenAIService.shared.fetchBatchErrors(
            apiKey: apiKey,
            errorFileID: errorFileID
        )
    }

    private static func recordUsage(_ usage: OpenAIUsageSummary?, in session: GradingSession, apiKey: String) {
        guard let usage else { return }
        session.estimatedCostUSD = (session.estimatedCostUSD ?? 0) + usage.estimatedCostUSD
        if session.apiKeyFingerprint == nil {
            session.apiKeyFingerprint = APIKeyIdentity.fingerprint(for: apiKey)
        }
    }

    private static func detailTextForBatchStatus(
        status: String,
        requestCounts: OpenAIBatchRequestCounts?
    ) -> String {
        let countSuffix: String
        if let requestCounts {
            let remaining = max(requestCounts.total - requestCounts.completed - requestCounts.failed, 0)
            countSuffix = " \(requestCounts.completed) completed, \(requestCounts.failed) failed, \(remaining) remaining."
        } else {
            countSuffix = ""
        }

        switch status {
        case "validating":
            return "OpenAI is validating the uploaded batch input.\(countSuffix)"
        case "in_progress":
            return "OpenAI is processing the batch.\(countSuffix)"
        case "finalizing":
            return "OpenAI is preparing the batch output files.\(countSuffix)"
        case "completed":
            return "Batch completed."
        case "expired":
            return "OpenAI could not finish this batch within the 24-hour window."
        case "cancelled":
            return "This batch was cancelled."
        case "failed":
            return "OpenAI rejected this batch job."
        default:
            return "Batch status: \(status).\(countSuffix)"
        }
    }

    private static func stagePrefixedDetail(for submission: StudentSubmission, detail: String) -> String {
        let prefix: String?
        switch submission.batchStage {
        case .queued:
            prefix = "Queued until rubric approval."
        case .grading:
            prefix = "Initial grading."
        case .validating:
            prefix = "Validation pass \(submission.currentBatchAttemptNumber)."
        case .regrading:
            prefix = "Regrade pass \(submission.currentBatchAttemptNumber)."
        case nil:
            prefix = nil
        }

        return [prefix, detail]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func storeBatchStatusDebug(
        _ snapshot: OpenAIBatchStatusSnapshot,
        session: GradingSession,
        batchID: String
    ) {
        guard
            let data = try? JSONEncoder.prettyPrinted.encode(snapshot),
            let text = String(data: data, encoding: .utf8)
        else {
            return
        }

        for submission in session.submissions where submission.remoteBatchID == batchID {
            submission.updateDebugInfo { info in
                info.batchStatusJSON = text
            }
        }
    }

    private static func missingBatchResultSummary(
        requestID: String,
        results: [String],
        errors: [String]
    ) -> String {
        let resultsText = results.isEmpty ? "(none)" : results.joined(separator: ", ")
        let errorsText = errors.isEmpty ? "(none)" : errors.joined(separator: ", ")
        return """
        No matching batch line was found for request id:
        \(requestID)

        Result custom_ids:
        \(resultsText)

        Error custom_ids:
        \(errorsText)
        """
    }
}
