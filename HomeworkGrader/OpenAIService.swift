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

struct OpenAIUsageSummary {
    let inputTokens: Int
    let outputTokens: Int
    let cachedInputTokens: Int
    let estimatedCostUSD: Double
}

struct OpenAIResult<Payload> {
    let payload: Payload
    let usage: OpenAIUsageSummary?
}

struct OrganizationCostSummary: Equatable {
    let totalCostUSD: Double
    let fetchedAt: Date
}

final class OpenAIService {
    static let shared = OpenAIService()

    private let session: URLSession
    private let endpoint = URL(string: "https://api.openai.com/v1/responses")!
    private let organizationCostsEndpoint = URL(string: "https://api.openai.com/v1/organization/costs")!

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
        serviceTier: String?
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
            serviceTier: serviceTier
        )
    }

    func gradeSubmission(
        apiKey: String,
        modelID: String,
        rubric: [RubricSnapshot],
        pageData: [Data],
        integerPointsOnly: Bool,
        reasoningEffort: String?,
        verbosity: String?,
        serviceTier: String?
    ) async throws -> OpenAIResult<SubmissionPayload> {
        let rubricData = try JSONEncoder.prettyPrinted.encode(rubric)
        let rubricString = String(decoding: rubricData, as: UTF8.self)

        let schema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "student_name": ["type": "string"],
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
            "required": ["student_name", "question_results", "overall_notes"],
        ]

        let systemPrompt = """
        You are grading a student's work using a teacher-approved rubric.
        Read the student's handwritten or printed work from the attached page images.
        Return the student's name if visible. If it is missing or unreadable, return an empty string.
        Award partial credit when justified.
        Evaluate both the final answer and the work process for each rubric item.
        Use only the question ids supplied in the rubric.
        Keep max_points aligned with the rubric values exactly.
        Mark needs_review=true whenever handwriting, ambiguity, missing work, or rubric mismatch makes the grade uncertain.
        \(integerPointsOnly ? "Award only whole-number scores. awarded_points and max_points must be integers with no decimals." : "Fractional scores are allowed when justified by the rubric.")
        """

        let userText = """
        Grade this student submission against the rubric below.

        RUBRIC JSON:
        \(rubricString)
        """

        return try await performStructuredRequest(
            apiKey: apiKey,
            modelID: modelID,
            schemaName: "graded_submission",
            schema: schema,
            systemPrompt: systemPrompt,
            userText: userText,
            images: pageData,
            reasoningEffort: reasoningEffort,
            verbosity: verbosity,
            serviceTier: serviceTier
        )
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
        serviceTier: String? = nil
    ) async throws -> OpenAIResult<T> {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw OpenAIServiceError.missingAPIKey }

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
                "detail": "high",
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

        if let reasoningEffort {
            body["reasoning"] = [
                "effort": reasoningEffort,
            ]
        }

        if let serviceTier {
            body["service_tier"] = serviceTier
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIServiceError.invalidResponse("OpenAI did not return an HTTP response.")
        }

        if !(200...299).contains(httpResponse.statusCode) {
            let message = parseErrorMessage(from: data) ?? "OpenAI returned HTTP \(httpResponse.statusCode)."
            throw OpenAIServiceError.httpError(httpResponse.statusCode, message)
        }

        let rawObject = try JSONSerialization.jsonObject(with: data, options: [])
        guard let rawResponse = rawObject as? [String: Any] else {
            throw OpenAIServiceError.invalidResponse("OpenAI returned a response that could not be parsed.")
        }

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

    private func extractOutputText(from response: [String: Any]) throws -> String {
        if let directText = response["output_text"] as? String, !directText.isEmpty {
            return directText
        }

        guard let outputItems = response["output"] as? [[String: Any]] else {
            throw OpenAIServiceError.invalidResponse("OpenAI did not return any output content.")
        }

        var collected = ""

        for item in outputItems {
            guard let contentItems = item["content"] as? [[String: Any]] else { continue }

            for contentItem in contentItems {
                if let type = contentItem["type"] as? String, type == "refusal" {
                    let message = (contentItem["refusal"] as? String) ?? "The model refused to answer."
                    throw OpenAIServiceError.refusal(message)
                }

                if let type = contentItem["type"] as? String, type == "output_text", let text = contentItem["text"] as? String {
                    collected += text
                }
            }
        }

        if collected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw OpenAIServiceError.invalidResponse("OpenAI returned no text output to decode.")
        }

        return collected
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
}

private struct SimpleValidationPayload: Decodable {
    let ok: Bool
}

private extension JSONEncoder {
    static var prettyPrinted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
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
