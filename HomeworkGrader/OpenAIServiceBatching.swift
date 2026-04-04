import Foundation

extension OpenAIService {
    func makeSubmissionBatchJSONLFile(
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
            let body = try autoreleasepool {
                try makeStructuredRequestBody(
                    modelID: modelID,
                    schemaName: definition.schemaName,
                    schema: definition.schema,
                    systemPrompt: definition.systemPrompt,
                    userText: definition.userText,
                    imageFileURLs: submission.pageFileURLs,
                    reasoningEffort: reasoningEffort,
                    verbosity: verbosity,
                    serviceTier: nil,
                    stream: false
                )
            }

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

    func makeAnswerKeyBatchJSONLFile(
        submissions: [OpenAIBatchAnswerKeyInput],
        modelID: String,
        sessionTitle: String,
        reasoningEffort: String?,
        verbosity: String?
    ) throws -> URL {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HGraderAnswerKeyBatch-\(UUID().uuidString).jsonl")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }

        let definition = try makeAnswerKeyDefinition(sessionTitle: sessionTitle)

        for submission in submissions {
            let body = try autoreleasepool {
                try makeStructuredRequestBody(
                    modelID: modelID,
                    schemaName: definition.schemaName,
                    schema: definition.schema,
                    systemPrompt: definition.systemPrompt,
                    userText: definition.userText,
                    imageFileURLs: submission.pageFileURLs,
                    reasoningEffort: reasoningEffort,
                    verbosity: verbosity,
                    serviceTier: nil,
                    stream: false
                )
            }

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

    func makeSubmissionValidationBatchJSONLFile(
        submissions: [OpenAIBatchValidationInput],
        modelID: String,
        rubric: [RubricSnapshot],
        overallRules: String?,
        integerPointsOnly: Bool,
        relaxedGradingMode: Bool,
        reasoningEffort: String?,
        verbosity: String?
    ) throws -> URL {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HGraderValidationBatch-\(UUID().uuidString).jsonl")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }

        for submission in submissions {
            let definition = try makeSubmissionValidationDefinition(
                rubric: rubric,
                overallRules: overallRules,
                candidateGrading: submission.candidateGrading,
                integerPointsOnly: integerPointsOnly,
                relaxedGradingMode: relaxedGradingMode
            )
            let body = try autoreleasepool {
                try makeStructuredRequestBody(
                    modelID: modelID,
                    schemaName: definition.schemaName,
                    schema: definition.schema,
                    systemPrompt: definition.systemPrompt,
                    userText: definition.userText,
                    imageFileURLs: submission.pageFileURLs,
                    reasoningEffort: reasoningEffort,
                    verbosity: verbosity,
                    serviceTier: nil,
                    stream: false
                )
            }

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

    func makeSubmissionRegradingBatchJSONLFile(
        submissions: [OpenAIBatchRegradeInput],
        modelID: String,
        rubric: [RubricSnapshot],
        overallRules: String?,
        integerPointsOnly: Bool,
        relaxedGradingMode: Bool,
        reasoningEffort: String?,
        verbosity: String?
    ) throws -> URL {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HGraderRegradeBatch-\(UUID().uuidString).jsonl")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }

        for submission in submissions {
            let definition = try makeSubmissionGradeDefinition(
                rubric: rubric,
                overallRules: overallRules,
                integerPointsOnly: integerPointsOnly,
                relaxedGradingMode: relaxedGradingMode,
                previousGrading: submission.previousGrading,
                validatorFeedback: submission.validatorFeedback
            )
            let body = try autoreleasepool {
                try makeStructuredRequestBody(
                    modelID: modelID,
                    schemaName: definition.schemaName,
                    schema: definition.schema,
                    systemPrompt: definition.systemPrompt,
                    userText: definition.userText,
                    imageFileURLs: submission.pageFileURLs,
                    reasoningEffort: reasoningEffort,
                    verbosity: verbosity,
                    serviceTier: nil,
                    stream: false
                )
            }

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

    func createStructuredBatch(
        apiKey: String,
        jsonlFileURL: URL,
        filenamePrefix: String
    ) async throws -> OpenAIBatchCreationResult {
        defer { try? FileManager.default.removeItem(at: jsonlFileURL) }

        let fileID = try await uploadBatchInputFile(
            apiKey: apiKey,
            fileURL: jsonlFileURL,
            filename: "\(filenamePrefix)-\(UUID().uuidString).jsonl"
        )

        var request = URLRequest(url: batchesEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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

    func uploadBatchInputFile(
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

    func makeMultipartFormFile(
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

    func fetchJSONLLines(apiKey: String, fileID: String) async throws -> [[String: Any]] {
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

    func batchErrorMessage(from object: [String: Any]) -> String? {
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
}
