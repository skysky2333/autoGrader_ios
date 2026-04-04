import Foundation

extension OpenAIService {
    func performStructuredRequest<T: Decodable>(
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

    func performStructuredRequestWithoutStreaming<T: Decodable>(
        apiKey: String,
        modelID: String,
        requestBody: [String: Any],
        streamHandler: (@Sendable (OpenAIStreamEvent) async -> Void)? = nil
    ) async throws -> OpenAIResult<T> {
        do {
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
                if let responseID = object["id"] as? String, !responseID.isEmpty {
                    await streamHandler(.responseCreated(responseID))
                }
                let outputText = try extractOutputText(from: object)
                await streamHandler(.outputTextDone(outputText))
                await streamHandler(.completed)
            }

            return try decodeStructuredResult(from: object, modelID: modelID)
        } catch {
            if let streamHandler {
                await streamHandler(.error(error.localizedDescription))
            }
            throw error
        }
    }

    func decodeStructuredResult<T: Decodable>(
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

    func decodeHTTPPayload(data: Data, response: URLResponse) throws -> Data {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIServiceError.invalidResponse("OpenAI did not return an HTTP response.")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = parseErrorMessage(from: data) ?? "OpenAI returned HTTP \(httpResponse.statusCode)."
            throw OpenAIServiceError.httpError(httpResponse.statusCode, message)
        }

        return data
    }

    func parseErrorMessage(from data: Data) -> String? {
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

    func extractOutputText(from response: [String: Any]) throws -> String {
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

    func stringifyJSONObject(_ object: Any) throws -> String {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw OpenAIServiceError.invalidResponse("OpenAI returned parsed output in an unsupported format.")
        }

        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    func describeResponseShape(_ response: [String: Any]) -> String {
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

    func extractUsage(from response: [String: Any], modelID: String) -> OpenAIUsageSummary? {
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

    func streamErrorMessage(from object: [String: Any]?) -> String? {
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

    func collectData(from bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
        }
        return data
    }
}
