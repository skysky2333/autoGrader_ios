"use strict";

const fs = require("node:fs/promises");
const path = require("node:path");
const { Blob } = require("node:buffer");
const {
  estimatedCostUSD,
} = require("./shared");

const RESPONSES_ENDPOINT = "https://api.openai.com/v1/responses";
const BATCHES_ENDPOINT = "https://api.openai.com/v1/batches";
const FILES_ENDPOINT = "https://api.openai.com/v1/files";
const ORGANIZATION_COSTS_ENDPOINT = "https://api.openai.com/v1/organization/costs";
const VISION_IMAGE_DETAIL = "high";

function openAIError(message, status = null) {
  const error = new Error(message);
  if (status != null) {
    error.status = status;
  }
  return error;
}

function ensureAPIKey(apiKey) {
  const trimmed = String(apiKey || "").trim();
  if (!trimmed) {
    throw openAIError("Add your OpenAI API key in Settings before scanning or grading.");
  }
  return trimmed;
}

async function validateAPIKey(apiKey, modelID) {
  const schema = {
    type: "object",
    additionalProperties: false,
    properties: {
      ok: { type: "boolean" },
    },
    required: ["ok"],
  };

  await performStructuredRequest({
    apiKey,
    modelID,
    schemaName: "api_key_validation",
    schema,
    systemPrompt: "You validate whether the API connection is working.",
    userText: "Return ok=true.",
    attachments: [],
  });
}

async function fetchOrganizationTotalCost(apiKey) {
  const key = ensureAPIKey(apiKey);
  let nextPage = null;
  let totalCostUSD = 0;

  do {
    const url = new URL(ORGANIZATION_COSTS_ENDPOINT);
    url.searchParams.set("start_time", "1577836800");
    url.searchParams.set("limit", "180");
    if (nextPage) {
      url.searchParams.set("page", nextPage);
    }

    const response = await fetch(url, {
      method: "GET",
      headers: {
        Authorization: `Bearer ${key}`,
      },
    });
    const payload = await decodeHTTPPayload(response);

    const data = JSON.parse(payload.toString("utf8"));
    for (const bucket of data.data || []) {
      for (const result of bucket.results || []) {
        totalCostUSD += Number(result.amount?.value || 0);
      }
    }
    nextPage = data.next_page || null;
  } while (nextPage);

  return {
    totalCostUSD,
    fetchedAt: new Date().toISOString(),
  };
}

async function generateAnswerKey({
  apiKey,
  modelID,
  sessionTitle,
  attachments,
  reasoningEffort,
  verbosity,
  serviceTier,
}) {
  const definition = makeAnswerKeyDefinition(sessionTitle);
  return performStructuredRequest({
    apiKey,
    modelID,
    schemaName: definition.schemaName,
    schema: definition.schema,
    systemPrompt: definition.systemPrompt,
    userText: definition.userText,
    attachments,
    reasoningEffort,
    verbosity,
    serviceTier,
  });
}

async function gradeSubmission({
  apiKey,
  modelID,
  rubric,
  overallRules,
  attachments,
  integerPointsOnly,
  relaxedGradingMode,
  previousGrading = null,
  validatorFeedback = null,
  reasoningEffort,
  verbosity,
  serviceTier,
}) {
  const definition = makeSubmissionGradeDefinition({
    rubric,
    overallRules,
    integerPointsOnly,
    relaxedGradingMode,
    previousGrading,
    validatorFeedback,
  });

  return performStructuredRequest({
    apiKey,
    modelID,
    schemaName: definition.schemaName,
    schema: definition.schema,
    systemPrompt: definition.systemPrompt,
    userText: definition.userText,
    attachments,
    reasoningEffort,
    verbosity,
    serviceTier,
  });
}

async function validateSubmissionGrade({
  apiKey,
  modelID,
  rubric,
  overallRules,
  candidateGrading,
  attachments,
  integerPointsOnly,
  relaxedGradingMode,
  reasoningEffort,
  verbosity,
  serviceTier,
}) {
  const definition = makeSubmissionValidationDefinition({
    rubric,
    overallRules,
    candidateGrading,
    integerPointsOnly,
    relaxedGradingMode,
  });

  return performStructuredRequest({
    apiKey,
    modelID,
    schemaName: definition.schemaName,
    schema: definition.schema,
    systemPrompt: definition.systemPrompt,
    userText: definition.userText,
    attachments,
    reasoningEffort,
    verbosity,
    serviceTier,
  });
}

async function createAnswerKeyBatch({
  apiKey,
  modelID,
  sessionTitle,
  submissions,
  reasoningEffort,
  verbosity,
}) {
  const definition = makeAnswerKeyDefinition(sessionTitle);
  return createStructuredBatch({
    apiKey,
    filenamePrefix: "hgrader-answer-key",
    submissions,
    buildDefinition: () => definition,
    modelID,
    reasoningEffort,
    verbosity,
    serviceTier: null,
  });
}

async function createSubmissionGradingBatch({
  apiKey,
  modelID,
  rubric,
  overallRules,
  submissions,
  integerPointsOnly,
  relaxedGradingMode,
  reasoningEffort,
  verbosity,
}) {
  return createStructuredBatch({
    apiKey,
    filenamePrefix: "homework-grader",
    submissions,
    buildDefinition: () =>
      makeSubmissionGradeDefinition({
        rubric,
        overallRules,
        integerPointsOnly,
        relaxedGradingMode,
        previousGrading: null,
        validatorFeedback: null,
      }),
    modelID,
    reasoningEffort,
    verbosity,
    serviceTier: null,
  });
}

async function createSubmissionValidationBatch({
  apiKey,
  modelID,
  rubric,
  overallRules,
  submissions,
  integerPointsOnly,
  relaxedGradingMode,
  reasoningEffort,
  verbosity,
}) {
  return createStructuredBatch({
    apiKey,
    filenamePrefix: "hgrader-validation",
    submissions,
    buildDefinition: (submission) =>
      makeSubmissionValidationDefinition({
        rubric,
        overallRules,
        candidateGrading: submission.candidateGrading,
        integerPointsOnly,
        relaxedGradingMode,
      }),
    modelID,
    reasoningEffort,
    verbosity,
    serviceTier: null,
  });
}

async function createSubmissionRegradingBatch({
  apiKey,
  modelID,
  rubric,
  overallRules,
  submissions,
  integerPointsOnly,
  relaxedGradingMode,
  reasoningEffort,
  verbosity,
}) {
  return createStructuredBatch({
    apiKey,
    filenamePrefix: "hgrader-regrade",
    submissions,
    buildDefinition: (submission) =>
      makeSubmissionGradeDefinition({
        rubric,
        overallRules,
        integerPointsOnly,
        relaxedGradingMode,
        previousGrading: submission.previousGrading,
        validatorFeedback: submission.validatorFeedback,
      }),
    modelID,
    reasoningEffort,
    verbosity,
    serviceTier: null,
  });
}

async function createStructuredBatch({
  apiKey,
  filenamePrefix,
  submissions,
  buildDefinition,
  modelID,
  reasoningEffort,
  verbosity,
  serviceTier,
}) {
  const key = ensureAPIKey(apiKey);
  const lines = [];

  for (const submission of submissions) {
    const definition = buildDefinition(submission);
    const fileReferences = await uploadAssetsForBatch(key, submission.attachments || []);
    const body = makeStructuredRequestBody({
      modelID,
      schemaName: definition.schemaName,
      schema: definition.schema,
      systemPrompt: definition.systemPrompt,
      userText: definition.userText,
      attachmentInputs: fileReferences,
      reasoningEffort,
      verbosity,
      serviceTier,
    });

    lines.push({
      custom_id: submission.customID,
      method: "POST",
      url: "/v1/responses",
      body,
    });
  }

  const fileID = await uploadJSONLBatchFile(key, lines, `${filenamePrefix}-${Date.now()}.jsonl`);
  const response = await fetch(BATCHES_ENDPOINT, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${key}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      input_file_id: fileID,
      endpoint: "/v1/responses",
      completion_window: "24h",
    }),
  });
  const payload = await decodeHTTPPayload(response);
  const batch = JSON.parse(payload.toString("utf8"));

  return {
    batchID: batch.id,
    status: batch.status,
  };
}

async function fetchBatchStatus(apiKey, batchID) {
  const key = ensureAPIKey(apiKey);
  const response = await fetch(`${BATCHES_ENDPOINT}/${batchID}`, {
    method: "GET",
    headers: {
      Authorization: `Bearer ${key}`,
    },
  });
  const payload = await decodeHTTPPayload(response);
  const batch = JSON.parse(payload.toString("utf8"));
  return {
    batchID: batch.id,
    status: batch.status,
    outputFileID: batch.output_file_id || null,
    errorFileID: batch.error_file_id || null,
    requestCounts: batch.request_counts
      ? {
          total: batch.request_counts.total,
          completed: batch.request_counts.completed,
          failed: batch.request_counts.failed,
        }
      : null,
    errors: (batch.errors?.data || []).map((item) => item.message).filter(Boolean),
  };
}

async function fetchSubmissionBatchResults(apiKey, modelID, outputFileID) {
  return fetchTypedBatchResults(apiKey, modelID, outputFileID, (text) => JSON.parse(text));
}

async function fetchValidationBatchResults(apiKey, modelID, outputFileID) {
  return fetchTypedBatchResults(apiKey, modelID, outputFileID, (text) => JSON.parse(text));
}

async function fetchAnswerKeyBatchResults(apiKey, modelID, outputFileID) {
  return fetchTypedBatchResults(apiKey, modelID, outputFileID, (text) => JSON.parse(text));
}

async function fetchBatchErrors(apiKey, errorFileID) {
  const objects = await fetchJSONLLines(apiKey, errorFileID);
  return objects
    .map((object) => {
      if (!object.custom_id) {
        return null;
      }
      return {
        customID: object.custom_id,
        message: batchErrorMessage(object) || "OpenAI did not provide an error message for this batch request.",
        rawLineJSON: JSON.stringify(object, null, 2),
      };
    })
    .filter(Boolean);
}

async function performStructuredRequest({
  apiKey,
  modelID,
  schemaName,
  schema,
  systemPrompt,
  userText,
  attachments,
  reasoningEffort = null,
  verbosity = null,
  serviceTier = null,
}) {
  const key = ensureAPIKey(apiKey);
  const attachmentInputs = await Promise.all((attachments || []).map(buildInlineAttachment));
  const requestBody = makeStructuredRequestBody({
    modelID,
    schemaName,
    schema,
    systemPrompt,
    userText,
    attachmentInputs,
    reasoningEffort,
    verbosity,
    serviceTier,
  });

  const response = await fetch(RESPONSES_ENDPOINT, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${key}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(requestBody),
  });
  const payload = await decodeHTTPPayload(response);
  const raw = JSON.parse(payload.toString("utf8"));
  const outputText = extractOutputText(raw);
  const parsedPayload = JSON.parse(outputText);
  return {
    payload: parsedPayload,
    usage: extractUsage(raw, modelID),
    rawResponse: raw,
  };
}

async function fetchTypedBatchResults(apiKey, modelID, outputFileID, decoder) {
  const objects = await fetchJSONLLines(apiKey, outputFileID);
  return objects.map((object) => {
    if (!object.custom_id) {
      throw openAIError("Batch output is missing a custom_id.");
    }
    const errorMessage = batchErrorMessage(object);
    if (errorMessage) {
      throw openAIError(`Batch output returned an error for ${object.custom_id}: ${errorMessage}`);
    }
    const body = object.response?.body;
    if (!body) {
      throw openAIError(`Batch output did not include a response body for ${object.custom_id}.`);
    }
    const outputText = extractOutputText(body);
    const payload = decoder(outputText);
    const usage = extractUsage(body, modelID);
    return {
      customID: object.custom_id,
      payload,
      usage: usage
        ? {
            ...usage,
            estimatedCostUSD: usage.estimatedCostUSD * 0.5,
          }
        : null,
      rawLineJSON: JSON.stringify(object, null, 2),
    };
  });
}

async function uploadAssetsForBatch(apiKey, attachments) {
  const references = [];
  for (const attachment of attachments || []) {
    const uploaded = await uploadInputAsset(apiKey, attachment);
    references.push(uploaded);
  }
  return references;
}

async function uploadInputAsset(apiKey, attachment) {
  const buffer = await fs.readFile(attachment.absolutePath);
  const form = new FormData();
  form.append("purpose", attachment.kind === "image" ? "vision" : "user_data");
  form.append(
    "file",
    new Blob([buffer], { type: attachment.mimeType }),
    attachment.originalName || path.basename(attachment.absolutePath)
  );

  const response = await fetch(FILES_ENDPOINT, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
    },
    body: form,
  });
  const payload = await decodeHTTPPayload(response);
  const fileObject = JSON.parse(payload.toString("utf8"));

  if (attachment.kind === "image") {
    return {
      type: "input_image",
      file_id: fileObject.id,
      detail: VISION_IMAGE_DETAIL,
    };
  }
  return {
    type: "input_file",
    file_id: fileObject.id,
  };
}

async function uploadJSONLBatchFile(apiKey, lines, filename) {
  const buffer = Buffer.from(lines.map((line) => JSON.stringify(line)).join("\n"), "utf8");
  const form = new FormData();
  form.append("purpose", "batch");
  form.append(
    "file",
    new Blob([buffer], { type: "application/jsonl" }),
    filename
  );

  const response = await fetch(FILES_ENDPOINT, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
    },
    body: form,
  });
  const payload = await decodeHTTPPayload(response);
  return JSON.parse(payload.toString("utf8")).id;
}

async function fetchJSONLLines(apiKey, fileID) {
  const key = ensureAPIKey(apiKey);
  const response = await fetch(`${FILES_ENDPOINT}/${fileID}/content`, {
    method: "GET",
    headers: {
      Authorization: `Bearer ${key}`,
    },
  });
  const payload = await decodeHTTPPayload(response);
  return payload
    .toString("utf8")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => JSON.parse(line));
}

async function buildInlineAttachment(attachment) {
  const buffer = await fs.readFile(attachment.absolutePath);
  if (attachment.kind === "image") {
    return {
      type: "input_image",
      image_url: `data:${attachment.mimeType};base64,${buffer.toString("base64")}`,
      detail: VISION_IMAGE_DETAIL,
    };
  }

  return {
    type: "input_file",
    filename: attachment.originalName || path.basename(attachment.absolutePath),
    file_data: buffer.toString("base64"),
  };
}

function makeStructuredRequestBody({
  modelID,
  schemaName,
  schema,
  systemPrompt,
  userText,
  attachmentInputs,
  reasoningEffort,
  verbosity,
  serviceTier,
}) {
  const userContent = [
    {
      type: "input_text",
      text: userText,
    },
    ...attachmentInputs,
  ];

  const textConfig = {
    format: {
      type: "json_schema",
      name: schemaName,
      strict: true,
      schema,
    },
  };

  if (verbosity) {
    textConfig.verbosity = verbosity;
  }

  const body = {
    model: modelID,
    store: false,
    input: [
      {
        role: "system",
        content: [
          {
            type: "input_text",
            text: systemPrompt,
          },
        ],
      },
      {
        role: "user",
        content: userContent,
      },
    ],
    text: textConfig,
  };

  if (reasoningEffort) {
    body.reasoning = { effort: reasoningEffort };
  }
  if (serviceTier) {
    body.service_tier = serviceTier;
  }

  return body;
}

function makeAnswerKeyDefinition(sessionTitle) {
  return {
    schemaName: "master_answer_key",
    schema: {
      type: "object",
      additionalProperties: false,
      properties: {
        assignment_title: { type: "string" },
        questions: {
          type: "array",
          items: {
            type: "object",
            additionalProperties: false,
            properties: {
              question_id: { type: "string" },
              display_label: { type: "string" },
              prompt_text: { type: "string" },
              ideal_answer: { type: "string" },
              grading_criteria: { type: "string" },
              page_references: {
                type: "array",
                items: { type: "integer" },
              },
            },
            required: [
              "question_id",
              "display_label",
              "prompt_text",
              "ideal_answer",
              "grading_criteria",
              "page_references",
            ],
          },
        },
      },
      required: ["assignment_title", "questions"],
    },
    systemPrompt: [
      "You are an expert teacher assistant.",
      "Analyze images of a blank assignment or exam and produce a teacher-reviewable answer key.",
      "Identify every distinct question in reading order across all pages.",
      "For each question, extract a concise prompt, write a detailed ideal answer or worked solution, and list grading criteria that a teacher can use later.",
      "Do not score questions. The teacher will set points manually.",
      "If parts of a page are unclear, still provide your best structured extraction and mention uncertainty inside grading_criteria.",
      "In prompt_text, ideal_answer, and grading_criteria:",
      "- keep normal prose as plain text",
      "- wrap every mathematical expression in $...$ or $$...$$",
      "- use only valid standard LaTeX inside those delimiters",
      "- never use single-dollar math delimiters",
      "- if you are unsure how to write an expression in LaTeX, use plain text instead of broken LaTeX",
    ].join("\n"),
    userText: [
      `Session title: ${sessionTitle}`,
      "The attached pages are blank assignment pages in page order starting at page 1.",
      "Return one question object per gradeable question.",
    ].join("\n"),
  };
}

function makeSubmissionGradeDefinition({
  rubric,
  overallRules,
  integerPointsOnly,
  relaxedGradingMode,
  previousGrading,
  validatorFeedback,
}) {
  const rubricString = JSON.stringify(rubric, null, 2);
  const previousGradingString = previousGrading ? JSON.stringify(previousGrading, null, 2) : null;
  const validatorFeedbackString = validatorFeedback ? JSON.stringify(validatorFeedback, null, 2) : null;

  return {
    schemaName: "graded_submission",
    schema: {
      type: "object",
      additionalProperties: false,
      properties: {
        student_name: { type: "string" },
        student_name_needs_review: { type: "boolean" },
        needs_attention: { type: "boolean" },
        attention_reasons: {
          type: "array",
          items: { type: "string" },
        },
        question_results: {
          type: "array",
          items: {
            type: "object",
            additionalProperties: false,
            properties: {
              question_id: { type: "string" },
              awarded_points: { type: "number" },
              max_points: { type: "number" },
              is_answer_correct: { type: "boolean" },
              is_process_correct: { type: "boolean" },
              feedback: { type: "string" },
              needs_review: { type: "boolean" },
            },
            required: [
              "question_id",
              "awarded_points",
              "max_points",
              "is_answer_correct",
              "is_process_correct",
              "feedback",
              "needs_review",
            ],
          },
        },
        overall_notes: { type: "string" },
      },
      required: [
        "student_name",
        "student_name_needs_review",
        "needs_attention",
        "attention_reasons",
        "question_results",
        "overall_notes",
      ],
    },
    systemPrompt: [
      "You are grading a student's work using a teacher-approved rubric.",
      "Read the student's handwritten or printed work from the attached page images.",
      "Return the student's name if visible. If it is missing or unreadable, return an empty string.",
      "For the student name, give your best guess after careful inspection, then compare character by character and be strict about exact matches. Only set student_name_needs_review=true when one or more characters remain genuinely unclear after careful inspection. Do not mark the name for review if you are confident in the exact reading.",
      "Award partial credit when justified.",
      "Evaluate both the final answer and the work process for each rubric item.",
      "Also check for mathematically equivalent answer forms that should still receive credit. Do not mark a grading wrong only because the student's answer is written in a different but equivalent form.",
      "Use only the question ids supplied in the rubric.",
      "Keep max_points aligned with the rubric values exactly.",
      "Mark needs_review=true only when the grade is genuinely uncertain after careful inspection, such as unresolved handwriting ambiguity, unreadable work, or a real rubric mismatch that you cannot confidently resolve.",
      "Do not use needs_review as a default safety flag. If you are confident in the grade, set needs_review=false.",
      "needs_attention is a separate submission-level flag. Set needs_attention=true only for serious problems that mean the submission itself needs teacher attention before the grade can be trusted, such as the wrong exam, obviously incomplete or cut-off pages, pages so blurry they cannot be read, or missing critical pages.",
      "Do not use needs_attention for ordinary uncertainty on one problem; that belongs in needs_review instead.",
      "When needs_attention=true, add clear concrete reasons to attention_reasons. When needs_attention=false, return attention_reasons as an empty array.",
      relaxedGradingMode
        ? "Relaxed grading mode is ON. If the student's final answer for a question is correct, award full credit for that question even if the intermediate work is minimal, omitted, or imperfect. Do not require many intermediate steps for full credit when the final answer is correct, unless the rubric explicitly requires process-based scoring."
        : "",
      "In feedback and overall_notes:",
      "- keep normal prose as plain text",
      "- wrap every mathematical expression in $...$ or $$...$$",
      "- use only valid standard LaTeX inside those delimiters",
      "- never use single-dollar math delimiters",
      "- do not output malformed LaTeX",
      "- if you are unsure how to write an expression in LaTeX, use plain text instead of broken LaTeX",
      integerPointsOnly
        ? "Award only whole-number scores. awarded_points and max_points must be integers with no decimals."
        : "Fractional scores are allowed when justified by the rubric.",
    ]
      .filter(Boolean)
      .join("\n"),
    userText: [
      "Grade this student submission against the rubric below.",
      "",
      "SESSION-WIDE GRADING RULES:",
      (String(overallRules || "").trim() ? overallRules : "None provided."),
      "",
      "RUBRIC JSON:",
      rubricString,
      previousGradingString ? `\nPREVIOUS GRADING JSON:\n${previousGradingString}` : "",
      validatorFeedbackString
        ? `\nVALIDATION FEEDBACK JSON:\n${validatorFeedbackString}\n\nIf the validator found issues, correct them and return a revised grading.`
        : "",
    ]
      .filter(Boolean)
      .join("\n"),
  };
}

function makeSubmissionValidationDefinition({
  rubric,
  overallRules,
  candidateGrading,
  integerPointsOnly,
  relaxedGradingMode,
}) {
  const rubricString = JSON.stringify(rubric, null, 2);
  const candidateString = JSON.stringify(candidateGrading, null, 2);

  return {
    schemaName: "grading_validation",
    schema: {
      type: "object",
      additionalProperties: false,
      properties: {
        is_grading_correct: { type: "boolean" },
        validator_summary: { type: "string" },
        issues: {
          type: "array",
          items: { type: "string" },
        },
      },
      required: ["is_grading_correct", "validator_summary", "issues"],
    },
    systemPrompt: [
      "You are validating a grading decision for a student's submission.",
      "Review the student work from the attached images, the rubric, the session-wide grading rules, and the candidate grading JSON.",
      "Return is_grading_correct=true only if the candidate grading is correct.",
      "Return false if any awarded points, correctness flags, process judgment, or review flags should change.",
      "Be critical of OCR or reading mistakes. Check carefully for text mismatches, symbol mismatches, copied-answer mismatches, and especially student-name mismatches.",
      "For the student name, give your best guess after careful inspection, then verify character by character and double-check every visible occurrence of the name across all attached pages before deciding.",
      "If the candidate name seems plausible but one or more characters remain genuinely uncertain after careful re-checking, student_name_needs_review should be true.",
      "Do not fail validation only because the name is uncertain if the candidate grading correctly marks the name for human review.",
      "Fail validation if the name appears materially wrong, or if the name is uncertain but the candidate grading failed to flag student_name_needs_review.",
      "Also verify that question-level needs_review flags are used sparingly and only when the underlying grade is genuinely uncertain.",
      "Also verify that needs_attention is reserved for serious submission-level problems such as unreadable scans, incomplete pages, or the wrong exam.",
      "Also check for mathematically equivalent answer forms that should still receive credit. Do not mark a grading wrong only because the student's answer is written in a different but equivalent form.",
      "Keep validator_summary concise and actionable so it can be used to regrade the submission if needed.",
      "In validator_summary and issues:",
      "- keep normal prose as plain text",
      "- wrap every mathematical expression in $...$ or $$...$$",
      "- use only valid standard LaTeX inside those delimiters",
      "- never use single-dollar math delimiters",
      "- if you are unsure how to write an expression in LaTeX, use plain text instead of broken LaTeX",
      relaxedGradingMode
        ? "Relaxed grading mode is ON. A correct final answer should receive full credit even if intermediate work is minimal, omitted, or imperfect, unless the rubric explicitly requires process-based scoring."
        : "",
      integerPointsOnly ? "Scores must remain whole numbers." : "Fractional scores are allowed when justified by the rubric.",
    ]
      .filter(Boolean)
      .join("\n"),
    userText: [
      "Validate the candidate grading below.",
      "",
      "SESSION-WIDE GRADING RULES:",
      (String(overallRules || "").trim() ? overallRules : "None provided."),
      "",
      "RUBRIC JSON:",
      rubricString,
      "",
      "CANDIDATE GRADING JSON:",
      candidateString,
    ].join("\n"),
  };
}

async function decodeHTTPPayload(response) {
  const buffer = Buffer.from(await response.arrayBuffer());
  if (response.ok) {
    return buffer;
  }

  let message = `OpenAI returned HTTP ${response.status}.`;
  try {
    const object = JSON.parse(buffer.toString("utf8"));
    if (object?.error?.message) {
      message = object.error.message;
    } else if (response.status === 401 || response.status === 403) {
      message = "OpenAI rejected the API key or the key does not have access to this endpoint.";
    }
  } catch {}

  throw openAIError(message, response.status);
}

function extractOutputText(response) {
  if (typeof response.output_text === "string" && response.output_text.trim()) {
    return response.output_text;
  }
  if (response.output_parsed) {
    return JSON.stringify(response.output_parsed);
  }

  const outputItems = Array.isArray(response.output) ? response.output : [];
  let collected = "";

  for (const item of outputItems) {
    if (typeof item.refusal === "string" && item.refusal.trim()) {
      throw openAIError(item.refusal);
    }

    const contentItems = Array.isArray(item.content) ? item.content : [];
    for (const contentItem of contentItems) {
      if (contentItem.type === "refusal") {
        throw openAIError(contentItem.refusal || "The model refused to answer.");
      }
      if (contentItem.parsed) {
        return JSON.stringify(contentItem.parsed);
      }
      if (contentItem.type === "output_text" || contentItem.type === "text") {
        if (typeof contentItem.text === "string") {
          collected += contentItem.text;
        } else if (contentItem.text && typeof contentItem.text.value === "string") {
          collected += contentItem.text.value;
        } else if (typeof contentItem.value === "string") {
          collected += contentItem.value;
        }
      }
    }
  }

  if (!collected.trim()) {
    throw openAIError("OpenAI returned no decodable structured output.");
  }
  return collected;
}

function extractUsage(response, modelID) {
  const usage = response.usage;
  if (!usage) {
    return null;
  }
  const inputTokens = Number(usage.input_tokens || 0);
  const outputTokens = Number(usage.output_tokens || 0);
  const cachedInputTokens = Number(usage.input_tokens_details?.cached_tokens || 0);
  return {
    inputTokens,
    outputTokens,
    cachedInputTokens,
    estimatedCostUSD: estimatedCostUSD(modelID, inputTokens, outputTokens, cachedInputTokens),
  };
}

function batchErrorMessage(object) {
  if (object.error?.message) {
    return object.error.message;
  }
  if (object.response?.body?.error?.message) {
    return object.response.body.error.message;
  }
  if (Array.isArray(object.response?.body?.errors) && object.response.body.errors[0]?.message) {
    return object.response.body.errors[0].message;
  }
  if (object.response?.status_code && Number(object.response.status_code) >= 400) {
    return `HTTP ${object.response.status_code}`;
  }
  return null;
}

module.exports = {
  createAnswerKeyBatch,
  createSubmissionGradingBatch,
  createSubmissionRegradingBatch,
  createSubmissionValidationBatch,
  fetchAnswerKeyBatchResults,
  fetchBatchErrors,
  fetchBatchStatus,
  fetchOrganizationTotalCost,
  fetchSubmissionBatchResults,
  fetchValidationBatchResults,
  generateAnswerKey,
  gradeSubmission,
  validateAPIKey,
  validateSubmissionGrade,
};
