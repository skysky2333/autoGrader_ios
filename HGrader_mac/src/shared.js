"use strict";

const crypto = require("node:crypto");

const MODEL_SUGGESTIONS = [
  "gpt-5.4",
  "gpt-5.4-mini",
  "gpt-5.4-nano",
  "gpt-5-mini",
  "gpt-4.1",
  "gpt-4.1-mini",
];

const DEFAULT_MODELS = {
  answer: "gpt-5.4",
  grading: "gpt-5.4",
  validation: "gpt-5.4",
};

const REASONING_OPTIONS = [
  { label: "API Default", value: null },
  { label: "None", value: "none" },
  { label: "Minimal", value: "minimal" },
  { label: "Low", value: "low" },
  { label: "Medium", value: "medium" },
  { label: "High", value: "high" },
  { label: "XHigh", value: "xhigh" },
];

const VERBOSITY_OPTIONS = [
  { label: "API Default", value: null },
  { label: "Low", value: "low" },
  { label: "Medium", value: "medium" },
  { label: "High", value: "high" },
];

const SERVICE_TIER_OPTIONS = [
  { label: "Auto (API Default)", value: null },
  { label: "Default", value: "default" },
  { label: "Flex", value: "flex" },
  { label: "Priority", value: "priority" },
];

const PRICE_CATALOG = [
  ["gpt-5.4-mini", { inputPerMTokensUSD: 0.75, cachedInputPerMTokensUSD: 0.075, outputPerMTokensUSD: 4.5 }],
  ["gpt-5.4-nano", { inputPerMTokensUSD: 0.2, cachedInputPerMTokensUSD: 0.02, outputPerMTokensUSD: 1.25 }],
  ["gpt-5.4", { inputPerMTokensUSD: 2.5, cachedInputPerMTokensUSD: 0.25, outputPerMTokensUSD: 15 }],
  ["gpt-5.2-mini", { inputPerMTokensUSD: 0.4, cachedInputPerMTokensUSD: 0.04, outputPerMTokensUSD: 3.2 }],
  ["gpt-5.2-nano", { inputPerMTokensUSD: 0.1, cachedInputPerMTokensUSD: 0.01, outputPerMTokensUSD: 0.8 }],
  ["gpt-5.2", { inputPerMTokensUSD: 1.75, cachedInputPerMTokensUSD: 0.175, outputPerMTokensUSD: 14 }],
  ["gpt-5-mini", { inputPerMTokensUSD: 0.25, cachedInputPerMTokensUSD: 0.025, outputPerMTokensUSD: 2 }],
  ["gpt-5-nano", { inputPerMTokensUSD: 0.05, cachedInputPerMTokensUSD: 0.005, outputPerMTokensUSD: 0.4 }],
  ["gpt-5", { inputPerMTokensUSD: 1.25, cachedInputPerMTokensUSD: 0.125, outputPerMTokensUSD: 10 }],
  ["gpt-4.1-mini", { inputPerMTokensUSD: 0.4, cachedInputPerMTokensUSD: 0.1, outputPerMTokensUSD: 1.6 }],
  ["gpt-4.1", { inputPerMTokensUSD: 2, cachedInputPerMTokensUSD: 0.5, outputPerMTokensUSD: 8 }],
  ["gpt-4o-mini", { inputPerMTokensUSD: 0.15, cachedInputPerMTokensUSD: 0.075, outputPerMTokensUSD: 0.6 }],
  ["gpt-4o", { inputPerMTokensUSD: 2.5, cachedInputPerMTokensUSD: 1.25, outputPerMTokensUSD: 10 }],
];

function nowISO() {
  return new Date().toISOString();
}

function uuid() {
  return crypto.randomUUID();
}

function trimText(value) {
  return typeof value === "string" ? value.trim() : "";
}

function safeName(value, fallback = "session") {
  const cleaned = String(value || "")
    .replace(/[^0-9A-Za-z\s-]+/g, "")
    .replace(/\s+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");
  return cleaned || fallback;
}

function deepClone(value) {
  return value == null ? value : JSON.parse(JSON.stringify(value));
}

function scoreString(value) {
  const numeric = Number(value || 0);
  if (Number.isInteger(numeric)) {
    return String(numeric);
  }
  return numeric.toFixed(2).replace(/\.?0+$/, "");
}

function escapeCSV(value) {
  const escaped = String(value ?? "").replace(/"/g, "\"\"");
  return `"${escaped}"`;
}

function parsePointValue(text, integerOnly) {
  const trimmed = trimText(text);
  if (!trimmed) {
    return null;
  }
  if (integerOnly) {
    const parsed = Number.parseInt(trimmed, 10);
    return Number.isInteger(parsed) && parsed > 0 ? parsed : null;
  }
  const parsed = Number(trimmed);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : null;
}

function normalizePointValue(value, integerOnly, maxPoints = null) {
  const upperBound = maxPoints == null ? Number(value || 0) : Number(maxPoints || 0);
  const clamped = Math.min(Math.max(Number(value || 0), 0), upperBound);
  return integerOnly ? Math.round(clamped) : clamped;
}

function pointStep(integerOnly) {
  return integerOnly ? 1 : 0.5;
}

function fingerprintAPIKey(apiKey) {
  const trimmed = trimText(apiKey);
  if (!trimmed) {
    return null;
  }
  return crypto.createHash("sha256").update(trimmed).digest("hex").slice(0, 16);
}

function labelForOption(value, options, disabledLabel = "Disabled") {
  if (value === "__disabled__") {
    return disabledLabel;
  }
  const match = options.find((option) => option.value === value);
  return match ? match.label : "API Default";
}

function pricingForModel(modelID) {
  const normalized = String(modelID || "").toLowerCase();
  const match = PRICE_CATALOG.find(([prefix]) => normalized.startsWith(prefix));
  return match ? match[1] : null;
}

function estimatedCostUSD(modelID, inputTokens, outputTokens, cachedInputTokens) {
  const pricing = pricingForModel(modelID);
  if (!pricing) {
    return 0;
  }
  const uncachedInput = Math.max(Number(inputTokens || 0) - Number(cachedInputTokens || 0), 0);
  const inputCost = (uncachedInput / 1_000_000) * pricing.inputPerMTokensUSD;
  const cachedCost = (Number(cachedInputTokens || 0) / 1_000_000) * pricing.cachedInputPerMTokensUSD;
  const outputCost = (Number(outputTokens || 0) / 1_000_000) * pricing.outputPerMTokensUSD;
  return inputCost + cachedCost + outputCost;
}

function questionGradeLookup(questionID, displayLabel, grades) {
  const list = Array.isArray(grades) ? grades : [];
  const normalizedQuestionID = normalizeLookupKey(questionID);
  const normalizedDisplayLabel = normalizeLookupKey(displayLabel);

  return (
    list.find((item) => item.questionID === questionID) ||
    list.find((item) => normalizeLookupKey(item.questionID) === normalizedQuestionID) ||
    list.find((item) => normalizeLookupKey(item.displayLabel) === normalizedDisplayLabel) ||
    null
  );
}

function normalizeLookupKey(value) {
  return String(value || "")
    .trim()
    .toLocaleLowerCase();
}

function totalScoreFromGrades(grades) {
  return (grades || []).reduce((sum, grade) => sum + Number(grade.awardedPoints || 0), 0);
}

function maxScoreFromGrades(grades) {
  return (grades || []).reduce((sum, grade) => sum + Number(grade.maxPoints || 0), 0);
}

function requiresAttention(draft) {
  return (
    !trimText(draft.studentName) ||
    Boolean(draft.needsAttention) ||
    Boolean(draft.nameNeedsReview) ||
    Boolean(draft.validationNeedsReview) ||
    (draft.grades || []).some((grade) => Boolean(grade.needsReview))
  );
}

function isPdfAsset(asset) {
  return asset && asset.kind === "pdf";
}

function isImageAsset(asset) {
  return asset && asset.kind === "image";
}

function validateSubmissionAssetGroup(assets) {
  const list = Array.isArray(assets) ? assets : [];
  if (!list.length) {
    return { ok: false, message: "No files were provided for this submission." };
  }
  const pdfCount = list.filter(isPdfAsset).length;
  const imageCount = list.filter(isImageAsset).length;

  if (pdfCount > 1) {
    return {
      ok: false,
      message: "Each submission can contain at most one PDF. Use one PDF per student or separate image files.",
    };
  }
  if (pdfCount === 1 && imageCount > 0) {
    return {
      ok: false,
      message: "A submission cannot mix a PDF with separate image files. Use either one PDF or image files only.",
    };
  }
  return { ok: true };
}

function validateMasterAssetGroup(assets) {
  const list = Array.isArray(assets) ? assets : [];
  if (!list.length) {
    return { ok: false, message: "No files were provided for the blank assignment." };
  }
  const pdfCount = list.filter(isPdfAsset).length;
  const imageCount = list.filter(isImageAsset).length;
  if (pdfCount > 0 && imageCount > 0) {
    return {
      ok: false,
      message: "Use either PDFs or image files for the blank assignment, but do not mix them in one upload.",
    };
  }
  return { ok: true };
}

module.exports = {
  DEFAULT_MODELS,
  MODEL_SUGGESTIONS,
  REASONING_OPTIONS,
  SERVICE_TIER_OPTIONS,
  VERBOSITY_OPTIONS,
  deepClone,
  escapeCSV,
  estimatedCostUSD,
  fingerprintAPIKey,
  labelForOption,
  maxScoreFromGrades,
  normalizePointValue,
  nowISO,
  parsePointValue,
  pointStep,
  questionGradeLookup,
  requiresAttention,
  safeName,
  scoreString,
  totalScoreFromGrades,
  trimText,
  uuid,
  validateMasterAssetGroup,
  validateSubmissionAssetGroup,
};
