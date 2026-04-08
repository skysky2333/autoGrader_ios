"use strict";

const { app, BrowserWindow, dialog, ipcMain, Notification, safeStorage, shell } = require("electron");
const fs = require("node:fs/promises");
const path = require("node:path");
const { pathToFileURL } = require("node:url");

const exporters = require("./src/exporters");
const openAI = require("./src/openai-service");
const canvasConnect = require("./src/canvas-connect");
const {
  DEFAULT_MODELS,
  MODEL_SUGGESTIONS,
  REASONING_OPTIONS,
  SERVICE_TIER_OPTIONS,
  VERBOSITY_OPTIONS,
  deepClone,
  fingerprintAPIKey,
  labelForOption,
  maxScoreFromGrades,
  normalizePointValue,
  nowISO,
  parsePointValue,
  questionGradeLookup,
  requiresAttention,
  scoreString,
  totalScoreFromGrades,
  trimText,
  uuid,
  validateMasterAssetGroup,
  validateSubmissionAssetGroup,
} = require("./src/shared");

let mainWindow = null;
let state = { version: 1, settings: { organizationCostSummary: null }, sessions: [] };
let apiKey = "";
let canvasToken = "";
let workQueue = Promise.resolve();
let pollTimer = null;

function storagePaths() {
  const root = path.join(app.getPath("userData"), "storage");
  return {
    root,
    stateFile: path.join(root, "state.json"),
    openAISecretsFile: path.join(root, "secrets-openai.json"),
    canvasSecretsFile: path.join(root, "secrets-canvas.json"),
    assetsRoot: path.join(root, "assets"),
    canvasWorkRoot: path.join(root, "canvas"),
  };
}

function enqueue(task) {
  const run = async () => task();
  const next = workQueue.then(run, run);
  workQueue = next.catch(() => {});
  return next;
}

async function ensureStorage() {
  const paths = storagePaths();
  await fs.mkdir(paths.root, { recursive: true });
  await fs.mkdir(paths.assetsRoot, { recursive: true });
  await fs.mkdir(paths.canvasWorkRoot, { recursive: true });
}

async function loadPersistedState() {
  await ensureStorage();
  const paths = storagePaths();
  try {
    const raw = await fs.readFile(paths.stateFile, "utf8");
    const parsed = JSON.parse(raw);
    state = {
      version: 1,
      settings: {
        organizationCostSummary: parsed.settings?.organizationCostSummary || null,
      },
      sessions: Array.isArray(parsed.sessions) ? parsed.sessions : [],
    };
  } catch {
    state = { version: 1, settings: { organizationCostSummary: null }, sessions: [] };
  }
  for (const session of state.sessions) {
    ensureSessionDefaults(session);
  }
  apiKey = await loadSecret(storagePaths().openAISecretsFile);
  canvasToken = await loadSecret(storagePaths().canvasSecretsFile);
}

async function savePersistedState() {
  const paths = storagePaths();
  await ensureStorage();
  await fs.writeFile(paths.stateFile, JSON.stringify(state, null, 2), "utf8");
}

async function loadSecret(filePath) {
  try {
    const raw = await fs.readFile(filePath, "utf8");
    const parsed = JSON.parse(raw);
    if (parsed.encrypted && safeStorage.isEncryptionAvailable()) {
      return safeStorage.decryptString(Buffer.from(parsed.encrypted, "base64"));
    }
    return parsed.plain || "";
  } catch {
    return "";
  }
}

async function persistSecret(filePath, nextValue) {
  const value = trimText(nextValue);
  if (!value) {
    try {
      await fs.unlink(filePath);
    } catch {}
    return;
  }

  const payload = safeStorage.isEncryptionAvailable()
    ? { encrypted: safeStorage.encryptString(value).toString("base64") }
    : { plain: value };
  await fs.writeFile(filePath, JSON.stringify(payload, null, 2), "utf8");
}

async function persistAPIKey(nextValue) {
  apiKey = trimText(nextValue);
  await persistSecret(storagePaths().openAISecretsFile, apiKey);
}

async function persistCanvasToken(nextValue) {
  canvasToken = trimText(nextValue);
  await persistSecret(storagePaths().canvasSecretsFile, canvasToken);
}

function buildSnapshot() {
  return {
    state: enrichStateForRenderer(state),
    meta: {
      hasAPIKey: Boolean(trimText(apiKey)),
      hasCanvasToken: Boolean(trimText(canvasToken)),
      modelSuggestions: MODEL_SUGGESTIONS,
      defaults: DEFAULT_MODELS,
      options: {
        reasoning: REASONING_OPTIONS,
        verbosity: VERBOSITY_OPTIONS,
        serviceTier: SERVICE_TIER_OPTIONS,
      },
    },
  };
}

function enrichStateForRenderer(rawState) {
  const paths = storagePaths();
  const snapshot = deepClone(rawState);

  for (const session of snapshot.sessions) {
    ensureSessionDefaults(session);
    session.hasPendingRubricGeneration = session.rubricProcessing?.state === "pending" && Boolean(session.rubricProcessing?.batchID);
    session.hasFailedRubricGeneration = session.rubricProcessing?.state === "failed";
    session.hasPendingRubricReview = Boolean(session.pendingRubricPayload);
    session.validationModelIDResolved = trimText(session.validationModelID) || session.gradingModelID;
    session.validationModelLabel = session.validationEnabled ? session.validationModelIDResolved : "Disabled";
    session.validationMaxAttemptsResolved = Math.max(Number(session.validationMaxAttempts || 2), 1);
    session.sessionCostLabel = formatUSD(session.estimatedCostUSD || 0);
    session.pointModeLabel = session.integerPointsOnly ? "Integers only" : "Fractional allowed";
    session.relaxedModeLabel = session.relaxedGradingMode ? "On" : "Off";
    session.answerReasoningLabel = labelForOption(session.answerReasoningEffort ?? null, REASONING_OPTIONS);
    session.gradingReasoningLabel = labelForOption(session.gradingReasoningEffort ?? null, REASONING_OPTIONS);
    session.validationReasoningLabel = session.validationEnabled
      ? labelForOption(session.validationReasoningEffort ?? null, REASONING_OPTIONS)
      : "Disabled";
    session.answerVerbosityLabel = labelForOption(session.answerVerbosity ?? null, VERBOSITY_OPTIONS);
    session.gradingVerbosityLabel = labelForOption(session.gradingVerbosity ?? null, VERBOSITY_OPTIONS);
    session.validationVerbosityLabel = session.validationEnabled
      ? labelForOption(session.validationVerbosity ?? null, VERBOSITY_OPTIONS)
      : "Disabled";
    session.answerServiceTierLabel = labelForOption(session.answerServiceTier ?? null, SERVICE_TIER_OPTIONS);
    session.gradingServiceTierLabel = labelForOption(session.gradingServiceTier ?? null, SERVICE_TIER_OPTIONS);
    session.validationServiceTierLabel = session.validationEnabled
      ? labelForOption(session.validationServiceTier ?? null, SERVICE_TIER_OPTIONS)
      : "Disabled";
    session.totalPossiblePoints = (session.questions || []).reduce((sum, question) => sum + Number(question.maxPoints || 0), 0);
    attachPreviewURLs(session.masterAssets || [], paths.assetsRoot);
    session.canvasModule = canvasConnect.ensureCanvasModule(session);
    session.canvasModule.rosterCount = session.canvasModule.roster.length;
    session.canvasModule.matchSummary = canvasConnect.summarizeMatchRecords(session.canvasModule.matches || []);
    session.canvasModule.lockedSummary = canvasConnect.summarizeLockedRecords(session.canvasModule.matches || []);

    for (const submission of session.submissions || []) {
      attachPreviewURLs(submission.assets || [], paths.assetsRoot);
      submission.listDisplayName = trimText(submission.studentName) || "Unnamed Student";
      submission.hasQuestionNeedingReview = (submission.grades || []).some((grade) => Boolean(grade.needsReview));
      submission.isQueuedForRubric = submission.processingState === "pending" && submission.batchStage === "queued";
      submission.isAwaitingRemoteProcessing = submission.processingState === "pending" && submission.batchStage !== "queued";
      submission.isProcessingPending = submission.processingState === "pending";
      submission.isProcessingFailed = submission.processingState === "failed";
      submission.isProcessingCompleted = submission.processingState === "completed";
      submission.validationNeedsReviewEnabled = Boolean(submission.validationNeedsReview);
      submission.nameNeedsReviewEnabled = Boolean(submission.nameNeedsReview);
      submission.needsAttentionEnabled = Boolean(submission.needsAttention);
    }
  }

  return snapshot;
}

function ensureSessionDefaults(session) {
  canvasConnect.ensureCanvasModule(session);
  return session;
}

function attachPreviewURLs(assets, assetRoot) {
  for (const asset of assets || []) {
    asset.previewURL = pathToFileURL(path.join(assetRoot, asset.storedPath)).toString();
  }
}

function broadcastState() {
  if (mainWindow && !mainWindow.isDestroyed()) {
    mainWindow.webContents.send("state:updated", buildSnapshot());
  }
}

async function persistAndBroadcast() {
  await savePersistedState();
  broadcastState();
}

function getSession(sessionId) {
  const session = state.sessions.find((item) => item.id === sessionId);
  if (!session) {
    throw new Error("Session not found.");
  }
  return session;
}

function getSubmission(session, submissionId) {
  const submission = (session.submissions || []).find((item) => item.id === submissionId);
  if (!submission) {
    throw new Error("Submission not found.");
  }
  return submission;
}

function sessionAssetDir(sessionId, bucket, childId = null) {
  const parts = ["sessions", sessionId, bucket];
  if (childId) {
    parts.push(childId);
  }
  return parts;
}

function detectAssetMetadata(filePath) {
  const extension = path.extname(filePath).toLowerCase();
  if (extension === ".pdf") {
    return { kind: "pdf", mimeType: "application/pdf" };
  }
  const imageMimes = {
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".png": "image/png",
    ".webp": "image/webp",
  };
  if (imageMimes[extension]) {
    return { kind: "image", mimeType: imageMimes[extension] };
  }
  throw new Error(`Unsupported file type: ${path.basename(filePath)}. Use PDFs or common image formats such as JPG, PNG, or WebP.`);
}

async function copyInputFiles(filePaths, bucketParts) {
  const paths = storagePaths();
  const targetDir = path.join(paths.assetsRoot, ...bucketParts);
  await fs.mkdir(targetDir, { recursive: true });
  const assets = [];

  for (let index = 0; index < filePaths.length; index += 1) {
    const sourcePath = filePaths[index];
    const metadata = detectAssetMetadata(sourcePath);
    const extension = path.extname(sourcePath).toLowerCase();
    const fileName = `${String(index + 1).padStart(3, "0")}-${uuid()}${extension}`;
    const destination = path.join(targetDir, fileName);
    const stats = await fs.stat(sourcePath);
    await fs.copyFile(sourcePath, destination);
    assets.push({
      id: uuid(),
      kind: metadata.kind,
      mimeType: metadata.mimeType,
      originalName: path.basename(sourcePath),
      storedPath: path.relative(paths.assetsRoot, destination),
      size: stats.size,
      createdAt: nowISO(),
    });
  }

  return assets;
}

function materializeAttachments(assets) {
  const paths = storagePaths();
  return (assets || []).map((asset) => ({
    ...asset,
    absolutePath: path.join(paths.assetsRoot, asset.storedPath),
  }));
}

function removeSessionAssets(sessionId) {
  const paths = storagePaths();
  return fs.rm(path.join(paths.assetsRoot, "sessions", sessionId), { recursive: true, force: true });
}

function formatUSD(value) {
  return new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" }).format(Number(value || 0));
}

function detailTextForBatchStatus(status, requestCounts) {
  const counts = requestCounts
    ? ` ${requestCounts.completed} completed, ${requestCounts.failed} failed, ${Math.max(requestCounts.total - requestCounts.completed - requestCounts.failed, 0)} remaining.`
    : "";
  switch (status) {
    case "validating":
      return `OpenAI is validating the uploaded batch input.${counts}`;
    case "in_progress":
      return `OpenAI is processing the batch.${counts}`;
    case "finalizing":
      return `OpenAI is preparing the batch output files.${counts}`;
    case "completed":
      return `OpenAI completed the batch.${counts}`;
    case "failed":
      return `OpenAI marked the batch as failed.${counts}`;
    case "expired":
      return `OpenAI let the batch expire before it finished.${counts}`;
    case "cancelled":
      return `OpenAI cancelled the batch.${counts}`;
    default:
      return `Batch status: ${status}.${counts}`;
  }
}

function createSessionFromInput(input) {
  const title = trimText(input.title);
  const answerModelID = trimText(input.answerModelID || DEFAULT_MODELS.answer);
  const gradingModelID = trimText(input.gradingModelID || DEFAULT_MODELS.grading);
  if (!title || !answerModelID || !gradingModelID) {
    throw new Error("Session title, answer model, and grading model are required.");
  }
  return {
    id: uuid(),
    title,
    createdAt: nowISO(),
    answerModelID,
    gradingModelID,
    validationEnabled: Boolean(input.validationEnabled),
    validationModelID: trimText(input.validationModelID || DEFAULT_MODELS.validation) || null,
    answerReasoningEffort: input.answerReasoningEffort ?? "high",
    gradingReasoningEffort: input.gradingReasoningEffort ?? "high",
    validationReasoningEffort: input.validationReasoningEffort ?? "high",
    answerVerbosity: input.answerVerbosity ?? null,
    gradingVerbosity: input.gradingVerbosity ?? null,
    validationVerbosity: input.validationVerbosity ?? null,
    answerServiceTier: input.answerServiceTier ?? "flex",
    gradingServiceTier: input.gradingServiceTier ?? "flex",
    validationServiceTier: input.validationServiceTier ?? "flex",
    validationMaxAttempts: Math.max(Number(input.validationMaxAttempts || 2), 1),
    overallGradingRules: null,
    relaxedGradingMode: Boolean(input.relaxedGradingMode),
    estimatedCostUSD: 0,
    apiKeyFingerprint: fingerprintAPIKey(apiKey),
    integerPointsOnly: Boolean(input.integerPointsOnly),
    isFinished: false,
    rubricApprovedAt: null,
    rubricProcessing: null,
    pendingRubricPayload: null,
    masterAssets: [],
    questions: [],
    submissions: [],
    canvasModule: canvasConnect.defaultCanvasModule(),
  };
}

function normalizeSessionToIntegerPoints(session) {
  for (const question of session.questions || []) {
    question.maxPoints = normalizePointValue(question.maxPoints, true);
  }
  for (const submission of session.submissions || []) {
    submission.grades = (submission.grades || []).map((grade) => ({
      ...grade,
      maxPoints: normalizePointValue(grade.maxPoints, true),
      awardedPoints: normalizePointValue(grade.awardedPoints, true, normalizePointValue(grade.maxPoints, true)),
    }));
    submission.totalScore = totalScoreFromGrades(submission.grades);
    submission.maxScore = maxScoreFromGrades(submission.grades);
  }
}

function updateSessionConfig(session, input) {
  const wasIntegerOnly = Boolean(session.integerPointsOnly);
  session.answerModelID = trimText(input.answerModelID);
  session.gradingModelID = trimText(input.gradingModelID);
  session.validationEnabled = Boolean(input.validationEnabled);
  session.validationModelID = session.validationEnabled ? trimText(input.validationModelID) || session.gradingModelID : null;
  session.integerPointsOnly = Boolean(input.integerPointsOnly);
  session.relaxedGradingMode = Boolean(input.relaxedGradingMode);
  session.isFinished = Boolean(input.isFinished);
  session.answerReasoningEffort = input.answerReasoningEffort ?? null;
  session.gradingReasoningEffort = input.gradingReasoningEffort ?? null;
  session.validationReasoningEffort = input.validationReasoningEffort ?? null;
  session.answerVerbosity = input.answerVerbosity ?? null;
  session.gradingVerbosity = input.gradingVerbosity ?? null;
  session.validationVerbosity = input.validationVerbosity ?? null;
  session.answerServiceTier = input.answerServiceTier ?? null;
  session.gradingServiceTier = input.gradingServiceTier ?? null;
  session.validationServiceTier = input.validationServiceTier ?? null;
  session.validationMaxAttempts = Math.max(Number(input.validationMaxAttempts || 2), 1);
  if (!wasIntegerOnly && session.integerPointsOnly) {
    normalizeSessionToIntegerPoints(session);
  }
}

function questionSnapshots(session) {
  return (session.questions || [])
    .slice()
    .sort((a, b) => a.orderIndex - b.orderIndex)
    .map((question) => ({
      questionID: question.questionID,
      displayLabel: question.displayLabel,
      promptText: question.promptText,
      idealAnswer: question.idealAnswer,
      gradingCriteria: question.gradingCriteria,
      maxPoints: Number(question.maxPoints || 0),
    }));
}

function createSubmissionDraftFromPayload(payload, rubricSnapshots, assets, integerPointsOnly) {
  const payloadByQuestionID = new Map((payload.question_results || []).map((item) => [item.question_id, item]));
  const grades = rubricSnapshots.map((question) => {
    const result = payloadByQuestionID.get(question.questionID);
    if (result) {
      return {
        questionID: question.questionID,
        displayLabel: question.displayLabel,
        awardedPoints: normalizePointValue(result.awarded_points, integerPointsOnly, question.maxPoints),
        maxPoints: question.maxPoints,
        isAnswerCorrect: Boolean(result.is_answer_correct),
        isProcessCorrect: Boolean(result.is_process_correct),
        feedback: result.feedback || "",
        needsReview:
          Boolean(result.needs_review) ||
          Math.abs(Number(result.max_points || 0) - Number(question.maxPoints || 0)) > 0.001 ||
          (integerPointsOnly && Math.abs(Math.round(Number(result.awarded_points || 0)) - Number(result.awarded_points || 0)) > 0.001),
      };
    }
    return {
      questionID: question.questionID,
      displayLabel: question.displayLabel,
      awardedPoints: 0,
      maxPoints: question.maxPoints,
      isAnswerCorrect: false,
      isProcessCorrect: false,
      feedback: "No model result was returned for this question. Teacher review is required.",
      needsReview: true,
    };
  });

  const draft = {
    studentName: trimText(payload.student_name),
    nameNeedsReview: Boolean(payload.student_name_needs_review) || !trimText(payload.student_name),
    needsAttention: Boolean(payload.needs_attention),
    attentionReasonsText: (payload.attention_reasons || []).join("\n"),
    validationNeedsReview: false,
    overallNotes: payload.overall_notes || "",
    grades,
    assets: deepClone(assets),
  };
  draft.totalScore = totalScoreFromGrades(grades);
  draft.maxScore = maxScoreFromGrades(grades);
  return normalizeDraft(draft, integerPointsOnly);
}

function normalizeDraft(draft, integerPointsOnly) {
  const copy = deepClone(draft);
  copy.attentionReasonsText = trimText(copy.attentionReasonsText);
  if (!copy.needsAttention) {
    copy.attentionReasonsText = "";
  }
  if (integerPointsOnly) {
    copy.grades = (copy.grades || []).map((grade) => ({
      ...grade,
      maxPoints: normalizePointValue(grade.maxPoints, true),
      awardedPoints: normalizePointValue(grade.awardedPoints, true, normalizePointValue(grade.maxPoints, true)),
    }));
  }
  copy.totalScore = totalScoreFromGrades(copy.grades || []);
  copy.maxScore = maxScoreFromGrades(copy.grades || []);
  return copy;
}

async function runLiveSubmissionProcessor(session, attachments) {
  const usageSummaries = [];
  const rubric = questionSnapshots(session);
  const grading = await openAI.gradeSubmission({
    apiKey,
    modelID: session.gradingModelID,
    rubric,
    overallRules: session.overallGradingRules,
    attachments,
    integerPointsOnly: session.integerPointsOnly,
    relaxedGradingMode: session.relaxedGradingMode,
    previousGrading: null,
    validatorFeedback: null,
    reasoningEffort: session.gradingReasoningEffort,
    verbosity: session.gradingVerbosity,
    serviceTier: session.gradingServiceTier,
  });
  if (grading.usage) {
    usageSummaries.push(grading.usage);
  }

  let draft = createSubmissionDraftFromPayload(grading.payload, rubric, attachments, session.integerPointsOnly);
  let latestPayload = grading.payload;
  let latestValidationPayload = null;
  let approved = !session.validationEnabled;

  if (session.validationEnabled) {
    for (let attempt = 1; attempt <= Math.max(Number(session.validationMaxAttempts || 2), 1); attempt += 1) {
      const validation = await openAI.validateSubmissionGrade({
        apiKey,
        modelID: trimText(session.validationModelID) || session.gradingModelID,
        rubric,
        overallRules: session.overallGradingRules,
        candidateGrading: latestPayload,
        attachments,
        integerPointsOnly: session.integerPointsOnly,
        relaxedGradingMode: session.relaxedGradingMode,
        reasoningEffort: session.validationReasoningEffort,
        verbosity: session.validationVerbosity,
        serviceTier: session.validationServiceTier,
      });
      latestValidationPayload = validation.payload;
      if (validation.usage) {
        usageSummaries.push(validation.usage);
      }

      if (validation.payload.is_grading_correct) {
        approved = true;
        break;
      }

      if (attempt === Math.max(Number(session.validationMaxAttempts || 2), 1)) {
        break;
      }

      const regrade = await openAI.gradeSubmission({
        apiKey,
        modelID: session.gradingModelID,
        rubric,
        overallRules: session.overallGradingRules,
        attachments,
        integerPointsOnly: session.integerPointsOnly,
        relaxedGradingMode: session.relaxedGradingMode,
        previousGrading: latestPayload,
        validatorFeedback: validation.payload,
        reasoningEffort: session.gradingReasoningEffort,
        verbosity: session.gradingVerbosity,
        serviceTier: session.gradingServiceTier,
      });
      latestPayload = regrade.payload;
      if (regrade.usage) {
        usageSummaries.push(regrade.usage);
      }
      draft = createSubmissionDraftFromPayload(regrade.payload, rubric, attachments, session.integerPointsOnly);
    }
  }

  if (!approved) {
    draft.validationNeedsReview = true;
    const attempts = Math.max(Number(session.validationMaxAttempts || 2), 1);
    const message = attempts === 1
      ? "Automated validation could not fully confirm this grading after 1 validation attempt."
      : `Automated validation could not fully confirm this grading after ${attempts} validation attempts.`;
    draft.overallNotes = [message, draft.overallNotes].filter(Boolean).join("\n\n");
  }

  return {
    draft: normalizeDraft(draft, session.integerPointsOnly),
    usageSummaries,
    latestSubmissionPayload: latestPayload,
    latestValidationPayload,
  };
}

function recordUsage(session, usage) {
  if (!usage) {
    return;
  }
  session.estimatedCostUSD = Number(session.estimatedCostUSD || 0) + Number(usage.estimatedCostUSD || 0);
  if (!session.apiKeyFingerprint && apiKey) {
    session.apiKeyFingerprint = fingerprintAPIKey(apiKey);
  }
}

function createStoredSubmission(session, draft, assets) {
  const normalized = normalizeDraft(draft, session.integerPointsOnly);
  return {
    id: uuid(),
    createdAt: nowISO(),
    studentName: trimText(normalized.studentName),
    nameNeedsReview: Boolean(normalized.nameNeedsReview),
    needsAttention: Boolean(normalized.needsAttention),
    attentionReasonsText: trimText(normalized.attentionReasonsText),
    validationNeedsReview: Boolean(normalized.validationNeedsReview),
    overallNotes: trimText(normalized.overallNotes),
    teacherReviewed: true,
    totalScore: normalized.totalScore,
    maxScore: normalized.maxScore,
    processingState: "completed",
    batchStage: null,
    batchAttemptNumber: null,
    processingDetail: null,
    remoteBatchID: null,
    remoteBatchRequestID: null,
    assets,
    grades: normalized.grades,
    latestSubmissionPayload: null,
    latestValidationPayload: null,
    debugInfo: { traces: [] },
  };
}

function updateStoredSubmission(session, submission, draft) {
  const normalized = normalizeDraft(draft, session.integerPointsOnly);
  submission.studentName = trimText(normalized.studentName);
  submission.nameNeedsReview = Boolean(normalized.nameNeedsReview);
  submission.needsAttention = Boolean(normalized.needsAttention);
  submission.attentionReasonsText = trimText(normalized.attentionReasonsText);
  submission.validationNeedsReview = Boolean(normalized.validationNeedsReview);
  submission.overallNotes = trimText(normalized.overallNotes);
  submission.teacherReviewed = true;
  submission.totalScore = normalized.totalScore;
  submission.maxScore = normalized.maxScore;
  submission.processingState = "completed";
  submission.batchStage = null;
  submission.batchAttemptNumber = null;
  submission.processingDetail = null;
  submission.remoteBatchID = null;
  submission.remoteBatchRequestID = null;
  submission.grades = normalized.grades;
  submission.latestValidationPayload = null;
}

function createPendingSubmissionPlaceholder(session, assets, labelPrefix, note, stage, requestID) {
  return {
    id: uuid(),
    createdAt: nowISO(),
    studentName: `${labelPrefix} ${session.submissions.length + 1}`,
    nameNeedsReview: false,
    needsAttention: false,
    attentionReasonsText: "",
    validationNeedsReview: false,
    overallNotes: note,
    teacherReviewed: false,
    totalScore: 0,
    maxScore: (session.questions || []).reduce((sum, question) => sum + Number(question.maxPoints || 0), 0),
    processingState: "pending",
    batchStage: stage,
    batchAttemptNumber: stage === "queued" ? null : 0,
    processingDetail: note,
    remoteBatchID: null,
    remoteBatchRequestID: requestID,
    assets,
    grades: [],
    latestSubmissionPayload: null,
    latestValidationPayload: null,
    debugInfo: { traces: [] },
  };
}

function completeSubmissionFromPayload(session, submission, payload, validationNeedsReview, reviewMessage) {
  const draft = createSubmissionDraftFromPayload(payload, questionSnapshots(session), submission.assets, session.integerPointsOnly);
  if (validationNeedsReview) {
    draft.validationNeedsReview = true;
    draft.overallNotes = [reviewMessage, draft.overallNotes].filter(Boolean).join("\n\n");
  }
  submission.studentName = trimText(draft.studentName);
  submission.nameNeedsReview = Boolean(draft.nameNeedsReview);
  submission.needsAttention = Boolean(draft.needsAttention);
  submission.attentionReasonsText = trimText(draft.attentionReasonsText);
  submission.validationNeedsReview = Boolean(draft.validationNeedsReview);
  submission.overallNotes = trimText(draft.overallNotes);
  submission.teacherReviewed = false;
  submission.totalScore = draft.totalScore;
  submission.maxScore = draft.maxScore;
  submission.processingState = "completed";
  submission.batchStage = null;
  submission.batchAttemptNumber = null;
  submission.processingDetail = null;
  submission.remoteBatchID = null;
  submission.remoteBatchRequestID = null;
  submission.grades = draft.grades;
}

function markSubmissionFailed(session, submission, message) {
  submission.processingState = "failed";
  submission.batchStage = null;
  submission.batchAttemptNumber = null;
  submission.processingDetail = message;
  submission.remoteBatchID = null;
  submission.remoteBatchRequestID = null;
  submission.teacherReviewed = false;
  submission.needsAttention = false;
  submission.attentionReasonsText = "";
  submission.validationNeedsReview = false;
  submission.latestSubmissionPayload = null;
  submission.latestValidationPayload = null;
  submission.grades = [];
  submission.totalScore = 0;
  submission.maxScore = (session.questions || []).reduce((sum, question) => sum + Number(question.maxPoints || 0), 0);
  submission.overallNotes = message;
}

async function submitQueuedFollowupBatches(session) {
  if (!trimText(apiKey)) {
    return;
  }
  await submitQueuedValidationBatch(session);
  await submitQueuedRegradingBatch(session);
}

async function submitQueuedValidationBatch(session) {
  const queued = (session.submissions || []).filter(
    (submission) => submission.processingState === "pending" && !submission.remoteBatchRequestID && submission.batchStage === "validating"
  );
  if (!queued.length) {
    return;
  }

  for (const submission of queued) {
    submission.remoteBatchRequestID = `validate-${submission.id}-${uuid()}`;
    submission.processingDetail = `Preparing validation pass ${Math.max(Number(submission.batchAttemptNumber || 1), 1)} batch submission.`;
  }

  const creation = await openAI.createSubmissionValidationBatch({
    apiKey,
    modelID: trimText(session.validationModelID) || session.gradingModelID,
    rubric: questionSnapshots(session),
    overallRules: session.overallGradingRules,
    submissions: queued.map((submission) => ({
      customID: submission.remoteBatchRequestID,
      attachments: materializeAttachments(submission.assets),
      candidateGrading: submission.latestSubmissionPayload,
    })),
    integerPointsOnly: session.integerPointsOnly,
    relaxedGradingMode: session.relaxedGradingMode,
    reasoningEffort: session.validationReasoningEffort,
    verbosity: session.validationVerbosity,
  });

  for (const submission of queued) {
    submission.remoteBatchID = creation.batchID;
    submission.processingDetail = `Validation pass ${Math.max(Number(submission.batchAttemptNumber || 1), 1)} batch submitted. ${detailTextForBatchStatus(creation.status, null)}`;
  }
}

async function submitQueuedRegradingBatch(session) {
  const queued = (session.submissions || []).filter(
    (submission) => submission.processingState === "pending" && !submission.remoteBatchRequestID && submission.batchStage === "regrading"
  );
  if (!queued.length) {
    return;
  }

  for (const submission of queued) {
    submission.remoteBatchRequestID = `regrade-${submission.id}-${uuid()}`;
    submission.processingDetail = `Preparing regrade pass ${Math.max(Number(submission.batchAttemptNumber || 1), 1)} batch submission.`;
  }

  const creation = await openAI.createSubmissionRegradingBatch({
    apiKey,
    modelID: session.gradingModelID,
    rubric: questionSnapshots(session),
    overallRules: session.overallGradingRules,
    submissions: queued.map((submission) => ({
      customID: submission.remoteBatchRequestID,
      attachments: materializeAttachments(submission.assets),
      previousGrading: submission.latestSubmissionPayload,
      validatorFeedback: submission.latestValidationPayload,
    })),
    integerPointsOnly: session.integerPointsOnly,
    relaxedGradingMode: session.relaxedGradingMode,
    reasoningEffort: session.gradingReasoningEffort,
    verbosity: session.gradingVerbosity,
  });

  for (const submission of queued) {
    submission.remoteBatchID = creation.batchID;
    submission.processingDetail = `Regrade pass ${Math.max(Number(submission.batchAttemptNumber || 1), 1)} batch submitted. ${detailTextForBatchStatus(creation.status, null)}`;
  }
}

async function refreshPendingWork({ sessionId = null, notify = false } = {}) {
  if (!trimText(apiKey)) {
    return;
  }

  const sessions = sessionId ? [getSession(sessionId)] : state.sessions.slice();

  for (const session of sessions) {
    if (session.rubricProcessing?.state === "pending" && session.rubricProcessing.batchID) {
      const snapshot = await openAI.fetchBatchStatus(apiKey, session.rubricProcessing.batchID);
      if (snapshot.status === "completed") {
        const results = snapshot.outputFileID
          ? await openAI.fetchAnswerKeyBatchResults(apiKey, session.answerModelID, snapshot.outputFileID)
          : [];
        const errors = snapshot.errorFileID ? await openAI.fetchBatchErrors(apiKey, snapshot.errorFileID) : [];
        const result = results.find((item) => item.customID === session.rubricProcessing.requestID);
        const error = errors.find((item) => item.customID === session.rubricProcessing.requestID);
        if (result) {
          recordUsage(session, result.usage);
          if ((result.payload.questions || []).length) {
            session.pendingRubricPayload = result.payload;
            session.rubricProcessing = null;
            if (notify) {
              showNotification("Answer Key Ready", `${session.title} has a generated rubric ready for review.`);
            }
          } else {
            session.rubricProcessing = { state: "failed", detail: "The model did not return any gradeable questions. Try rescanning the blank assignment." };
          }
        } else if (error) {
          session.rubricProcessing = { state: "failed", detail: error.message };
        } else {
          session.rubricProcessing = { state: "failed", detail: "OpenAI completed the answer key batch but did not return a result." };
        }
      } else if (["failed", "expired", "cancelled"].includes(snapshot.status)) {
        session.rubricProcessing = {
          state: "failed",
          detail: snapshot.errors[0] || detailTextForBatchStatus(snapshot.status, snapshot.requestCounts),
        };
      } else {
        session.rubricProcessing.detail = detailTextForBatchStatus(snapshot.status, snapshot.requestCounts);
      }
    }

    const activeBatchIDs = [...new Set((session.submissions || []).filter((item) => item.processingState === "pending" && item.remoteBatchID).map((item) => item.remoteBatchID))];
    const pendingBefore = (session.submissions || []).filter((item) => item.processingState === "pending").length;

    for (const batchID of activeBatchIDs) {
      const snapshot = await openAI.fetchBatchStatus(apiKey, batchID);
      const pendingSubmissions = (session.submissions || []).filter(
        (item) => item.processingState === "pending" && item.remoteBatchID === batchID
      );
      const stage = pendingSubmissions[0]?.batchStage;

      if (["failed", "expired", "cancelled"].includes(snapshot.status)) {
        for (const submission of pendingSubmissions) {
          markSubmissionFailed(session, submission, snapshot.errors[0] || detailTextForBatchStatus(snapshot.status, snapshot.requestCounts));
        }
        continue;
      }

      if (snapshot.status !== "completed") {
        for (const submission of pendingSubmissions) {
          submission.processingDetail = detailTextForBatchStatus(snapshot.status, snapshot.requestCounts);
        }
        continue;
      }

      if (stage === "grading") {
        const results = snapshot.outputFileID
          ? await openAI.fetchSubmissionBatchResults(apiKey, session.gradingModelID, snapshot.outputFileID)
          : [];
        const errors = snapshot.errorFileID ? await openAI.fetchBatchErrors(apiKey, snapshot.errorFileID) : [];

        for (const submission of pendingSubmissions) {
          const result = results.find((item) => item.customID === submission.remoteBatchRequestID);
          const error = errors.find((item) => item.customID === submission.remoteBatchRequestID);
          if (result) {
            recordUsage(session, result.usage);
            submission.latestSubmissionPayload = result.payload;
            submission.latestValidationPayload = null;
            if (session.validationEnabled) {
              submission.batchStage = "validating";
              submission.batchAttemptNumber = 1;
              submission.remoteBatchID = null;
              submission.remoteBatchRequestID = null;
              submission.processingDetail = "Queued for validation pass 1.";
            } else {
              completeSubmissionFromPayload(session, submission, result.payload, false, null);
            }
          } else if (error) {
            markSubmissionFailed(session, submission, error.message);
          } else {
            markSubmissionFailed(session, submission, "OpenAI completed the batch but did not return a result for this submission.");
          }
        }
      } else if (stage === "validating") {
        const validationModel = trimText(session.validationModelID) || session.gradingModelID;
        const results = snapshot.outputFileID
          ? await openAI.fetchValidationBatchResults(apiKey, validationModel, snapshot.outputFileID)
          : [];
        const errors = snapshot.errorFileID ? await openAI.fetchBatchErrors(apiKey, snapshot.errorFileID) : [];

        for (const submission of pendingSubmissions) {
          const result = results.find((item) => item.customID === submission.remoteBatchRequestID);
          const error = errors.find((item) => item.customID === submission.remoteBatchRequestID);
          if (result) {
            recordUsage(session, result.usage);
            submission.latestValidationPayload = result.payload;
            if (result.payload.is_grading_correct) {
              completeSubmissionFromPayload(session, submission, submission.latestSubmissionPayload, false, null);
            } else if (Math.max(Number(submission.batchAttemptNumber || 1), 1) >= Math.max(Number(session.validationMaxAttempts || 2), 1)) {
              const attempts = Math.max(Number(session.validationMaxAttempts || 2), 1);
              const message = attempts === 1
                ? "Automated validation could not fully confirm this grading after 1 validation attempt."
                : `Automated validation could not fully confirm this grading after ${attempts} validation attempts.`;
              if (submission.latestSubmissionPayload) {
                completeSubmissionFromPayload(session, submission, submission.latestSubmissionPayload, true, message);
              } else {
                markSubmissionFailed(session, submission, message);
              }
            } else {
              submission.batchStage = "regrading";
              submission.remoteBatchID = null;
              submission.remoteBatchRequestID = null;
              submission.processingDetail = `Queued for regrade pass ${Math.max(Number(submission.batchAttemptNumber || 1), 1)} after validation pass ${Math.max(Number(submission.batchAttemptNumber || 1), 1)}.`;
            }
          } else if (error) {
            if (submission.latestSubmissionPayload) {
              completeSubmissionFromPayload(session, submission, submission.latestSubmissionPayload, true, `Validation batch could not finish automatically. ${error.message}`);
            } else {
              markSubmissionFailed(session, submission, `Validation batch could not finish automatically. ${error.message}`);
            }
          } else {
            markSubmissionFailed(session, submission, "OpenAI completed the validation batch but did not return a result for this submission.");
          }
        }
      } else if (stage === "regrading") {
        const results = snapshot.outputFileID
          ? await openAI.fetchSubmissionBatchResults(apiKey, session.gradingModelID, snapshot.outputFileID)
          : [];
        const errors = snapshot.errorFileID ? await openAI.fetchBatchErrors(apiKey, snapshot.errorFileID) : [];

        for (const submission of pendingSubmissions) {
          const result = results.find((item) => item.customID === submission.remoteBatchRequestID);
          const error = errors.find((item) => item.customID === submission.remoteBatchRequestID);
          if (result) {
            recordUsage(session, result.usage);
            submission.latestSubmissionPayload = result.payload;
            submission.latestValidationPayload = null;
            submission.batchStage = "validating";
            submission.batchAttemptNumber = Math.max(Number(submission.batchAttemptNumber || 1), 1) + 1;
            submission.remoteBatchID = null;
            submission.remoteBatchRequestID = null;
            submission.processingDetail = `Queued for validation pass ${submission.batchAttemptNumber}.`;
          } else if (error) {
            if (submission.latestSubmissionPayload) {
              completeSubmissionFromPayload(session, submission, submission.latestSubmissionPayload, true, `Regrade batch could not finish automatically. ${error.message}`);
            } else {
              markSubmissionFailed(session, submission, `Regrade batch could not finish automatically. ${error.message}`);
            }
          } else {
            markSubmissionFailed(session, submission, "OpenAI completed the regrade batch but did not return a result for this submission.");
          }
        }
      }
    }

    await submitQueuedFollowupBatches(session);

    const pendingAfter = (session.submissions || []).filter((item) => item.processingState === "pending").length;
    if (notify && pendingBefore > 0 && pendingAfter === 0) {
      const completed = (session.submissions || []).filter((item) => item.processingState === "completed").length;
      const failed = (session.submissions || []).filter((item) => item.processingState === "failed").length;
      showNotification("Batch Grading Finished", `${session.title}: ${completed} completed, ${failed} failed.`);
    }
  }
}

function showNotification(title, body) {
  if (!Notification.isSupported()) {
    return;
  }
  new Notification({ title, body }).show();
}

function makeWindow() {
  mainWindow = new BrowserWindow({
    width: 1480,
    height: 980,
    minWidth: 1180,
    minHeight: 760,
    backgroundColor: "#f7f1e6",
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
    },
  });

  mainWindow.loadFile(path.join(__dirname, "index.html"));
}

async function handleCreateSession(_event, payload) {
  return enqueue(async () => {
    const session = createSessionFromInput(payload);
    state.sessions.unshift(session);
    await persistAndBroadcast();
    return { sessionId: session.id };
  });
}

async function handleUpdateSession(_event, payload) {
  return enqueue(async () => {
    const session = getSession(payload.sessionId);
    updateSessionConfig(session, payload);
    await persistAndBroadcast();
    return { ok: true };
  });
}

async function handleDeleteSession(_event, sessionId) {
  return enqueue(async () => {
    state.sessions = state.sessions.filter((session) => session.id !== sessionId);
    await removeSessionAssets(sessionId);
    await persistAndBroadcast();
    return { ok: true };
  });
}

async function handleSaveAPIKey(_event, nextValue) {
  return enqueue(async () => {
    await persistAPIKey(nextValue);
    await persistAndBroadcast();
    return { ok: true };
  });
}

async function handleTestAPIKey() {
  return enqueue(async () => {
    await openAI.validateAPIKey(apiKey, DEFAULT_MODELS.grading);
    return { ok: true };
  });
}

async function handleFetchOrganizationCost() {
  return enqueue(async () => {
    const summary = await openAI.fetchOrganizationTotalCost(apiKey);
    state.settings.organizationCostSummary = summary;
    await persistAndBroadcast();
    return summary;
  });
}

async function handleUploadMaster(_event, { sessionId, filePaths }) {
  return enqueue(async () => {
    const session = getSession(sessionId);
    if (!trimText(apiKey)) {
      throw new Error("Add your OpenAI API key in Settings before scanning or grading.");
    }
    if (session.questions.length) {
      throw new Error("This session already has an approved rubric. Create a new session to rescan the master assignment.");
    }
    const selectedAssets = filePaths.map((filePath) => ({
      filePath,
      ...detectAssetMetadata(filePath),
    }));
    const validation = validateMasterAssetGroup(selectedAssets);
    if (!validation.ok) {
      throw new Error(validation.message);
    }
    const masterAssets = await copyInputFiles(filePaths, sessionAssetDir(session.id, "master", uuid()));
    session.masterAssets = masterAssets;
    session.pendingRubricPayload = null;
    session.rubricProcessing = null;

    const requestID = `answer-key-${session.id}-${uuid()}`;
    const creation = await openAI.createAnswerKeyBatch({
      apiKey,
      modelID: session.answerModelID,
      sessionTitle: session.title,
      submissions: [{ customID: requestID, attachments: materializeAttachments(masterAssets) }],
      reasoningEffort: session.answerReasoningEffort,
      verbosity: session.answerVerbosity,
    });
    session.rubricProcessing = {
      state: "pending",
      detail: detailTextForBatchStatus(creation.status, null),
      batchID: creation.batchID,
      requestID,
    };
    await persistAndBroadcast();
    await refreshPendingWork({ sessionId: session.id, notify: false });
    await persistAndBroadcast();
    return { ok: true };
  });
}

async function handleSaveRubric(_event, { sessionId, overallRules, questionDrafts }) {
  return enqueue(async () => {
    const session = getSession(sessionId);
    if (!Array.isArray(questionDrafts) || !questionDrafts.length) {
      throw new Error("At least one rubric question is required.");
    }
    session.overallGradingRules = trimText(overallRules) || null;
    session.questions = questionDrafts.map((draft, index) => {
      const parsed = parsePointValue(draft.maxPointsText, session.integerPointsOnly);
      if (parsed == null) {
        throw new Error(`Enter valid max points for ${draft.displayLabel || draft.questionID || `Question ${index + 1}`}.`);
      }
      return {
        id: uuid(),
        orderIndex: index,
        questionID: trimText(draft.questionID),
        displayLabel: trimText(draft.displayLabel),
        promptText: trimText(draft.promptText),
        idealAnswer: trimText(draft.idealAnswer),
        gradingCriteria: trimText(draft.gradingCriteria),
        maxPoints: parsed,
      };
    });
    session.pendingRubricPayload = null;
    session.rubricProcessing = null;
    session.rubricApprovedAt = nowISO();
    await persistAndBroadcast();
    return { ok: true };
  });
}

function buildBatchGroups(filePaths, mode, filesPerSubmission) {
  const items = filePaths.map((filePath) => ({
    filePath,
    ...detectAssetMetadata(filePath),
  }));

  if (!items.length) {
    throw new Error("No files were selected.");
  }

  if (mode === "each-file") {
    return items.map((item) => [item]);
  }

  const groupSize = Number(filesPerSubmission || 0);
  if (!Number.isInteger(groupSize) || groupSize <= 0) {
    throw new Error("Enter a valid number of files per submission.");
  }
  if (items.length % groupSize !== 0) {
    throw new Error(`The upload contains ${items.length} files, which cannot be split into groups of ${groupSize}.`);
  }
  const groups = [];
  for (let index = 0; index < items.length; index += groupSize) {
    groups.push(items.slice(index, index + groupSize));
  }
  return groups;
}

async function handleBatchUpload(_event, { sessionId, filePaths, groupingMode, filesPerSubmission }) {
  return enqueue(async () => {
    const session = getSession(sessionId);
    if (session.isFinished) {
      throw new Error("This session is marked as ended. Turn off Session ended to grade more submissions.");
    }

    const groups = buildBatchGroups(filePaths, groupingMode, filesPerSubmission);
    const preparedGroups = [];

    for (const group of groups) {
      const validation = validateSubmissionAssetGroup(group);
      if (!validation.ok) {
        throw new Error(validation.message);
      }
      const assets = await copyInputFiles(
        group.map((item) => item.filePath),
        sessionAssetDir(session.id, "submissions", uuid())
      );
      preparedGroups.push(assets);
    }

    if (!session.questions.length) {
      for (const assets of preparedGroups) {
        session.submissions.unshift(
          createPendingSubmissionPlaceholder(
            session,
            assets,
            "Queued Submission",
            "Saved scan. Waiting for rubric approval before submission.",
            "queued",
            null
          )
        );
      }
      await persistAndBroadcast();
      return { queued: preparedGroups.length };
    }

    if (!trimText(apiKey)) {
      throw new Error("Add your OpenAI API key in Settings before scanning or grading.");
    }

    const placeholders = preparedGroups.map((assets, index) =>
      createPendingSubmissionPlaceholder(
        session,
        assets,
        "Pending Submission",
        "Preparing batch submission",
        "grading",
        `submission-${session.id}-${Date.now()}-${index}-${uuid()}`
      )
    );
    session.submissions.unshift(...placeholders);

    try {
      const creation = await openAI.createSubmissionGradingBatch({
        apiKey,
        modelID: session.gradingModelID,
        rubric: questionSnapshots(session),
        overallRules: session.overallGradingRules,
        submissions: placeholders.map((submission) => ({
          customID: submission.remoteBatchRequestID,
          attachments: materializeAttachments(submission.assets),
        })),
        integerPointsOnly: session.integerPointsOnly,
        relaxedGradingMode: session.relaxedGradingMode,
        reasoningEffort: session.gradingReasoningEffort,
        verbosity: session.gradingVerbosity,
      });

      for (const submission of placeholders) {
        submission.remoteBatchID = creation.batchID;
        submission.processingDetail = detailTextForBatchStatus(creation.status, null);
      }
      await persistAndBroadcast();
      await refreshPendingWork({ sessionId: session.id, notify: false });
      await persistAndBroadcast();
      return { submitted: placeholders.length };
    } catch (error) {
      session.submissions = session.submissions.filter((submission) => !placeholders.includes(submission));
      throw error;
    }
  });
}

async function handleGradeSingle(_event, { sessionId, filePaths }) {
  return enqueue(async () => {
    const session = getSession(sessionId);
    if (!trimText(apiKey)) {
      throw new Error("Add your OpenAI API key in Settings before scanning or grading.");
    }
    if (!session.questions.length) {
      throw new Error("Approve the rubric before grading a single submission.");
    }
    if (session.isFinished) {
      throw new Error("This session is marked as ended. Turn off Session ended to grade more submissions.");
    }

    const sourceAssets = filePaths.map((filePath) => ({
      id: uuid(),
      originalName: path.basename(filePath),
      ...detectAssetMetadata(filePath),
      absolutePath: filePath,
      previewURL: pathToFileURL(filePath).toString(),
    }));
    const validation = validateSubmissionAssetGroup(sourceAssets);
    if (!validation.ok) {
      throw new Error(validation.message);
    }

    const processed = await runLiveSubmissionProcessor(session, sourceAssets);
    for (const usage of processed.usageSummaries) {
      recordUsage(session, usage);
    }
    await persistAndBroadcast();
    return {
      draft: {
        ...processed.draft,
        sourceFiles: sourceAssets.map((asset) => ({
          absolutePath: asset.absolutePath,
          kind: asset.kind,
          mimeType: asset.mimeType,
          originalName: asset.originalName,
          previewURL: asset.previewURL,
        })),
      },
    };
  });
}

async function handleRegradeSubmission(_event, { sessionId, submissionId }) {
  return enqueue(async () => {
    const session = getSession(sessionId);
    const submission = getSubmission(session, submissionId);
    if (!trimText(apiKey)) {
      throw new Error("Add your OpenAI API key in Settings before regrading.");
    }
    const attachments = materializeAttachments(submission.assets).map((asset) => ({
      ...asset,
      previewURL: pathToFileURL(asset.absolutePath).toString(),
    }));
    const processed = await runLiveSubmissionProcessor(session, attachments);
    for (const usage of processed.usageSummaries) {
      recordUsage(session, usage);
    }
    await persistAndBroadcast();
    return {
      draft: {
        ...processed.draft,
        existingSubmissionId: submissionId,
      },
    };
  });
}

async function handleSaveReviewedSubmission(_event, { sessionId, draft }) {
  return enqueue(async () => {
    const session = getSession(sessionId);
    const normalized = normalizeDraft(draft, session.integerPointsOnly);

    if (draft.existingSubmissionId) {
      const submission = getSubmission(session, draft.existingSubmissionId);
      updateStoredSubmission(session, submission, normalized);
    } else {
      const copiedAssets = await copyInputFiles(
        (draft.sourceFiles || []).map((file) => file.absolutePath),
        sessionAssetDir(session.id, "submissions", uuid())
      );
      const submission = createStoredSubmission(session, normalized, copiedAssets);
      session.submissions.unshift(submission);
    }
    await persistAndBroadcast();
    return { ok: true };
  });
}

async function handleDeleteSubmission(_event, { sessionId, submissionId }) {
  return enqueue(async () => {
    const session = getSession(sessionId);
    session.submissions = session.submissions.filter((submission) => submission.id !== submissionId);
    await persistAndBroadcast();
    return { ok: true };
  });
}

async function handleRegradeAll(_event, sessionId) {
  return enqueue(async () => {
    const session = getSession(sessionId);
    if (!trimText(apiKey)) {
      throw new Error("Add your OpenAI API key in Settings before regrading.");
    }
    if ((session.submissions || []).some((submission) => submission.processingState === "pending" && submission.batchStage !== "queued")) {
      throw new Error("Wait for the current pending grading jobs to finish before starting a bulk regrade.");
    }
    const eligible = (session.submissions || []).filter((submission) => submission.processingState !== "pending");
    if (!eligible.length) {
      throw new Error("There are no saved submissions available to regrade.");
    }

    for (const submission of eligible) {
      submission.processingState = "pending";
      submission.batchStage = "grading";
      submission.batchAttemptNumber = 0;
      submission.processingDetail = "Preparing batch submission";
      submission.remoteBatchRequestID = `regradeall-${submission.id}-${uuid()}`;
      submission.remoteBatchID = null;
      submission.teacherReviewed = false;
      submission.validationNeedsReview = false;
      submission.overallNotes = "Regrading requested.";
      submission.latestSubmissionPayload = null;
      submission.latestValidationPayload = null;
      submission.grades = [];
      submission.totalScore = 0;
      submission.maxScore = (session.questions || []).reduce((sum, question) => sum + Number(question.maxPoints || 0), 0);
    }

    const creation = await openAI.createSubmissionGradingBatch({
      apiKey,
      modelID: session.gradingModelID,
      rubric: questionSnapshots(session),
      overallRules: session.overallGradingRules,
      submissions: eligible.map((submission) => ({
        customID: submission.remoteBatchRequestID,
        attachments: materializeAttachments(submission.assets),
      })),
      integerPointsOnly: session.integerPointsOnly,
      relaxedGradingMode: session.relaxedGradingMode,
      reasoningEffort: session.gradingReasoningEffort,
      verbosity: session.gradingVerbosity,
    });

    for (const submission of eligible) {
      submission.remoteBatchID = creation.batchID;
      submission.processingDetail = detailTextForBatchStatus(creation.status, null);
    }
    await persistAndBroadcast();
    await refreshPendingWork({ sessionId: session.id, notify: false });
    await persistAndBroadcast();
    return { submitted: eligible.length };
  });
}

async function handleSubmitQueued(_event, sessionId) {
  return enqueue(async () => {
    const session = getSession(sessionId);
    if (!trimText(apiKey)) {
      throw new Error("Add your OpenAI API key in Settings before submitting queued scans.");
    }
    if (!session.questions.length) {
      throw new Error("Approve the rubric before submitting queued scans.");
    }
    const queued = (session.submissions || []).filter((submission) => submission.processingState === "pending" && submission.batchStage === "queued");
    if (!queued.length) {
      throw new Error("There are no queued scans ready to submit.");
    }

    for (const submission of queued) {
      submission.batchStage = "grading";
      submission.batchAttemptNumber = 0;
      submission.remoteBatchRequestID = `queued-${submission.id}-${uuid()}`;
      submission.processingDetail = "Preparing batch submission";
      submission.overallNotes = "Queued scans submitted for grading.";
    }

    const creation = await openAI.createSubmissionGradingBatch({
      apiKey,
      modelID: session.gradingModelID,
      rubric: questionSnapshots(session),
      overallRules: session.overallGradingRules,
      submissions: queued.map((submission) => ({
        customID: submission.remoteBatchRequestID,
        attachments: materializeAttachments(submission.assets),
      })),
      integerPointsOnly: session.integerPointsOnly,
      relaxedGradingMode: session.relaxedGradingMode,
      reasoningEffort: session.gradingReasoningEffort,
      verbosity: session.gradingVerbosity,
    });

    for (const submission of queued) {
      submission.remoteBatchID = creation.batchID;
      submission.processingDetail = detailTextForBatchStatus(creation.status, null);
    }
    await persistAndBroadcast();
    await refreshPendingWork({ sessionId: session.id, notify: false });
    await persistAndBroadcast();
    return { submitted: queued.length };
  });
}

async function handleRefresh(_event, sessionId) {
  return enqueue(async () => {
    await refreshPendingWork({ sessionId, notify: false });
    await persistAndBroadcast();
    return { ok: true };
  });
}

async function handleExportCSV(_event, sessionId) {
  return enqueue(async () => {
    const session = getSession(sessionId);
    const defaultPath = `${trimText(session.title) || "session"}.csv`;
    const { canceled, filePath } = await dialog.showSaveDialog(mainWindow, {
      title: "Export Session CSV",
      defaultPath,
      filters: [{ name: "CSV", extensions: ["csv"] }],
    });
    if (canceled || !filePath) {
      return { canceled: true };
    }
    const tempPath = await exporters.writeCSVTempFile(session);
    await fs.copyFile(tempPath, filePath);
    return { canceled: false, filePath };
  });
}

async function handleExportPackage(_event, sessionId) {
  return enqueue(async () => {
    const session = getSession(sessionId);
    const defaultPath = `${trimText(session.title) || "session"}.zip`;
    const { canceled, filePath } = await dialog.showSaveDialog(mainWindow, {
      title: "Export Full Session Package",
      defaultPath,
      filters: [{ name: "ZIP", extensions: ["zip"] }],
    });
    if (canceled || !filePath) {
      return { canceled: true };
    }
    const zipPath = await exporters.writeSessionPackageZip(session, storagePaths().assetsRoot);
    await fs.copyFile(zipPath, filePath);
    return { canceled: false, filePath };
  });
}

function currentCanvasModule(session) {
  return canvasConnect.ensureCanvasModule(session);
}

function normalizeCanvasConfigInput(existing, input) {
  const next = {
    ...existing,
    canvasBaseUrl: trimText(input.canvasBaseUrl || ""),
    courseId: trimText(input.courseId || ""),
    assignmentId: trimText(input.assignmentId || ""),
    assignmentColumn: trimText(input.assignmentColumn || ""),
    gradebookTemplatePath: trimText(input.gradebookTemplatePath || existing.gradebookTemplatePath || ""),
    matchAutoAcceptScore: Math.max(Number(input.matchAutoAcceptScore || existing.matchAutoAcceptScore || 95), 0),
    matchReviewFloor: Math.max(Number(input.matchReviewFloor || existing.matchReviewFloor || 90), 0),
    matchMargin: Math.max(Number(input.matchMargin || existing.matchMargin || 5), 0),
    enforceManualPostPolicy: Boolean(input.enforceManualPostPolicy),
    uploadAttachPdfAsComment: Boolean(input.uploadAttachPdfAsComment),
    uploadPostGrade: Boolean(input.uploadPostGrade),
    uploadCommentEnabled: Boolean(input.uploadCommentEnabled),
    uploadCommentIncludeTotalScore: Boolean(input.uploadCommentIncludeTotalScore),
    uploadCommentIncludeQuestionScores: Boolean(input.uploadCommentIncludeQuestionScores),
    uploadCommentIncludeIndividualNotes: Boolean(input.uploadCommentIncludeIndividualNotes),
    uploadCommentIncludeOverallNotes: Boolean(input.uploadCommentIncludeOverallNotes),
    requestTimeoutSeconds: Math.max(Number(input.requestTimeoutSeconds || existing.requestTimeoutSeconds || 60), 10),
  };
  return next;
}

function canvasClientFromModule(canvasModule) {
  if (!trimText(canvasToken)) {
    throw new Error("Save your Canvas API token before using the Canvas module.");
  }
  if (!trimText(canvasModule.canvasBaseUrl)) {
    throw new Error("Canvas base URL is required.");
  }
  return new canvasConnect.CanvasAPI(
    canvasModule.canvasBaseUrl,
    canvasToken,
    canvasModule.requestTimeoutSeconds
  );
}

async function datasetForCanvas(session) {
  return canvasConnect.buildSessionDataset(session, storagePaths().assetsRoot, storagePaths().canvasWorkRoot);
}

function rosterById(canvasModule) {
  return new Map((canvasModule.roster || []).map((student) => [Number(student.userId), student]));
}

function resolvedLockedMatches(canvasModule) {
  return (canvasModule.matches || []).filter((record) => record.finalStatus === "matched" || record.finalStatus === "skipped");
}

async function handleSaveCanvasToken(_event, nextValue) {
  return enqueue(async () => {
    await persistCanvasToken(nextValue);
    await persistAndBroadcast();
    return { ok: true };
  });
}

async function handleUpdateCanvasConfig(_event, { sessionId, config }) {
  return enqueue(async () => {
    const session = getSession(sessionId);
    const canvasModule = currentCanvasModule(session);
    session.canvasModule = normalizeCanvasConfigInput(canvasModule, config || {});
    if (session.canvasModule.gradebookTemplatePath) {
      try {
        const info = await canvasConnect.gradebookTemplateInfo(session.canvasModule.gradebookTemplatePath);
        session.canvasModule.gradebookTemplateColumns = info.headers;
      } catch {
        session.canvasModule.gradebookTemplateColumns = [];
      }
    } else {
      session.canvasModule.gradebookTemplateColumns = [];
    }
    await persistAndBroadcast();
    return { ok: true };
  });
}

async function handleCanvasLoadRosterFromAPI(_event, sessionId) {
  return enqueue(async () => {
    const session = getSession(sessionId);
    const canvasModule = currentCanvasModule(session);
    if (!trimText(canvasModule.courseId)) {
      throw new Error("Canvas course id is required before loading the roster.");
    }

    const client = canvasClientFromModule(canvasModule);
    const apiRoster = await client.listCourseStudents(Number(canvasModule.courseId));
    canvasModule.apiRoster = apiRoster;
    canvasModule.roster = canvasConnect.mergeRosters(apiRoster, canvasModule.gradebookRoster || []);
    canvasModule.rosterLoadedAt = nowISO();
    canvasModule.rosterSource.apiLoaded = true;
    await persistAndBroadcast();
    return { count: canvasModule.roster.length };
  });
}

async function handleCanvasLoadGradebookTemplate(_event, { sessionId, csvPath }) {
  return enqueue(async () => {
    const session = getSession(sessionId);
    const canvasModule = currentCanvasModule(session);
    const info = await canvasConnect.gradebookTemplateInfo(csvPath);
    const gradebookRoster = await canvasConnect.loadGradebookRoster(csvPath);
    canvasModule.gradebookTemplatePath = csvPath;
    canvasModule.gradebookTemplateColumns = info.headers;
    canvasModule.gradebookRoster = gradebookRoster;
    canvasModule.rosterSource.gradebookPath = csvPath;
    canvasModule.roster = canvasConnect.mergeRosters(canvasModule.apiRoster || [], gradebookRoster);
    canvasModule.rosterLoadedAt = nowISO();
    await persistAndBroadcast();
    return { count: canvasModule.roster.length, headers: info.headers };
  });
}

async function handleCanvasRunMatching(_event, sessionId) {
  return enqueue(async () => {
    const session = getSession(sessionId);
    const canvasModule = currentCanvasModule(session);
    const dataset = await datasetForCanvas(session);
    canvasModule.matches = canvasConnect.buildMatchManifest(dataset, canvasModule.roster || [], canvasModule);
    await persistAndBroadcast();
    return {
      summary: canvasConnect.summarizeMatchRecords(canvasModule.matches),
      lockedSummary: canvasConnect.summarizeLockedRecords(canvasModule.matches),
    };
  });
}

async function handleCanvasUpdateMatch(_event, { sessionId, localSubmissionId, selection }) {
  return enqueue(async () => {
    const session = getSession(sessionId);
    const canvasModule = currentCanvasModule(session);
    const record = (canvasModule.matches || []).find((item) => item.localSubmissionId === localSubmissionId);
    if (!record) {
      throw new Error("Match record not found.");
    }
    canvasConnect.applyMatchSelection(record, rosterById(canvasModule), selection);
    await persistAndBroadcast();
    return {
      summary: canvasConnect.summarizeLockedRecords(canvasModule.matches),
    };
  });
}

async function handleCanvasExportGradebook(_event, sessionId) {
  return enqueue(async () => {
    const session = getSession(sessionId);
    const canvasModule = currentCanvasModule(session);
    const locked = resolvedLockedMatches(canvasModule);
    if (!canvasModule.gradebookTemplatePath) {
      throw new Error("Choose a Gradebook CSV template first.");
    }
    if (!trimText(canvasModule.assignmentColumn)) {
      throw new Error("Choose the assignment column to populate.");
    }
    if (!locked.some((record) => record.finalStatus === "matched")) {
      throw new Error("At least one matched submission is required before exporting a Gradebook CSV.");
    }

    const { canceled, filePath } = await dialog.showSaveDialog(mainWindow, {
      title: "Save Canvas Gradebook Import CSV",
      defaultPath: `${trimText(session.title) || "grades"}-gradebook-import.csv`,
      filters: [{ name: "CSV", extensions: ["csv"] }],
    });
    if (canceled || !filePath) {
      return { canceled: true };
    }
    const stats = await canvasConnect.buildGradeImportCSV(
      canvasModule.gradebookTemplatePath,
      filePath,
      canvasModule.assignmentColumn,
      locked
    );
    canvasModule.lastGradeCsvPath = filePath;
    await persistAndBroadcast();
    return { canceled: false, filePath, stats };
  });
}

async function handleCanvasPostGrades(_event, sessionId) {
  return enqueue(async () => {
    const session = getSession(sessionId);
    const canvasModule = currentCanvasModule(session);
    const locked = resolvedLockedMatches(canvasModule);
    const matched = locked.filter((record) => record.finalStatus === "matched");
    if (!matched.length) {
      throw new Error("No matched submissions are ready to post.");
    }

    const client = canvasClientFromModule(canvasModule);
    const result = await canvasConnect.postGrades(client, canvasModule, locked);
    canvasModule.lastGradeResults = result;
    await persistAndBroadcast();
    return result;
  });
}

async function handleCanvasUploadSubmissions(_event, sessionId) {
  return enqueue(async () => {
    const session = getSession(sessionId);
    const canvasModule = currentCanvasModule(session);
    const locked = resolvedLockedMatches(canvasModule);
    const dataset = await datasetForCanvas(session);
    const submissionsById = new Map(dataset.submissions.map((submission) => [submission.submissionId, submission]));
    const client = canvasClientFromModule(canvasModule);
    const results = await canvasConnect.uploadSubmissions(client, canvasModule, locked, submissionsById);
    canvasModule.lastUploadResults = results;
    await persistAndBroadcast();
    return {
      results,
      summary: canvasConnect.summarizeUploadResults(results),
    };
  });
}

function registerIPC() {
  ipcMain.handle("app:snapshot", () => buildSnapshot());
  ipcMain.handle("app:select-files", async (_event, options = {}) => {
    const ownerWindow = BrowserWindow.getFocusedWindow() || mainWindow || undefined;
    const dialogOptions = {
      title: options.title || "Choose Files",
      properties: options.properties || ["openFile", "multiSelections"],
      filters: options.filters || [
        { name: "Supported Files", extensions: ["pdf", "jpg", "jpeg", "png", "webp"] },
      ],
    };
    const result = ownerWindow
      ? await dialog.showOpenDialog(ownerWindow, dialogOptions)
      : await dialog.showOpenDialog(dialogOptions);
    return result.canceled ? [] : result.filePaths;
  });
  ipcMain.handle("app:reveal-file", async (_event, filePath) => {
    shell.showItemInFolder(filePath);
    return { ok: true };
  });
  ipcMain.handle("session:create", handleCreateSession);
  ipcMain.handle("session:update", handleUpdateSession);
  ipcMain.handle("session:delete", handleDeleteSession);
  ipcMain.handle("settings:save-api-key", handleSaveAPIKey);
  ipcMain.handle("settings:save-canvas-token", handleSaveCanvasToken);
  ipcMain.handle("settings:test-api-key", handleTestAPIKey);
  ipcMain.handle("settings:fetch-org-cost", handleFetchOrganizationCost);
  ipcMain.handle("session:upload-master", handleUploadMaster);
  ipcMain.handle("session:save-rubric", handleSaveRubric);
  ipcMain.handle("session:batch-upload", handleBatchUpload);
  ipcMain.handle("session:grade-single", handleGradeSingle);
  ipcMain.handle("submission:regrade", handleRegradeSubmission);
  ipcMain.handle("submission:save-review", handleSaveReviewedSubmission);
  ipcMain.handle("submission:delete", handleDeleteSubmission);
  ipcMain.handle("session:regrade-all", handleRegradeAll);
  ipcMain.handle("session:submit-queued", handleSubmitQueued);
  ipcMain.handle("session:refresh", handleRefresh);
  ipcMain.handle("session:export-csv", handleExportCSV);
  ipcMain.handle("session:export-package", handleExportPackage);
  ipcMain.handle("canvas:update-config", handleUpdateCanvasConfig);
  ipcMain.handle("canvas:load-roster-api", handleCanvasLoadRosterFromAPI);
  ipcMain.handle("canvas:load-gradebook-template", handleCanvasLoadGradebookTemplate);
  ipcMain.handle("canvas:run-matching", handleCanvasRunMatching);
  ipcMain.handle("canvas:update-match", handleCanvasUpdateMatch);
  ipcMain.handle("canvas:export-gradebook", handleCanvasExportGradebook);
  ipcMain.handle("canvas:post-grades", handleCanvasPostGrades);
  ipcMain.handle("canvas:upload-submissions", handleCanvasUploadSubmissions);
}

async function boot() {
  await loadPersistedState();
  registerIPC();
  makeWindow();
  pollTimer = setInterval(() => {
    enqueue(async () => {
      try {
        await refreshPendingWork({ notify: true });
        await persistAndBroadcast();
      } catch {}
    });
  }, 15000);
}

app.whenReady().then(boot);

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") {
    app.quit();
  }
});

app.on("activate", () => {
  if (BrowserWindow.getAllWindows().length === 0) {
    makeWindow();
  }
});

app.on("before-quit", () => {
  if (pollTimer) {
    clearInterval(pollTimer);
  }
});
