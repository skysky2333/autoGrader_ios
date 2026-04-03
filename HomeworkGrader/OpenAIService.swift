import Foundation

enum OpenAIServiceError: LocalizedError {
    case missingAPIKey
    case invalidResponse(String)
    case refusal(String)
    case httpError(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add your OpenAI API key in Settings before scanning or grading."
        case .invalidResponse(let message):
            return message
        case .refusal(let message):
            return message
        case .httpError(_, let message):
            return message
        }
    }
}

struct OpenAIUsageSummary: Sendable {
    let inputTokens: Int
    let outputTokens: Int
    let cachedInputTokens: Int
    let estimatedCostUSD: Double
}

struct OpenAIRequestPreview: Sendable {
    let modelID: String
    let schemaName: String
    let imageCount: Int
    let systemPromptPreview: String
    let userTextPreview: String

    var formattedText: String {
        [
            "Model: \(modelID)",
            "Schema: \(schemaName)",
            "Attached pages: \(imageCount)",
            "",
            "System prompt:",
            systemPromptPreview,
            "",
            "User payload:",
            userTextPreview,
        ]
        .joined(separator: "\n")
    }
}

enum OpenAIStreamEvent: Sendable {
    case preparing(OpenAIRequestPreview)
    case status(String)
    case responseCreated(String)
    case outputTextDelta(String)
    case outputTextDone(String)
    case completed
    case error(String)
}

struct OpenAIResult<Payload> {
    let payload: Payload
    let usage: OpenAIUsageSummary?
}

struct OrganizationCostSummary: Equatable, Sendable {
    let totalCostUSD: Double
    let fetchedAt: Date
}

struct OpenAIBatchSubmissionInput: Sendable {
    let customID: String
    let pageFileURLs: [URL]
}

struct OpenAIBatchCreationResult: Sendable {
    let batchID: String
    let status: String
}

struct OpenAIBatchStatusSnapshot: Sendable {
    let batchID: String
    let status: String
    let outputFileID: String?
    let errorFileID: String?
    let requestCounts: OpenAIBatchRequestCounts?
    let errors: [String]
}

struct OpenAIBatchRequestCounts: Sendable {
    let total: Int
    let completed: Int
    let failed: Int
}

struct OpenAIBatchSubmissionResult<Payload: Sendable>: Sendable {
    let customID: String
    let payload: Payload
    let usage: OpenAIUsageSummary?
}

struct OpenAIBatchSubmissionError: Sendable {
    let customID: String
    let message: String
}

private struct StructuredResponseDefinition {
    let schemaName: String
    let schema: [String: Any]
    let systemPrompt: String
    let userText: String
}

final class OpenAIService: @unchecked Sendable {
    static let shared = OpenAIService()

    private let session: URLSession
    private let endpoint = URL(string: "https://api.openai.com/v1/responses")!
    private let batchesEndpoint = URL(string: "https://api.openai.com/v1/batches")!
    private let filesEndpoint = URL(string: "https://api.openai.com/v1/files")!
    private let organizationCostsEndpoint = URL(string: "https://api.openai.com/v1/organization/costs")!
    private let visionImageDetail = "high"

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
        let schema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "assignment_title": ["type": "string"],
                "questions": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "properties": [
                            "question_id": ["type": "string"],
                            "display_label": ["type": "string"],
                            "prompt_text": ["type": "string"],
                            "ideal_answer": ["type": "string"],
                            "grading_criteria": ["type": "string"],
                            "page_references": [
                                "type": "array",
                                "items": ["type": "integer"],
                            ],
                        ],
                        "required": [
                            "question_id",
                            "display_label",
                            "prompt_text",
                            "ideal_answer",
                            "grading_criteria",
                            "page_references",
                        ],
                    ],
                ],
            ],
            "required": ["assignment_title", "questions"],
        ]

        let systemPrompt = """
        You are an expert teacher assistant.
        Analyze images of a blank assignment or exam and produce a teacher-reviewable answer key.
        Identify every distinct question in reading order across all pages.
        For each question, extract a concise prompt, write a detailed ideal answer or worked solution, and list grading criteria that a teacher can use later.
        Do not score questions. The teacher will set points manually.
        If parts of a page are unclear, still provide your best structured extraction and mention uncertainty inside grading_criteria.
        In prompt_text, ideal_answer, and grading_criteria:
        - keep normal prose as plain text
        - wrap every mathematical expression in $$...$$ or $...$
        - use only valid standard LaTeX inside those delimiters
        - never use single-dollar math delimiters
        - if you are unsure how to write an expression in LaTeX, use plain text instead of broken LaTeX
        """

        let userText = """
        Session title: \(sessionTitle)
        The attached pages are blank assignment pages in page order starting at page 1.
        Return one question object per gradeable question.
        """

        return try await performStructuredRequest(
            apiKey: apiKey,
            modelID: modelID,
            schemaName: "master_answer_key",
            schema: schema,
            systemPrompt: systemPrompt,
            userText: userText,
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
        let rubricString = String(decoding: try JSONEncoder.prettyPrinted.encode(rubric), as: UTF8.self)
        let candidateString = String(decoding: try JSONEncoder.prettyPrinted.encode(candidateGrading), as: UTF8.self)

        let schema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "is_grading_correct": ["type": "boolean"],
                "validator_summary": ["type": "string"],
                "issues": [
                    "type": "array",
                    "items": ["type": "string"],
                ],
            ],
            "required": ["is_grading_correct", "validator_summary", "issues"],
        ]

        let systemPrompt = """
        You are validating a grading decision for a student's submission.
        Review the student work from the attached images, the rubric, the session-wide grading rules, and the candidate grading JSON.
        Return is_grading_correct=true only if the candidate grading is correct.
        Return false if any awarded points, correctness flags, process judgment, or review flags should change.
        Be critical of OCR or reading mistakes. Check carefully for text mismatches, symbol mismatches, copied-answer mismatches, and especially student-name mismatches.
        For the student name, verify character by character.
        If the candidate name seems plausible but one or more characters are uncertain, student_name_needs_review should be true.
        Do not fail validation only because the name is uncertain if the candidate grading correctly marks the name for human review.
        Fail validation if the name appears materially wrong, or if the name is uncertain but the candidate grading failed to flag student_name_needs_review.
        Also check for mathematically equivalent answer forms that should still receive credit. Do not mark a grading wrong only because the student's answer is written in a different but equivalent form.
        Keep validator_summary concise and actionable so it can be used to regrade the submission if needed.
        In validator_summary and issues:
        - keep normal prose as plain text
        - wrap every mathematical expression in $$...$$ or $...$
        - use only valid standard LaTeX inside those delimiters
        - never use single-dollar math delimiters
        - if you are unsure how to write an expression in LaTeX, use plain text instead of broken LaTeX
        \(relaxedGradingMode ? "Relaxed grading mode is ON. A correct final answer should receive full credit even if intermediate work is minimal, omitted, or imperfect, unless the rubric explicitly requires process-based scoring." : "")
        \(integerPointsOnly ? "Scores must remain whole numbers." : "Fractional scores are allowed when justified by the rubric.")
        """

        let userText = """
        Validate the candidate grading below.

        SESSION-WIDE GRADING RULES:
        \(overallRules?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? overallRules! : "None provided.")

        RUBRIC JSON:
        \(rubricString)

        CANDIDATE GRADING JSON:
        \(candidateString)
        """

        return try await performStructuredRequest(
            apiKey: apiKey,
            modelID: modelID,
            schemaName: "grading_validation",
            schema: schema,
            systemPrompt: systemPrompt,
            userText: userText,
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
        defer { try? FileManager.default.removeItem(at: jsonlFileURL) }

        let fileID = try await uploadBatchInputFile(
            apiKey: trimmedKey,
            fileURL: jsonlFileURL,
            filename: "homework-grader-\(UUID().uuidString).jsonl"
        )

        var request = URLRequest(url: batchesEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "input_file_id": fileID,
                "endpoint": "/v1/responses",
                "completion_window": "24h",
            ],
            options: []
        )

        let (data, response) = try await session.data(for: request)
        let payload = try decodeHTTPPayload(data: data, response: response)
        let batch = try JSONDecoder().decode(OpenAIBatchObject.self, from: payload)

        return OpenAIBatchCreationResult(
            batchID: batch.id,
            status: batch.status
        )
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
                usage: usage
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
            return OpenAIBatchSubmissionError(customID: customID, message: message)
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

    private func makeSubmissionGradeDefinition(
        rubric: [RubricSnapshot],
        overallRules: String?,
        integerPointsOnly: Bool,
        relaxedGradingMode: Bool,
        previousGrading: SubmissionPayload?,
        validatorFeedback: GradingValidationPayload?
    ) throws -> StructuredResponseDefinition {
        let rubricData = try JSONEncoder.prettyPrinted.encode(rubric)
        let rubricString = String(decoding: rubricData, as: UTF8.self)
        let previousGradingString: String?
        if let previousGrading {
            previousGradingString = String(
                decoding: try JSONEncoder.prettyPrinted.encode(previousGrading),
                as: UTF8.self
            )
        } else {
            previousGradingString = nil
        }

        let validatorFeedbackString: String?
        if let validatorFeedback {
            validatorFeedbackString = String(
                decoding: try JSONEncoder.prettyPrinted.encode(validatorFeedback),
                as: UTF8.self
            )
        } else {
            validatorFeedbackString = nil
        }

        let schema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "student_name": ["type": "string"],
                "student_name_needs_review": ["type": "boolean"],
                "question_results": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "properties": [
                            "question_id": ["type": "string"],
                            "awarded_points": ["type": "number"],
                            "max_points": ["type": "number"],
                            "is_answer_correct": ["type": "boolean"],
                            "is_process_correct": ["type": "boolean"],
                            "feedback": ["type": "string"],
                            "needs_review": ["type": "boolean"],
                        ],
                        "required": [
                            "question_id",
                            "awarded_points",
                            "max_points",
                            "is_answer_correct",
                            "is_process_correct",
                            "feedback",
                            "needs_review",
                        ],
                    ],
                ],
                "overall_notes": ["type": "string"],
            ],
            "required": ["student_name", "student_name_needs_review", "question_results", "overall_notes"],
        ]

        let systemPrompt = """
        You are grading a student's work using a teacher-approved rubric.
        Read the student's handwritten or printed work from the attached page images.
        Return the student's name if visible. If it is missing or unreadable, return an empty string.
        For the student name, compare character by character and be strict about exact matches. If any character is unclear or uncertain, return the best candidate name and set student_name_needs_review=true.
        Award partial credit when justified.
        Evaluate both the final answer and the work process for each rubric item.
        Also check for mathematically equivalent answer forms that should still receive credit. Do not mark a grading wrong only because the student's answer is written in a different but equivalent form.
        Use only the question ids supplied in the rubric.
        Keep max_points aligned with the rubric values exactly.
        Mark needs_review=true whenever handwriting, ambiguity, missing work, or rubric mismatch makes the grade uncertain.
        \(relaxedGradingMode ? "Relaxed grading mode is ON. If the student's final answer for a question is correct, award full credit for that question even if the intermediate work is minimal, omitted, or imperfect. Do not require many intermediate steps for full credit when the final answer is correct, unless the rubric explicitly requires process-based scoring." : "")
        In feedback and overall_notes:
        - keep normal prose as plain text
        - wrap every mathematical expression in $$...$$ or $...$
        - use only valid standard LaTeX inside those delimiters
        - never use single-dollar math delimiters
        - do not output malformed LaTeX
        - if you are unsure how to write an expression in LaTeX, use plain text instead of broken LaTeX
        \(integerPointsOnly ? "Award only whole-number scores. awarded_points and max_points must be integers with no decimals." : "Fractional scores are allowed when justified by the rubric.")
        """

        let userText = """
        Grade this student submission against the rubric below.

        SESSION-WIDE GRADING RULES:
        \(overallRules?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? overallRules! : "None provided.")

        RUBRIC JSON:
        \(rubricString)
        \(previousGradingString.map { "\n\nPREVIOUS GRADING JSON:\n\($0)" } ?? "")
        \(validatorFeedbackString.map { "\n\nVALIDATION FEEDBACK JSON:\n\($0)\n\nIf the validator found issues, correct them and return a revised grading." } ?? "")
        """

        return StructuredResponseDefinition(
            schemaName: "graded_submission",
            schema: schema,
            systemPrompt: systemPrompt,
            userText: userText
        )
    }

    private func makeStructuredRequestBody(
        modelID: String,
        schemaName: String,
        schema: [String: Any],
        systemPrompt: String,
        userText: String,
        images: [Data],
        reasoningEffort: String?,
        verbosity: String?,
        serviceTier: String?,
        stream: Bool
    ) -> [String: Any] {
        var userContent: [[String: Any]] = [
            [
                "type": "input_text",
                "text": userText,
            ],
        ]

        for image in images {
            userContent.append([
                "type": "input_image",
                "image_url": makeDataURL(for: image),
                "detail": visionImageDetail,
            ])
        }

        var textConfig: [String: Any] = [
            "format": [
                "type": "json_schema",
                "name": schemaName,
                "strict": true,
                "schema": schema,
            ],
        ]

        if let verbosity {
            textConfig["verbosity"] = verbosity
        }

        var body: [String: Any] = [
            "model": modelID,
            "store": false,
            "input": [
                [
                    "role": "system",
                    "content": [
                        [
                            "type": "input_text",
                            "text": systemPrompt,
                        ],
                    ],
                ],
                [
                    "role": "user",
                    "content": userContent,
                ],
            ],
            "text": textConfig,
        ]

        if stream {
            body["stream"] = true
            body["stream_options"] = [
                "include_obfuscation": false,
            ]
        }

        if let reasoningEffort {
            body["reasoning"] = [
                "effort": reasoningEffort,
            ]
        }

        if let serviceTier {
            body["service_tier"] = serviceTier
        }

        return body
    }

    private func performStructuredRequest<T: Decodable>(
        apiKey: String,
        modelID: String,
        schemaName: String,
        schema: [String: Any],
        systemPrompt: String,
        userText: String,
        images: [Data],
        reasoningEffort: String? = nil,
        verbosity: String? = nil,
        serviceTier: String? = nil,
        streamHandler: (@Sendable (OpenAIStreamEvent) async -> Void)? = nil
    ) async throws -> OpenAIResult<T> {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw OpenAIServiceError.missingAPIKey }
        let requestBody = makeStructuredRequestBody(
            modelID: modelID,
            schemaName: schemaName,
            schema: schema,
            systemPrompt: systemPrompt,
            userText: userText,
            images: images,
            reasoningEffort: reasoningEffort,
            verbosity: verbosity,
            serviceTier: serviceTier,
            stream: false
        )

        if let streamHandler {
            await streamHandler(
                .preparing(
                    OpenAIRequestPreview(
                        modelID: modelID,
                        schemaName: schemaName,
                        imageCount: images.count,
                        systemPromptPreview: previewText(systemPrompt),
                        userTextPreview: previewText(userText, limit: 1800)
                    )
                )
            )
            await streamHandler(.status("Submitting request"))
            await streamHandler(.status("Waiting for response"))
        }

        return try await performStructuredRequestWithoutStreaming(
            apiKey: trimmedKey,
            modelID: modelID,
            requestBody: requestBody,
            streamHandler: streamHandler
        )
    }

    private func performStructuredRequestWithoutStreaming<T: Decodable>(
        apiKey: String,
        modelID: String,
        requestBody: [String: Any],
        streamHandler: (@Sendable (OpenAIStreamEvent) async -> Void)? = nil
    ) async throws -> OpenAIResult<T> {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody, options: [])

        let (data, response) = try await session.data(for: request)
        let payload = try decodeHTTPPayload(data: data, response: response)
        guard
            let object = try JSONSerialization.jsonObject(with: payload, options: []) as? [String: Any]
        else {
            throw OpenAIServiceError.invalidResponse("OpenAI returned malformed JSON for the structured response.")
        }

        if let streamHandler {
            await streamHandler(.completed)
        }

        return try decodeStructuredResult(from: object, modelID: modelID)
    }

    private func decodeStructuredResult<T: Decodable>(
        from rawResponse: [String: Any],
        modelID: String
    ) throws -> OpenAIResult<T> {
        let outputText = try extractOutputText(from: rawResponse)
        let payloadData = Data(outputText.utf8)
        let decoder = JSONDecoder()

        do {
            let payload = try decoder.decode(T.self, from: payloadData)
            let usage = extractUsage(from: rawResponse, modelID: modelID)
            return OpenAIResult(payload: payload, usage: usage)
        } catch {
            throw OpenAIServiceError.invalidResponse("OpenAI returned JSON that did not match the expected schema. \(error.localizedDescription)")
        }
    }

    private func makeSubmissionBatchJSONLFile(
        submissions: [OpenAIBatchSubmissionInput],
        modelID: String,
        definition: StructuredResponseDefinition,
        reasoningEffort: String?,
        verbosity: String?
    ) throws -> URL {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HomeworkGraderBatch-\(UUID().uuidString).jsonl")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }

        for submission in submissions {
            let images = try submission.pageFileURLs.map {
                try Data(contentsOf: $0, options: .mappedIfSafe)
            }
            let body = makeStructuredRequestBody(
                modelID: modelID,
                schemaName: definition.schemaName,
                schema: definition.schema,
                systemPrompt: definition.systemPrompt,
                userText: definition.userText,
                images: images,
                reasoningEffort: reasoningEffort,
                verbosity: verbosity,
                serviceTier: nil,
                stream: false
            )

            let lineObject: [String: Any] = [
                "custom_id": submission.customID,
                "method": "POST",
                "url": "/v1/responses",
                "body": body,
            ]

            let data = try JSONSerialization.data(withJSONObject: lineObject, options: [])
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data("\n".utf8))
        }

        return fileURL
    }

    private func uploadBatchInputFile(
        apiKey: String,
        fileURL: URL,
        filename: String
    ) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: filesEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let multipartFileURL = try makeMultipartFormFile(
            boundary: boundary,
            fileFieldName: "file",
            filename: filename,
            mimeType: "application/jsonl",
            fileURL: fileURL,
            extraFields: [
                "purpose": "batch",
            ]
        )
        defer { try? FileManager.default.removeItem(at: multipartFileURL) }

        let (responseData, response) = try await session.upload(for: request, fromFile: multipartFileURL)
        let payload = try decodeHTTPPayload(data: responseData, response: response)
        let file = try JSONDecoder().decode(OpenAIFileObject.self, from: payload)
        return file.id
    }

    private func makeMultipartFormFile(
        boundary: String,
        fileFieldName: String,
        filename: String,
        mimeType: String,
        fileURL: URL,
        extraFields: [String: String]
    ) throws -> URL {
        let multipartURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HomeworkGraderUpload-\(UUID().uuidString).tmp")
        FileManager.default.createFile(atPath: multipartURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: multipartURL)
        defer { try? outputHandle.close() }

        for (key, value) in extraFields {
            try outputHandle.write(contentsOf: Data("--\(boundary)\r\n".utf8))
            try outputHandle.write(contentsOf: Data("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".utf8))
            try outputHandle.write(contentsOf: Data("\(value)\r\n".utf8))
        }

        try outputHandle.write(contentsOf: Data("--\(boundary)\r\n".utf8))
        try outputHandle.write(contentsOf: Data("Content-Disposition: form-data; name=\"\(fileFieldName)\"; filename=\"\(filename)\"\r\n".utf8))
        try outputHandle.write(contentsOf: Data("Content-Type: \(mimeType)\r\n\r\n".utf8))

        let inputHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? inputHandle.close() }

        while let chunk = try inputHandle.read(upToCount: 512 * 1024), !chunk.isEmpty {
            try outputHandle.write(contentsOf: chunk)
        }

        try outputHandle.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        return multipartURL
    }

    private func fetchJSONLLines(apiKey: String, fileID: String) async throws -> [[String: Any]] {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw OpenAIServiceError.missingAPIKey }

        let url = filesEndpoint.appendingPathComponent(fileID).appendingPathComponent("content")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 180
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        let payload = try decodeHTTPPayload(data: data, response: response)
        let lines = String(decoding: payload, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        return try lines.map { line in
            guard
                let lineData = line.data(using: .utf8),
                let object = try JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else {
                throw OpenAIServiceError.invalidResponse("OpenAI returned malformed JSONL content for batch results.")
            }
            return object
        }
    }

    private func decodeHTTPPayload(data: Data, response: URLResponse) throws -> Data {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIServiceError.invalidResponse("OpenAI did not return an HTTP response.")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = parseErrorMessage(from: data) ?? "OpenAI returned HTTP \(httpResponse.statusCode)."
            throw OpenAIServiceError.httpError(httpResponse.statusCode, message)
        }

        return data
    }

    private func parseErrorMessage(from data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data, options: []),
            let response = object as? [String: Any]
        else {
            return nil
        }

        if let error = response["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }

        return nil
    }

    private func batchErrorMessage(from object: [String: Any]) -> String? {
        if
            let error = object["error"] as? [String: Any],
            let message = error["message"] as? String
        {
            return message
        }

        if
            let response = object["response"] as? [String: Any],
            let body = response["body"] as? [String: Any],
            let error = body["error"] as? [String: Any],
            let message = error["message"] as? String
        {
            return message
        }

        if
            let response = object["response"] as? [String: Any],
            let statusCode = response["status_code"] as? Int,
            !(200...299).contains(statusCode)
        {
            return "OpenAI returned HTTP \(statusCode) for this batched request."
        }

        return nil
    }

    private func extractOutputText(from response: [String: Any]) throws -> String {
        if let directText = response["output_text"] as? String, !directText.isEmpty {
            return directText
        }

        if let parsedObject = response["output_parsed"] {
            return try stringifyJSONObject(parsedObject)
        }

        guard let outputItems = response["output"] as? [[String: Any]] else {
            throw OpenAIServiceError.invalidResponse("OpenAI did not return any output content.")
        }

        var collected = ""

        for item in outputItems {
            if let refusal = item["refusal"] as? String, !refusal.isEmpty {
                throw OpenAIServiceError.refusal(refusal)
            }

            guard let contentItems = item["content"] as? [[String: Any]] else { continue }

            for contentItem in contentItems {
                if let type = contentItem["type"] as? String, type == "refusal" {
                    let message = (contentItem["refusal"] as? String) ?? "The model refused to answer."
                    throw OpenAIServiceError.refusal(message)
                }

                if let parsedObject = contentItem["parsed"] {
                    return try stringifyJSONObject(parsedObject)
                }

                if let type = contentItem["type"] as? String, type == "output_text" || type == "text" {
                    if let text = contentItem["text"] as? String {
                        collected += text
                        continue
                    }

                    if
                        let textObject = contentItem["text"] as? [String: Any],
                        let value = textObject["value"] as? String
                    {
                        collected += value
                        continue
                    }

                    if let value = contentItem["value"] as? String {
                        collected += value
                    }
                }
            }
        }

        if collected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw OpenAIServiceError.invalidResponse("OpenAI returned no decodable structured output. \(describeResponseShape(response))")
        }

        return collected
    }

    private func stringifyJSONObject(_ object: Any) throws -> String {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw OpenAIServiceError.invalidResponse("OpenAI returned parsed output in an unsupported format.")
        }

        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func describeResponseShape(_ response: [String: Any]) -> String {
        let keys = response.keys.sorted().joined(separator: ", ")
        let outputTypes = ((response["output"] as? [[String: Any]]) ?? [])
            .compactMap { item -> String? in
                if let type = item["type"] as? String {
                    return type
                }
                if let content = item["content"] as? [[String: Any]] {
                    let contentTypes = content.compactMap { $0["type"] as? String }
                    guard !contentTypes.isEmpty else { return nil }
                    return contentTypes.joined(separator: "+")
                }
                return nil
            }
            .joined(separator: ", ")

        if outputTypes.isEmpty {
            return "Response keys: [\(keys)]."
        }

        return "Response keys: [\(keys)]. Output types: [\(outputTypes)]."
    }

    private func extractUsage(from response: [String: Any], modelID: String) -> OpenAIUsageSummary? {
        guard let usage = response["usage"] as? [String: Any] else { return nil }

        let inputTokens = usage["input_tokens"] as? Int ?? 0
        let outputTokens = usage["output_tokens"] as? Int ?? 0
        let inputDetails = usage["input_tokens_details"] as? [String: Any]
        let cachedInputTokens = inputDetails?["cached_tokens"] as? Int ?? 0

        let estimatedCostUSD = PricingCatalog.estimatedCostUSD(
            modelID: modelID,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cachedInputTokens: cachedInputTokens
        )

        return OpenAIUsageSummary(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cachedInputTokens: cachedInputTokens,
            estimatedCostUSD: estimatedCostUSD
        )
    }

    private func makeDataURL(for data: Data) -> String {
        "data:image/jpeg;base64,\(data.base64EncodedString())"
    }

    private func previewText(_ text: String, limit: Int = 900) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "\n...[truncated]"
    }

    private func streamErrorMessage(from object: [String: Any]?) -> String? {
        if let message = object?["message"] as? String {
            return message
        }

        if
            let error = object?["error"] as? [String: Any],
            let message = error["message"] as? String
        {
            return message
        }

        return nil
    }

    private func collectData(from bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
        }
        return data
    }
}

private struct SimpleValidationPayload: Decodable {
    let ok: Bool
}

private struct OpenAIFileObject: Decodable {
    let id: String
}

private struct OpenAIBatchObject: Decodable {
    let id: String
    let status: String
    let outputFileID: String?
    let errorFileID: String?
    let requestCounts: OpenAIBatchRequestCountsPayload?
    let errors: OpenAIBatchErrorList?

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case outputFileID = "output_file_id"
        case errorFileID = "error_file_id"
        case requestCounts = "request_counts"
        case errors
    }
}

private struct OpenAIBatchRequestCountsPayload: Decodable {
    let total: Int
    let completed: Int
    let failed: Int
}

private struct OpenAIBatchErrorList: Decodable {
    let data: [OpenAIBatchErrorItem]
}

private struct OpenAIBatchErrorItem: Decodable {
    let message: String?
}

struct GradingValidationPayload: Codable, Sendable {
    let isGradingCorrect: Bool
    let validatorSummary: String
    let issues: [String]

    enum CodingKeys: String, CodingKey {
        case isGradingCorrect = "is_grading_correct"
        case validatorSummary = "validator_summary"
        case issues
    }
}

private struct ModelPricing {
    let inputPerMTokensUSD: Double
    let cachedInputPerMTokensUSD: Double
    let outputPerMTokensUSD: Double
}

private enum PricingCatalog {
    static func estimatedCostUSD(modelID: String, inputTokens: Int, outputTokens: Int, cachedInputTokens: Int) -> Double {
        guard let pricing = pricing(for: modelID) else { return 0 }

        let uncachedInputTokens = max(inputTokens - cachedInputTokens, 0)
        let inputCost = Double(uncachedInputTokens) / 1_000_000 * pricing.inputPerMTokensUSD
        let cachedInputCost = Double(cachedInputTokens) / 1_000_000 * pricing.cachedInputPerMTokensUSD
        let outputCost = Double(outputTokens) / 1_000_000 * pricing.outputPerMTokensUSD
        return inputCost + cachedInputCost + outputCost
    }

    static func pricing(for modelID: String) -> ModelPricing? {
        let normalized = modelID.lowercased()

        if normalized.hasPrefix("gpt-5.4-mini") { return ModelPricing(inputPerMTokensUSD: 0.75, cachedInputPerMTokensUSD: 0.075, outputPerMTokensUSD: 4.50) }
        if normalized.hasPrefix("gpt-5.4-nano") { return ModelPricing(inputPerMTokensUSD: 0.20, cachedInputPerMTokensUSD: 0.02, outputPerMTokensUSD: 1.25) }
        if normalized.hasPrefix("gpt-5.4") { return ModelPricing(inputPerMTokensUSD: 2.50, cachedInputPerMTokensUSD: 0.25, outputPerMTokensUSD: 15.00) }
        if normalized.hasPrefix("gpt-5.2-mini") { return ModelPricing(inputPerMTokensUSD: 0.40, cachedInputPerMTokensUSD: 0.04, outputPerMTokensUSD: 3.20) }
        if normalized.hasPrefix("gpt-5.2-nano") { return ModelPricing(inputPerMTokensUSD: 0.10, cachedInputPerMTokensUSD: 0.01, outputPerMTokensUSD: 0.80) }
        if normalized.hasPrefix("gpt-5.2") { return ModelPricing(inputPerMTokensUSD: 1.75, cachedInputPerMTokensUSD: 0.175, outputPerMTokensUSD: 14.00) }
        if normalized.hasPrefix("gpt-5-mini") { return ModelPricing(inputPerMTokensUSD: 0.25, cachedInputPerMTokensUSD: 0.025, outputPerMTokensUSD: 2.00) }
        if normalized.hasPrefix("gpt-5-nano") { return ModelPricing(inputPerMTokensUSD: 0.05, cachedInputPerMTokensUSD: 0.005, outputPerMTokensUSD: 0.40) }
        if normalized.hasPrefix("gpt-5") { return ModelPricing(inputPerMTokensUSD: 1.25, cachedInputPerMTokensUSD: 0.125, outputPerMTokensUSD: 10.00) }
        if normalized.hasPrefix("gpt-4.1-mini") { return ModelPricing(inputPerMTokensUSD: 0.40, cachedInputPerMTokensUSD: 0.10, outputPerMTokensUSD: 1.60) }
        if normalized.hasPrefix("gpt-4.1") { return ModelPricing(inputPerMTokensUSD: 2.00, cachedInputPerMTokensUSD: 0.50, outputPerMTokensUSD: 8.00) }
        if normalized.hasPrefix("gpt-4o-mini") { return ModelPricing(inputPerMTokensUSD: 0.15, cachedInputPerMTokensUSD: 0.075, outputPerMTokensUSD: 0.60) }
        if normalized.hasPrefix("gpt-4o") { return ModelPricing(inputPerMTokensUSD: 2.50, cachedInputPerMTokensUSD: 1.25, outputPerMTokensUSD: 10.00) }

        return nil
    }
}

private struct OrganizationCostsPage: Decodable {
    let data: [OrganizationCostsBucket]
    let nextPage: String?

    enum CodingKeys: String, CodingKey {
        case data
        case nextPage = "next_page"
    }
}

private struct OrganizationCostsBucket: Decodable {
    let results: [OrganizationCostResult]
}

private struct OrganizationCostResult: Decodable {
    let amount: OrganizationCostAmount
}

private struct OrganizationCostAmount: Decodable {
    let value: Double
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
