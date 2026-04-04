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

struct OpenAIBatchAnswerKeyInput: Sendable {
    let customID: String
    let pageFileURLs: [URL]
}

struct OpenAIBatchValidationInput: Sendable {
    let customID: String
    let pageFileURLs: [URL]
    let candidateGrading: SubmissionPayload
}

struct OpenAIBatchRegradeInput: Sendable {
    let customID: String
    let pageFileURLs: [URL]
    let previousGrading: SubmissionPayload
    let validatorFeedback: GradingValidationPayload
}

struct OpenAIBatchCreationResult: Sendable {
    let batchID: String
    let status: String
}

struct OpenAIBatchStatusSnapshot: Codable, Sendable {
    let batchID: String
    let status: String
    let outputFileID: String?
    let errorFileID: String?
    let requestCounts: OpenAIBatchRequestCounts?
    let errors: [String]
}

struct OpenAIBatchRequestCounts: Codable, Sendable {
    let total: Int
    let completed: Int
    let failed: Int
}

struct OpenAIBatchSubmissionResult<Payload: Sendable>: Sendable {
    let customID: String
    let payload: Payload
    let usage: OpenAIUsageSummary?
    let rawLineJSON: String?
}

struct OpenAIBatchSubmissionError: Sendable {
    let customID: String
    let message: String
    let rawLineJSON: String?
}

struct StructuredResponseDefinition {
    let schemaName: String
    let schema: [String: Any]
    let systemPrompt: String
    let userText: String
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

struct SimpleValidationPayload: Decodable {
    let ok: Bool
}

struct OpenAIFileObject: Decodable {
    let id: String
}

struct OpenAIBatchObject: Decodable {
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

struct OpenAIBatchRequestCountsPayload: Decodable {
    let total: Int
    let completed: Int
    let failed: Int
}

struct OpenAIBatchErrorList: Decodable {
    let data: [OpenAIBatchErrorItem]
}

struct OpenAIBatchErrorItem: Decodable {
    let message: String?
}

struct ModelPricing {
    let inputPerMTokensUSD: Double
    let cachedInputPerMTokensUSD: Double
    let outputPerMTokensUSD: Double
}

enum PricingCatalog {
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

struct OrganizationCostsPage: Decodable {
    let data: [OrganizationCostsBucket]
    let nextPage: String?

    enum CodingKeys: String, CodingKey {
        case data
        case nextPage = "next_page"
    }
}

struct OrganizationCostsBucket: Decodable {
    let results: [OrganizationCostResult]
}

struct OrganizationCostResult: Decodable {
    let amount: OrganizationCostAmount
}

struct OrganizationCostAmount: Decodable {
    let value: Double
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
