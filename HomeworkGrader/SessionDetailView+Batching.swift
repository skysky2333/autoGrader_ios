import SwiftUI
import SwiftData

extension SessionDetailView {
    @MainActor
    func refreshPendingRubricGeneration(force: Bool) async {
        guard session.hasPendingRubricGeneration else { return }
        guard !isRefreshingPendingRubric else { return }
        guard hasAPIKey else { return }

        if
            !force,
            let lastPendingRubricRefreshAt,
            Date.now.timeIntervalSince(lastPendingRubricRefreshAt) < 12
        {
            return
        }

        guard
            let batchID = session.rubricRemoteBatchID,
            let requestID = session.rubricRemoteBatchRequestID
        else {
            session.markRubricGenerationFailed(message: "The saved answer key request is missing its batch metadata.")
            try? modelContext.save()
            return
        }

        let apiKey = KeychainStore.shared.string(for: AppSecrets.openAIKey) ?? ""
        isRefreshingPendingRubric = true
        lastPendingRubricRefreshAt = .now
        defer { isRefreshingPendingRubric = false }

        do {
            let snapshot = try await OpenAIService.shared.fetchBatchStatus(
                apiKey: apiKey,
                batchID: batchID
            )

            switch snapshot.status {
            case "completed":
                try await finalizeCompletedRubricBatch(
                    snapshot,
                    requestID: requestID,
                    apiKey: apiKey
                )
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

        try? modelContext.save()
    }

    @MainActor
    func finalizeCompletedRubricBatch(
        _ snapshot: OpenAIBatchStatusSnapshot,
        requestID: String,
        apiKey: String
    ) async throws {
        let results = try await fetchAnswerKeyBatchResults(snapshot: snapshot, apiKey: apiKey)
        let errors = try await fetchBatchErrors(snapshot: snapshot, apiKey: apiKey)
        let result = results.first { $0.customID == requestID }
        let errorMessage = errors.first { $0.customID == requestID }?.message

        if let result {
            recordUsage(result.usage, apiKey: apiKey)

            guard !result.payload.questions.isEmpty else {
                session.markRubricGenerationFailed(
                    message: "The model did not return any gradeable questions. Try rescanning the blank assignment."
                )
                return
            }

            session.setPendingRubricPayload(result.payload)
            session.clearRubricGenerationState()
            try? modelContext.save()

            openPendingRubricReview()
            await AppNotificationCoordinator.shared.notifyAnswerKeyReady(sessionTitle: session.title)
            feedbackCenter.show("Answer key ready for review.", tone: .info)
        } else if let errorMessage {
            session.markRubricGenerationFailed(message: errorMessage)
        } else {
            session.markRubricGenerationFailed(
                message: "OpenAI completed the answer key batch but did not return a result."
            )
        }
    }

    @MainActor
    func refreshPendingBatchSubmissions(force: Bool) async {
        guard hasRefreshablePendingBatchSubmissions else { return }
        guard !isRefreshingPendingBatches else { return }
        guard hasAPIKey else { return }

        if
            !force,
            let lastPendingBatchRefreshAt,
            Date.now.timeIntervalSince(lastPendingBatchRefreshAt) < 8
        {
            return
        }

        let apiKey = KeychainStore.shared.string(for: AppSecrets.openAIKey) ?? ""
        let batchIDs = Array(Set(session.submissions.compactMap { submission in
            submission.hasRemoteBatchInFlight ? submission.remoteBatchID : nil
        }))

        let summaryBeforeRefresh = batchRefreshSummary
        isRefreshingPendingBatches = true
        lastPendingBatchRefreshAt = .now
        defer { isRefreshingPendingBatches = false }

        for batchID in batchIDs {
            do {
                let snapshot = try await OpenAIService.shared.fetchBatchStatus(
                    apiKey: apiKey,
                    batchID: batchID
                )
                storeBatchStatusDebug(snapshot, batchID: batchID)
                try await applyBatchStatusSnapshot(snapshot, apiKey: apiKey)
            } catch {
                markBatchSubmissions(
                    batchID: batchID,
                    detail: "Unable to refresh batch status. \(error.localizedDescription)"
                )
            }
        }

        if !hasActivePendingBatchRequests {
            do {
                try await submitQueuedBatchPipelineStages(apiKey: apiKey)
            } catch {
                for submission in session.submissions where submission.isAwaitingRemoteProcessing && !submission.hasRemoteBatchInFlight {
                    submission.processingDetail = "Automatic batch submission failed. \(error.localizedDescription)"
                }
            }
        }

        try? modelContext.save()

        let summaryAfterRefresh = batchRefreshSummary
        if summaryBeforeRefresh.pending > 0 && summaryAfterRefresh.pending == 0 {
            await AppNotificationCoordinator.shared.notifyBatchGradingFinished(
                sessionTitle: session.title,
                completed: summaryAfterRefresh.completed,
                failed: summaryAfterRefresh.failed
            )
        }

        if force {
            feedbackCenter.show(batchRefreshFeedbackMessage(before: summaryBeforeRefresh, after: summaryAfterRefresh), tone: .info)
        }
    }

    @MainActor
    func applyBatchStatusSnapshot(_ snapshot: OpenAIBatchStatusSnapshot, apiKey: String) async throws {
        switch snapshot.status {
        case "completed":
            try await finalizeCompletedBatch(snapshot, apiKey: apiKey)
        case "failed", "expired", "cancelled":
            let message = snapshot.errors.first ?? detailTextForBatchStatus(
                status: snapshot.status,
                requestCounts: snapshot.requestCounts
            )
            markBatchSubmissionsAsFailed(batchID: snapshot.batchID, message: message)
        default:
            markBatchSubmissions(
                batchID: snapshot.batchID,
                detail: detailTextForBatchStatus(
                    status: snapshot.status,
                    requestCounts: snapshot.requestCounts
                )
            )
        }
    }

    @MainActor
    func finalizeCompletedBatch(_ snapshot: OpenAIBatchStatusSnapshot, apiKey: String) async throws {
        let pendingSubmissions = session.submissions.filter {
            $0.isProcessingPending && $0.remoteBatchID == snapshot.batchID
        }
        guard !pendingSubmissions.isEmpty else { return }

        switch pendingSubmissions.compactMap(\.batchStage).first ?? .grading {
        case .queued:
            return
        case .grading:
            try await finalizeCompletedGradingBatch(snapshot, pendingSubmissions: pendingSubmissions, apiKey: apiKey)
        case .validating:
            try await finalizeCompletedValidationBatch(snapshot, pendingSubmissions: pendingSubmissions, apiKey: apiKey)
        case .regrading:
            try await finalizeCompletedRegradingBatch(snapshot, pendingSubmissions: pendingSubmissions, apiKey: apiKey)
        }
    }

    @MainActor
    func finalizeCompletedGradingBatch(
        _ snapshot: OpenAIBatchStatusSnapshot,
        pendingSubmissions: [StudentSubmission],
        apiKey: String
    ) async throws {
        let results = try await fetchSubmissionBatchResults(snapshot: snapshot, modelID: session.gradingModelID, apiKey: apiKey)
        let errors = try await fetchBatchErrors(snapshot: snapshot, apiKey: apiKey)
        let resultsByID = Dictionary(uniqueKeysWithValues: results.map { ($0.customID, $0) })

        for submission in pendingSubmissions {
            guard let requestID = submission.remoteBatchRequestID else {
                markSubmissionFailed(submission, message: "This batch submission is missing its request identifier.")
                continue
            }

            if let result = resultsByID[requestID] {
                recordUsage(result.usage, apiKey: apiKey, persistChanges: false)
                submission.setLatestSubmissionPayload(result.payload)
                submission.setLatestValidationPayload(nil)
                recordBatchOutputDebug(submission, requestID: requestID, rawLineJSON: result.rawLineJSON)
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
                        from: result.payload,
                        validationNeedsReview: false,
                        reviewMessage: nil
                    )
                }
            } else if let error = errors.first(where: { $0.customID == requestID }) {
                markSubmissionFailed(submission, message: error.message)
                recordBatchErrorDebug(submission, requestID: requestID, rawLineJSON: error.rawLineJSON, message: error.message)
                submission.updateDebugInfo { info in
                    info.latestBatchErrorLineJSON = error.rawLineJSON
                    info.latestLookupSummary = nil
                }
            } else {
                markSubmissionFailed(
                    submission,
                    message: "OpenAI completed the batch but did not return a result for this submission."
                )
                let lookupSummary = missingBatchResultSummary(
                    requestID: requestID,
                    results: results.map(\.customID),
                    errors: errors.map(\.customID)
                )
                recordLookupDebug(submission, requestID: requestID, summary: lookupSummary)
                submission.updateDebugInfo { info in
                    info.latestLookupSummary = lookupSummary
                }
            }
        }
    }

    @MainActor
    func finalizeCompletedValidationBatch(
        _ snapshot: OpenAIBatchStatusSnapshot,
        pendingSubmissions: [StudentSubmission],
        apiKey: String
    ) async throws {
        let validationModelID = session.validationModelIDResolved
        let results = try await fetchValidationBatchResults(snapshot: snapshot, modelID: validationModelID, apiKey: apiKey)
        let errors = try await fetchBatchErrors(snapshot: snapshot, apiKey: apiKey)
        let resultsByID = Dictionary(uniqueKeysWithValues: results.map { ($0.customID, $0) })

        for submission in pendingSubmissions {
            guard let requestID = submission.remoteBatchRequestID else {
                finalizeSubmissionWithValidationReview(
                    submission,
                    message: "This validation batch submission is missing its request identifier."
                )
                continue
            }

            if let result = resultsByID[requestID] {
                recordUsage(result.usage, apiKey: apiKey, persistChanges: false)
                submission.setLatestValidationPayload(result.payload)
                recordBatchOutputDebug(submission, requestID: requestID, rawLineJSON: result.rawLineJSON)
                submission.updateDebugInfo { info in
                    info.latestBatchOutputLineJSON = result.rawLineJSON
                    info.latestBatchErrorLineJSON = nil
                    info.latestLookupSummary = nil
                }

                if result.payload.isGradingCorrect {
                    guard let payload = submission.latestSubmissionPayload() else {
                        markSubmissionFailed(
                            submission,
                            message: "Validation completed but the latest grading payload was missing."
                        )
                        continue
                    }
                    completeSubmission(
                        submission,
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
                    message: "Validation batch could not finish automatically. \(error.message)"
                )
                recordBatchErrorDebug(submission, requestID: requestID, rawLineJSON: error.rawLineJSON, message: error.message)
                submission.updateDebugInfo { info in
                    info.latestBatchErrorLineJSON = error.rawLineJSON
                    info.latestLookupSummary = nil
                }
            } else {
                let lookupSummary = missingBatchResultSummary(
                    requestID: requestID,
                    results: results.map(\.customID),
                    errors: errors.map(\.customID)
                )
                finalizeSubmissionWithValidationReview(
                    submission,
                    message: "OpenAI completed the validation batch but did not return a result for this submission."
                )
                recordLookupDebug(submission, requestID: requestID, summary: lookupSummary)
                submission.updateDebugInfo { info in
                    info.latestLookupSummary = lookupSummary
                }
            }
        }
    }

    @MainActor
    func finalizeCompletedRegradingBatch(
        _ snapshot: OpenAIBatchStatusSnapshot,
        pendingSubmissions: [StudentSubmission],
        apiKey: String
    ) async throws {
        let results = try await fetchSubmissionBatchResults(snapshot: snapshot, modelID: session.gradingModelID, apiKey: apiKey)
        let errors = try await fetchBatchErrors(snapshot: snapshot, apiKey: apiKey)
        let resultsByID = Dictionary(uniqueKeysWithValues: results.map { ($0.customID, $0) })

        for submission in pendingSubmissions {
            guard let requestID = submission.remoteBatchRequestID else {
                finalizeSubmissionWithValidationReview(
                    submission,
                    message: "This regrade batch submission is missing its request identifier."
                )
                continue
            }

            if let result = resultsByID[requestID] {
                recordUsage(result.usage, apiKey: apiKey, persistChanges: false)
                submission.setLatestSubmissionPayload(result.payload)
                submission.setLatestValidationPayload(nil)
                recordBatchOutputDebug(submission, requestID: requestID, rawLineJSON: result.rawLineJSON)
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
                    message: "Regrade batch could not finish automatically. \(error.message)"
                )
                recordBatchErrorDebug(submission, requestID: requestID, rawLineJSON: error.rawLineJSON, message: error.message)
                submission.updateDebugInfo { info in
                    info.latestBatchErrorLineJSON = error.rawLineJSON
                    info.latestLookupSummary = nil
                }
            } else {
                let lookupSummary = missingBatchResultSummary(
                    requestID: requestID,
                    results: results.map(\.customID),
                    errors: errors.map(\.customID)
                )
                finalizeSubmissionWithValidationReview(
                    submission,
                    message: "OpenAI completed the regrade batch but did not return a result for this submission."
                )
                recordLookupDebug(submission, requestID: requestID, summary: lookupSummary)
                submission.updateDebugInfo { info in
                    info.latestLookupSummary = lookupSummary
                }
            }
        }
    }

    func fetchSubmissionBatchResults(
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

    func fetchAnswerKeyBatchResults(
        snapshot: OpenAIBatchStatusSnapshot,
        apiKey: String
    ) async throws -> [OpenAIBatchSubmissionResult<MasterExamPayload>] {
        guard let outputFileID = snapshot.outputFileID else { return [] }
        return try await OpenAIService.shared.fetchAnswerKeyBatchResults(
            apiKey: apiKey,
            modelID: session.answerModelID,
            outputFileID: outputFileID
        )
    }

    func fetchValidationBatchResults(
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

    func fetchBatchErrors(
        snapshot: OpenAIBatchStatusSnapshot,
        apiKey: String
    ) async throws -> [OpenAIBatchSubmissionError] {
        guard let errorFileID = snapshot.errorFileID else { return [] }
        return try await OpenAIService.shared.fetchBatchErrors(
            apiKey: apiKey,
            errorFileID: errorFileID
        )
    }

    func submitQueuedBatchPipelineStages(apiKey: String) async throws {
        try await submitQueuedValidationBatch(apiKey: apiKey)
        try await submitQueuedRegradingBatch(apiKey: apiKey)
    }

    func submitQueuedValidationBatch(apiKey: String) async throws {
        let queued = session.submissions.filter {
            $0.isProcessingPending && !$0.hasRemoteBatchReservation && $0.batchStage == .validating
        }
        guard !queued.isEmpty else { return }

        var reservedSubmissions: [StudentSubmission] = []
        let inputs = queued.compactMap { submission -> OpenAIBatchValidationInput? in
            guard
                let pageFileURLs = ensureSubmissionScanFileURLs(for: submission),
                let payload = submission.latestSubmissionPayload()
            else {
                finalizeSubmissionWithValidationReview(
                    submission,
                    message: "Validation batch could not be created because the saved grading payload or page scans were missing."
                )
                return nil
            }
            let requestID = "validate-\(submission.id.uuidString)-\(UUID().uuidString)"
            submission.remoteBatchRequestID = requestID
            submission.processingDetail = "Preparing validation pass \(submission.currentBatchAttemptNumber) batch submission."
            reservedSubmissions.append(submission)
            return OpenAIBatchValidationInput(
                customID: requestID,
                pageFileURLs: pageFileURLs,
                candidateGrading: payload
            )
        }
        guard !inputs.isEmpty else { return }
        try? modelContext.save()

        let creation: OpenAIBatchCreationResult
        do {
            creation = try await OpenAIService.shared.createSubmissionValidationBatch(
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
        } catch {
            for submission in reservedSubmissions {
                submission.remoteBatchRequestID = nil
            }
            try? modelContext.save()
            throw error
        }

        for submission in queued where submission.remoteBatchRequestID != nil {
            submission.remoteBatchID = creation.batchID
            submission.processingDetail = "Validation pass \(submission.currentBatchAttemptNumber) batch submitted. \(detailTextForBatchStatus(status: creation.status, requestCounts: nil))"
            if let requestID = submission.remoteBatchRequestID {
                submission.appendDebugTraceEntry(
                    traceID: "batch-output-\(requestID)",
                    traceTitle: "Validation Pass \(submission.currentBatchAttemptNumber) • Batch Request",
                    entryTitle: "Submitted",
                    body: submission.processingDetail ?? "Validation batch submitted.",
                    kind: .outgoing,
                    mergeConsecutiveDuplicates: false
                )
            }
        }
    }

    func submitQueuedRegradingBatch(apiKey: String) async throws {
        let queued = session.submissions.filter {
            $0.isProcessingPending && !$0.hasRemoteBatchReservation && $0.batchStage == .regrading
        }
        guard !queued.isEmpty else { return }

        var reservedSubmissions: [StudentSubmission] = []
        let inputs = queued.compactMap { submission -> OpenAIBatchRegradeInput? in
            guard
                let pageFileURLs = ensureSubmissionScanFileURLs(for: submission),
                let latestPayload = submission.latestSubmissionPayload(),
                let validationPayload = submission.latestValidationPayload()
            else {
                finalizeSubmissionWithValidationReview(
                    submission,
                    message: "Regrade batch could not be created because the saved grading or validation context was missing."
                )
                return nil
            }
            let requestID = "regrade-\(submission.id.uuidString)-\(UUID().uuidString)"
            submission.remoteBatchRequestID = requestID
            submission.processingDetail = "Preparing regrade pass \(submission.currentBatchAttemptNumber) batch submission."
            reservedSubmissions.append(submission)
            return OpenAIBatchRegradeInput(
                customID: requestID,
                pageFileURLs: pageFileURLs,
                previousGrading: latestPayload,
                validatorFeedback: validationPayload
            )
        }
        guard !inputs.isEmpty else { return }
        try? modelContext.save()

        let creation: OpenAIBatchCreationResult
        do {
            creation = try await OpenAIService.shared.createSubmissionRegradingBatch(
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
        } catch {
            for submission in reservedSubmissions {
                submission.remoteBatchRequestID = nil
            }
            try? modelContext.save()
            throw error
        }

        for submission in queued where submission.remoteBatchRequestID != nil {
            submission.remoteBatchID = creation.batchID
            submission.processingDetail = "Regrade pass \(submission.currentBatchAttemptNumber) batch submitted. \(detailTextForBatchStatus(status: creation.status, requestCounts: nil))"
            if let requestID = submission.remoteBatchRequestID {
                submission.appendDebugTraceEntry(
                    traceID: "batch-output-\(requestID)",
                    traceTitle: "Regrade Pass \(submission.currentBatchAttemptNumber) • Batch Request",
                    entryTitle: "Submitted",
                    body: submission.processingDetail ?? "Regrade batch submitted.",
                    kind: .outgoing,
                    mergeConsecutiveDuplicates: false
                )
            }
        }
    }

    func queueSubmissionForBatchStage(
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
        submission.appendDebugTraceEntry(
            traceID: "pipeline-\(submission.id.uuidString)",
            traceTitle: "Pipeline",
            entryTitle: "Queued",
            body: detail,
            kind: .status
        )
    }

    func completeSubmission(
        _ submission: StudentSubmission,
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
        submission.needsAttention = draft.needsAttention
        submission.attentionReasonsText = draft.attentionReasonsText.trimmingCharacters(in: .whitespacesAndNewlines)
        submission.validationNeedsReview = draft.validationNeedsReview
        submission.overallNotes = draft.overallNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        submission.teacherReviewed = false
        submission.processingStateRaw = StudentSubmissionProcessingState.completed.rawValue
        submission.processingDetail = nil
        submission.setQuestionGrades(draft.grades)
        submission.clearBatchPipelineState()
    }

    func finalizeSubmissionWithValidationReview(
        _ submission: StudentSubmission,
        message: String
    ) {
        if let payload = submission.latestSubmissionPayload() {
            completeSubmission(
                submission,
                from: payload,
                validationNeedsReview: true,
                reviewMessage: message
            )
        } else {
            markSubmissionFailed(submission, message: message)
        }
    }

    func ensureSubmissionScanFileURLs(for submission: StudentSubmission) -> [URL]? {
        if let existing = submission.scanFileURLs(), !existing.isEmpty {
            return existing
        }
        let pages = submission.scans()
        guard !pages.isEmpty else { return nil }
        submission.setScans(pages)
        return submission.scanFileURLs()
    }

    func markBatchSubmissions(batchID: String, detail: String) {
        for submission in session.submissions where submission.isProcessingPending && submission.remoteBatchID == batchID {
            submission.processingDetail = stagePrefixedDetail(for: submission, detail: detail)
        }
    }

    func markBatchSubmissionsAsFailed(batchID: String, message: String) {
        for submission in session.submissions where submission.isProcessingPending && submission.remoteBatchID == batchID {
            markSubmissionFailed(submission, message: message)
        }
    }

    func markSubmissionFailed(_ submission: StudentSubmission, message: String) {
        submission.processingStateRaw = StudentSubmissionProcessingState.failed.rawValue
        submission.batchStageRaw = nil
        submission.batchAttemptNumber = nil
        submission.remoteBatchID = nil
        submission.remoteBatchRequestID = nil
        submission.processingDetail = message
        submission.overallNotes = message
        submission.teacherReviewed = false
        submission.needsAttention = false
        submission.attentionReasonsText = nil
        submission.validationNeedsReview = false
        submission.setLatestSubmissionPayload(nil)
        submission.setLatestValidationPayload(nil)
        submission.setQuestionGrades([])
        submission.totalScore = 0
        submission.maxScore = session.totalPossiblePoints
        submission.appendDebugTraceEntry(
            traceID: "pipeline-\(submission.id.uuidString)",
            traceTitle: "Pipeline",
            entryTitle: "Failed",
            body: message,
            kind: .error
        )
    }

    func detailTextForBatchStatus(
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

    func stagePrefixedDetail(for submission: StudentSubmission, detail: String) -> String {
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

    func storeBatchStatusDebug(_ snapshot: OpenAIBatchStatusSnapshot, batchID: String) {
        guard
            let data = try? JSONEncoder.prettyPrinted.encode(snapshot),
            let text = String(data: data, encoding: .utf8)
        else {
            return
        }

        for submission in session.submissions where submission.remoteBatchID == batchID {
            submission.appendDebugTraceEntry(
                traceID: "batch-status-\(batchID)",
                traceTitle: "Batch \(batchID) • Status",
                entryTitle: snapshot.status,
                body: text,
                kind: .batchStatus
            )
            submission.updateDebugInfo { info in
                info.batchStatusJSON = text
            }
        }
    }

    func missingBatchResultSummary(
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

    private func recordBatchOutputDebug(
        _ submission: StudentSubmission,
        requestID: String,
        rawLineJSON: String?
    ) {
        guard let rawLineJSON, !rawLineJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        submission.appendDebugTraceEntry(
            traceID: "batch-output-\(requestID)",
            traceTitle: "\(debugPhaseTitle(for: submission)) • Batch Output",
            entryTitle: "Received",
            body: rawLineJSON,
            kind: .batchOutput,
            mergeConsecutiveDuplicates: false
        )
    }

    private func recordBatchErrorDebug(
        _ submission: StudentSubmission,
        requestID: String,
        rawLineJSON: String?,
        message: String
    ) {
        if let rawLineJSON, !rawLineJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            submission.appendDebugTraceEntry(
                traceID: "batch-error-\(requestID)",
                traceTitle: "\(debugPhaseTitle(for: submission)) • Batch Error",
                entryTitle: "Error Line",
                body: rawLineJSON,
                kind: .batchError,
                mergeConsecutiveDuplicates: false
            )
        }
        submission.appendDebugTraceEntry(
            traceID: "batch-error-\(requestID)",
            traceTitle: "\(debugPhaseTitle(for: submission)) • Batch Error",
            entryTitle: "Error",
            body: message,
            kind: .error
        )
    }

    private func recordLookupDebug(
        _ submission: StudentSubmission,
        requestID: String,
        summary: String
    ) {
        submission.appendDebugTraceEntry(
            traceID: "batch-lookup-\(requestID)",
            traceTitle: "\(debugPhaseTitle(for: submission)) • Lookup",
            entryTitle: "Lookup Summary",
            body: summary,
            kind: .lookup,
            mergeConsecutiveDuplicates: false
        )
    }

    private func debugPhaseTitle(for submission: StudentSubmission) -> String {
        switch submission.batchStage {
        case .queued:
            return "Queued"
        case .grading:
            return "Initial Grading"
        case .validating:
            return "Validation Pass \(submission.currentBatchAttemptNumber)"
        case .regrading:
            return "Regrade Pass \(submission.currentBatchAttemptNumber)"
        case nil:
            return "Submission Debug"
        }
    }
}
