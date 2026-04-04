import Foundation

final class OpenAIService: @unchecked Sendable {
    static let shared = OpenAIService()

    let session: URLSession
    let endpoint = URL(string: "https://api.openai.com/v1/responses")!
    let batchesEndpoint = URL(string: "https://api.openai.com/v1/batches")!
    let filesEndpoint = URL(string: "https://api.openai.com/v1/files")!
    let organizationCostsEndpoint = URL(string: "https://api.openai.com/v1/organization/costs")!
    let visionImageDetail = "high"

    init(session: URLSession = .shared) {
        self.session = session
    }

    func validateAPIKey(_ apiKey: String) async throws {
        let schema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "ok": [
                    "type": "boolean",
                ],
            ],
            "required": ["ok"],
        ]

        let _: OpenAIResult<SimpleValidationPayload> = try await performStructuredRequest(
            apiKey: apiKey,
            modelID: ModelCatalog.defaultGradingModel,
            schemaName: "api_key_validation",
            schema: schema,
            systemPrompt: "You validate whether the API connection is working.",
            userText: "Return ok=true.",
            images: []
        )
    }

    func generateAnswerKey(
        apiKey: String,
        modelID: String,
        sessionTitle: String,
        pageData: [Data],
        reasoningEffort: String?,
        verbosity: String?,
        serviceTier: String?,
        streamHandler: (@Sendable (OpenAIStreamEvent) async -> Void)? = nil
    ) async throws -> OpenAIResult<MasterExamPayload> {
        let definition = try makeAnswerKeyDefinition(sessionTitle: sessionTitle)

        return try await performStructuredRequest(
            apiKey: apiKey,
            modelID: modelID,
            schemaName: definition.schemaName,
            schema: definition.schema,
            systemPrompt: definition.systemPrompt,
            userText: definition.userText,
            images: pageData,
            reasoningEffort: reasoningEffort,
            verbosity: verbosity,
            serviceTier: serviceTier,
            streamHandler: streamHandler
        )
    }

    func gradeSubmission(
        apiKey: String,
        modelID: String,
        rubric: [RubricSnapshot],
        overallRules: String?,
        pageData: [Data],
        integerPointsOnly: Bool,
        relaxedGradingMode: Bool,
        previousGrading: SubmissionPayload? = nil,
        validatorFeedback: GradingValidationPayload? = nil,
        reasoningEffort: String?,
        verbosity: String?,
        serviceTier: String?,
        streamHandler: (@Sendable (OpenAIStreamEvent) async -> Void)? = nil
    ) async throws -> OpenAIResult<SubmissionPayload> {
        let definition = try makeSubmissionGradeDefinition(
            rubric: rubric,
            overallRules: overallRules,
            integerPointsOnly: integerPointsOnly,
            relaxedGradingMode: relaxedGradingMode,
            previousGrading: previousGrading,
            validatorFeedback: validatorFeedback
        )

        return try await performStructuredRequest(
            apiKey: apiKey,
            modelID: modelID,
            schemaName: definition.schemaName,
            schema: definition.schema,
            systemPrompt: definition.systemPrompt,
            userText: definition.userText,
            images: pageData,
            reasoningEffort: reasoningEffort,
            verbosity: verbosity,
            serviceTier: serviceTier,
            streamHandler: streamHandler
        )
    }

    func validateSubmissionGrade(
        apiKey: String,
        modelID: String,
        rubric: [RubricSnapshot],
        overallRules: String?,
        candidateGrading: SubmissionPayload,
        pageData: [Data],
        integerPointsOnly: Bool,
        relaxedGradingMode: Bool,
        reasoningEffort: String?,
        verbosity: String?,
        serviceTier: String?,
        streamHandler: (@Sendable (OpenAIStreamEvent) async -> Void)? = nil
    ) async throws -> OpenAIResult<GradingValidationPayload> {
        let definition = try makeSubmissionValidationDefinition(
            rubric: rubric,
            overallRules: overallRules,
            candidateGrading: candidateGrading,
            integerPointsOnly: integerPointsOnly,
            relaxedGradingMode: relaxedGradingMode
        )

        return try await performStructuredRequest(
            apiKey: apiKey,
            modelID: modelID,
            schemaName: definition.schemaName,
            schema: definition.schema,
            systemPrompt: definition.systemPrompt,
            userText: definition.userText,
            images: pageData,
            reasoningEffort: reasoningEffort,
            verbosity: verbosity,
            serviceTier: serviceTier,
            streamHandler: streamHandler
        )
    }

    func createSubmissionGradingBatch(
        apiKey: String,
        modelID: String,
        rubric: [RubricSnapshot],
        overallRules: String?,
        submissions: [OpenAIBatchSubmissionInput],
        integerPointsOnly: Bool,
        relaxedGradingMode: Bool,
        reasoningEffort: String?,
        verbosity: String?
    ) async throws -> OpenAIBatchCreationResult {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw OpenAIServiceError.missingAPIKey }

        let definition = try makeSubmissionGradeDefinition(
            rubric: rubric,
            overallRules: overallRules,
            integerPointsOnly: integerPointsOnly,
            relaxedGradingMode: relaxedGradingMode,
            previousGrading: nil,
            validatorFeedback: nil
        )

        let jsonlFileURL = try makeSubmissionBatchJSONLFile(
            submissions: submissions,
            modelID: modelID,
            definition: definition,
            reasoningEffort: reasoningEffort,
            verbosity: verbosity
        )
        return try await createStructuredBatch(
            apiKey: trimmedKey,
            jsonlFileURL: jsonlFileURL,
            filenamePrefix: "homework-grader"
        )
    }

    func createAnswerKeyBatch(
        apiKey: String,
        modelID: String,
        sessionTitle: String,
        submissions: [OpenAIBatchAnswerKeyInput],
        reasoningEffort: String?,
        verbosity: String?
    ) async throws -> OpenAIBatchCreationResult {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw OpenAIServiceError.missingAPIKey }

        let jsonlFileURL = try makeAnswerKeyBatchJSONLFile(
            submissions: submissions,
            modelID: modelID,
            sessionTitle: sessionTitle,
            reasoningEffort: reasoningEffort,
            verbosity: verbosity
        )
        return try await createStructuredBatch(
            apiKey: trimmedKey,
            jsonlFileURL: jsonlFileURL,
            filenamePrefix: "hgrader-answer-key"
        )
    }

    func createSubmissionValidationBatch(
        apiKey: String,
        modelID: String,
        rubric: [RubricSnapshot],
        overallRules: String?,
        submissions: [OpenAIBatchValidationInput],
        integerPointsOnly: Bool,
        relaxedGradingMode: Bool,
        reasoningEffort: String?,
        verbosity: String?
    ) async throws -> OpenAIBatchCreationResult {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw OpenAIServiceError.missingAPIKey }

        let jsonlFileURL = try makeSubmissionValidationBatchJSONLFile(
            submissions: submissions,
            modelID: modelID,
            rubric: rubric,
            overallRules: overallRules,
            integerPointsOnly: integerPointsOnly,
            relaxedGradingMode: relaxedGradingMode,
            reasoningEffort: reasoningEffort,
            verbosity: verbosity
        )
        return try await createStructuredBatch(
            apiKey: trimmedKey,
            jsonlFileURL: jsonlFileURL,
            filenamePrefix: "hgrader-validation"
        )
    }

    func createSubmissionRegradingBatch(
        apiKey: String,
        modelID: String,
        rubric: [RubricSnapshot],
        overallRules: String?,
        submissions: [OpenAIBatchRegradeInput],
        integerPointsOnly: Bool,
        relaxedGradingMode: Bool,
        reasoningEffort: String?,
        verbosity: String?
    ) async throws -> OpenAIBatchCreationResult {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw OpenAIServiceError.missingAPIKey }

        let jsonlFileURL = try makeSubmissionRegradingBatchJSONLFile(
            submissions: submissions,
            modelID: modelID,
            rubric: rubric,
            overallRules: overallRules,
            integerPointsOnly: integerPointsOnly,
            relaxedGradingMode: relaxedGradingMode,
            reasoningEffort: reasoningEffort,
            verbosity: verbosity
        )
        return try await createStructuredBatch(
            apiKey: trimmedKey,
            jsonlFileURL: jsonlFileURL,
            filenamePrefix: "hgrader-regrade"
        )
    }

    func fetchValidationBatchResults(
        apiKey: String,
        modelID: String,
        outputFileID: String
    ) async throws -> [OpenAIBatchSubmissionResult<GradingValidationPayload>] {
        let objects = try await fetchJSONLLines(apiKey: apiKey, fileID: outputFileID)
        return try objects.map { object in
            guard let customID = object["custom_id"] as? String else {
                throw OpenAIServiceError.invalidResponse("Batch output is missing a custom_id.")
            }

            if let errorMessage = batchErrorMessage(from: object) {
                throw OpenAIServiceError.invalidResponse("Batch output returned an error for \(customID): \(errorMessage)")
            }

            guard
                let response = object["response"] as? [String: Any],
                let body = response["body"] as? [String: Any]
            else {
                throw OpenAIServiceError.invalidResponse("Batch output did not include a response body for \(customID).")
            }

            let outputText = try extractOutputText(from: body)
            let payloadData = Data(outputText.utf8)
            let payload = try JSONDecoder().decode(GradingValidationPayload.self, from: payloadData)
            let usage = extractUsage(from: body, modelID: modelID).map {
                OpenAIUsageSummary(
                    inputTokens: $0.inputTokens,
                    outputTokens: $0.outputTokens,
                    cachedInputTokens: $0.cachedInputTokens,
                    estimatedCostUSD: $0.estimatedCostUSD * 0.5
                )
            }

            return OpenAIBatchSubmissionResult(
                customID: customID,
                payload: payload,
                usage: usage,
                rawLineJSON: try? stringifyJSONObject(object)
            )
        }
    }

    func fetchBatchStatus(apiKey: String, batchID: String) async throws -> OpenAIBatchStatusSnapshot {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw OpenAIServiceError.missingAPIKey }

        let url = batchesEndpoint.appendingPathComponent(batchID)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 60
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        let payload = try decodeHTTPPayload(data: data, response: response)
        let batch = try JSONDecoder().decode(OpenAIBatchObject.self, from: payload)

        let counts = batch.requestCounts.map {
            OpenAIBatchRequestCounts(
                total: $0.total,
                completed: $0.completed,
                failed: $0.failed
            )
        }

        return OpenAIBatchStatusSnapshot(
            batchID: batch.id,
            status: batch.status,
            outputFileID: batch.outputFileID,
            errorFileID: batch.errorFileID,
            requestCounts: counts,
            errors: batch.errors?.data.compactMap(\.message) ?? []
        )
    }

    func fetchSubmissionBatchResults(
        apiKey: String,
        modelID: String,
        outputFileID: String
    ) async throws -> [OpenAIBatchSubmissionResult<SubmissionPayload>] {
        let objects = try await fetchJSONLLines(apiKey: apiKey, fileID: outputFileID)
        return try objects.map { object in
            guard let customID = object["custom_id"] as? String else {
                throw OpenAIServiceError.invalidResponse("Batch output is missing a custom_id.")
            }

            if let errorMessage = batchErrorMessage(from: object) {
                throw OpenAIServiceError.invalidResponse("Batch output returned an error for \(customID): \(errorMessage)")
            }

            guard
                let response = object["response"] as? [String: Any],
                let body = response["body"] as? [String: Any]
            else {
                throw OpenAIServiceError.invalidResponse("Batch output did not include a response body for \(customID).")
            }

            let outputText = try extractOutputText(from: body)
            let payloadData = Data(outputText.utf8)
            let payload = try JSONDecoder().decode(SubmissionPayload.self, from: payloadData)
            let usage = extractUsage(from: body, modelID: modelID).map {
                OpenAIUsageSummary(
                    inputTokens: $0.inputTokens,
                    outputTokens: $0.outputTokens,
                    cachedInputTokens: $0.cachedInputTokens,
                    estimatedCostUSD: $0.estimatedCostUSD * 0.5
                )
            }

            return OpenAIBatchSubmissionResult(
                customID: customID,
                payload: payload,
                usage: usage,
                rawLineJSON: try? stringifyJSONObject(object)
            )
        }
    }

    func fetchAnswerKeyBatchResults(
        apiKey: String,
        modelID: String,
        outputFileID: String
    ) async throws -> [OpenAIBatchSubmissionResult<MasterExamPayload>] {
        let objects = try await fetchJSONLLines(apiKey: apiKey, fileID: outputFileID)
        return try objects.map { object in
            guard let customID = object["custom_id"] as? String else {
                throw OpenAIServiceError.invalidResponse("Batch output is missing a custom_id.")
            }

            if let errorMessage = batchErrorMessage(from: object) {
                throw OpenAIServiceError.invalidResponse("Batch output returned an error for \(customID): \(errorMessage)")
            }

            guard
                let response = object["response"] as? [String: Any],
                let body = response["body"] as? [String: Any]
            else {
                throw OpenAIServiceError.invalidResponse("Batch output did not include a response body for \(customID).")
            }

            let outputText = try extractOutputText(from: body)
            let payloadData = Data(outputText.utf8)
            let payload = try JSONDecoder().decode(MasterExamPayload.self, from: payloadData)
            let usage = extractUsage(from: body, modelID: modelID).map {
                OpenAIUsageSummary(
                    inputTokens: $0.inputTokens,
                    outputTokens: $0.outputTokens,
                    cachedInputTokens: $0.cachedInputTokens,
                    estimatedCostUSD: $0.estimatedCostUSD * 0.5
                )
            }

            return OpenAIBatchSubmissionResult(
                customID: customID,
                payload: payload,
                usage: usage,
                rawLineJSON: try? stringifyJSONObject(object)
            )
        }
    }

    func fetchBatchErrors(
        apiKey: String,
        errorFileID: String
    ) async throws -> [OpenAIBatchSubmissionError] {
        let objects = try await fetchJSONLLines(apiKey: apiKey, fileID: errorFileID)
        return objects.compactMap { object in
            guard let customID = object["custom_id"] as? String else { return nil }
            let message = batchErrorMessage(from: object) ?? "OpenAI did not provide an error message for this batch request."
            return OpenAIBatchSubmissionError(
                customID: customID,
                message: message,
                rawLineJSON: try? stringifyJSONObject(object)
            )
        }
    }

    func fetchOrganizationTotalCost(apiKey: String) async throws -> OrganizationCostSummary {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw OpenAIServiceError.missingAPIKey }

        var nextPage: String?
        var total = 0.0
        var pageCount = 0

        repeat {
            var components = URLComponents(url: organizationCostsEndpoint, resolvingAgainstBaseURL: false)
            components?.queryItems = [
                URLQueryItem(name: "start_time", value: "1577836800"),
                URLQueryItem(name: "limit", value: "180"),
            ]

            if let nextPage {
                components?.queryItems?.append(URLQueryItem(name: "page", value: nextPage))
            }

            guard let url = components?.url else {
                throw OpenAIServiceError.invalidResponse("Unable to build the organization costs request.")
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 60
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw OpenAIServiceError.invalidResponse("OpenAI did not return an HTTP response.")
            }

            if !(200...299).contains(httpResponse.statusCode) {
                let defaultMessage = httpResponse.statusCode == 401 || httpResponse.statusCode == 403
                    ? "Organization-wide OpenAI costs require an admin API key."
                    : "OpenAI returned HTTP \(httpResponse.statusCode)."
                let message = parseErrorMessage(from: data) ?? defaultMessage
                throw OpenAIServiceError.httpError(httpResponse.statusCode, message)
            }

            let page = try JSONDecoder().decode(OrganizationCostsPage.self, from: data)
            total += page.data.flatMap(\.results).reduce(0) { $0 + $1.amount.value }
            nextPage = page.nextPage
            pageCount += 1
        } while nextPage != nil && pageCount < 30

        return OrganizationCostSummary(totalCostUSD: total, fetchedAt: .now)
    }
}
