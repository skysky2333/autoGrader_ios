import Foundation

extension OpenAIService {
    func makeSubmissionGradeDefinition(
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
                "needs_attention": ["type": "boolean"],
                "attention_reasons": [
                    "type": "array",
                    "items": ["type": "string"],
                ],
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
            "required": [
                "student_name",
                "student_name_needs_review",
                "needs_attention",
                "attention_reasons",
                "question_results",
                "overall_notes",
            ],
        ]

        let systemPrompt = """
        You are grading a student's work using a teacher-approved rubric.
        Read the student's handwritten or printed work from the attached page images.
        Return the student's name if visible. If it is missing or unreadable, return an empty string.
        For the student name, compare character by character and be strict about exact matches. Only set student_name_needs_review=true when one or more characters remain genuinely unclear after careful inspection. Do not mark the name for review if you are confident in the exact reading.
        Award partial credit when justified.
        Evaluate both the final answer and the work process for each rubric item.
        Also check for mathematically equivalent answer forms that should still receive credit. Do not mark a grading wrong only because the student's answer is written in a different but equivalent form.
        Use only the question ids supplied in the rubric.
        Keep max_points aligned with the rubric values exactly.
        Mark needs_review=true only when the grade is genuinely uncertain after careful inspection, such as unresolved handwriting ambiguity, unreadable work, or a real rubric mismatch that you cannot confidently resolve.
        Do not use needs_review as a default safety flag. If you are confident in the grade, set needs_review=false.
        needs_attention is a separate submission-level flag. Set needs_attention=true only for serious problems that mean the submission itself needs teacher attention before the grade can be trusted, such as the wrong exam, obviously incomplete or cut-off pages, pages so blurry they cannot be read, or missing critical pages.
        Do not use needs_attention for ordinary uncertainty on one problem; that belongs in needs_review instead.
        When needs_attention=true, add clear concrete reasons to attention_reasons. When needs_attention=false, return attention_reasons as an empty array.
        \(relaxedGradingMode ? "Relaxed grading mode is ON. If the student's final answer for a question is correct, award full credit for that question even if the intermediate work is minimal, omitted, or imperfect. Do not require many intermediate steps for full credit when the final answer is correct, unless the rubric explicitly requires process-based scoring." : "")
        In feedback and overall_notes:
        - keep normal prose as plain text
        - wrap every mathematical expression in $...$ or $$...$$
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

    func makeSubmissionValidationDefinition(
        rubric: [RubricSnapshot],
        overallRules: String?,
        candidateGrading: SubmissionPayload,
        integerPointsOnly: Bool,
        relaxedGradingMode: Bool
    ) throws -> StructuredResponseDefinition {
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
        For the student name, verify character by character and double-check every visible occurrence of the name across all attached pages before deciding.
        If the candidate name seems plausible but one or more characters remain genuinely uncertain after careful re-checking, student_name_needs_review should be true.
        Do not fail validation only because the name is uncertain if the candidate grading correctly marks the name for human review.
        Fail validation if the name appears materially wrong, or if the name is uncertain but the candidate grading failed to flag student_name_needs_review.
        Also verify that question-level needs_review flags are used sparingly and only when the underlying grade is genuinely uncertain.
        Also verify that needs_attention is reserved for serious submission-level problems such as unreadable scans, incomplete pages, or the wrong exam.
        Also check for mathematically equivalent answer forms that should still receive credit. Do not mark a grading wrong only because the student's answer is written in a different but equivalent form.
        Keep validator_summary concise and actionable so it can be used to regrade the submission if needed.
        In validator_summary and issues:
        - keep normal prose as plain text
        - wrap every mathematical expression in $...$ or $$...$$
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

        return StructuredResponseDefinition(
            schemaName: "grading_validation",
            schema: schema,
            systemPrompt: systemPrompt,
            userText: userText
        )
    }

    func makeStructuredRequestBody(
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

    func makeStructuredRequestBody(
        modelID: String,
        schemaName: String,
        schema: [String: Any],
        systemPrompt: String,
        userText: String,
        imageFileURLs: [URL],
        reasoningEffort: String?,
        verbosity: String?,
        serviceTier: String?,
        stream: Bool
    ) throws -> [String: Any] {
        var userContent: [[String: Any]] = [
            [
                "type": "input_text",
                "text": userText,
            ],
        ]

        for fileURL in imageFileURLs {
            let imagePayload = try autoreleasepool {
                let imageData = try Data(contentsOf: fileURL, options: .mappedIfSafe)
                return [
                    "type": "input_image",
                    "image_url": makeDataURL(for: imageData),
                    "detail": visionImageDetail,
                ]
            }
            userContent.append(imagePayload)
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

    func makeAnswerKeyDefinition(sessionTitle: String) throws -> StructuredResponseDefinition {
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
        - wrap every mathematical expression in $...$ or $$...$$
        - use only valid standard LaTeX inside those delimiters
        - never use single-dollar math delimiters
        - if you are unsure how to write an expression in LaTeX, use plain text instead of broken LaTeX
        """

        let userText = """
        Session title: \(sessionTitle)
        The attached pages are blank assignment pages in page order starting at page 1.
        Return one question object per gradeable question.
        """

        return StructuredResponseDefinition(
            schemaName: "master_answer_key",
            schema: schema,
            systemPrompt: systemPrompt,
            userText: userText
        )
    }

    func makeDataURL(for data: Data) -> String {
        "data:image/jpeg;base64,\(data.base64EncodedString())"
    }

    func previewText(_ text: String, limit: Int = 900) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "\n...[truncated]"
    }
}
