"use strict";

const fs = require("node:fs/promises");
const path = require("node:path");
const os = require("node:os");
const { Blob } = require("node:buffer");
const { nativeImage } = require("electron");

const { escapeCSV, safeName, scoreString } = require("./shared");

function defaultCanvasModule() {
  return {
    canvasBaseUrl: "",
    courseId: "",
    assignmentId: "",
    assignmentColumn: "",
    gradebookTemplatePath: "",
    gradebookTemplateColumns: [],
    matchAutoAcceptScore: 95,
    matchReviewFloor: 90,
    matchMargin: 5,
    enforceManualPostPolicy: true,
    uploadAttachPdfAsComment: true,
    uploadPostGrade: true,
    uploadCommentEnabled: true,
    uploadCommentIncludeTotalScore: true,
    uploadCommentIncludeQuestionScores: true,
    uploadCommentIncludeIndividualNotes: false,
    uploadCommentIncludeOverallNotes: true,
    requestTimeoutSeconds: 60,
    apiRoster: [],
    gradebookRoster: [],
    roster: [],
    rosterLoadedAt: null,
    rosterSource: {
      apiLoaded: false,
      gradebookPath: "",
    },
    matches: [],
    lastGradeCsvPath: "",
    lastUploadResults: [],
    lastGradeResults: null,
  };
}

function ensureCanvasModule(session) {
  const next = {
    ...defaultCanvasModule(),
    ...(session.canvasModule || {}),
  };
  next.roster = Array.isArray(next.roster) ? next.roster : [];
  next.apiRoster = Array.isArray(next.apiRoster) ? next.apiRoster : [];
  next.gradebookRoster = Array.isArray(next.gradebookRoster) ? next.gradebookRoster : [];
  next.matches = Array.isArray(next.matches) ? next.matches : [];
  next.gradebookTemplateColumns = Array.isArray(next.gradebookTemplateColumns) ? next.gradebookTemplateColumns : [];
  next.rosterSource = {
    apiLoaded: Boolean(next.rosterSource?.apiLoaded),
    gradebookPath: next.rosterSource?.gradebookPath || "",
  };
  session.canvasModule = next;
  return next;
}

class CanvasAPIError extends Error {}

class CanvasAPI {
  constructor(baseUrl, token, timeoutSeconds = 60) {
    this.baseUrl = String(baseUrl || "").replace(/\/$/, "");
    this.token = token;
    this.timeoutSeconds = timeoutSeconds;
  }

  buildURL(pathname, query = null) {
    const url = new URL(this.baseUrl + pathname);
    if (query) {
      for (const [key, value] of Object.entries(query)) {
        if (Array.isArray(value)) {
          for (const item of value) {
            url.searchParams.append(key, String(item));
          }
        } else if (value !== undefined && value !== null && value !== "") {
          url.searchParams.append(key, String(value));
        }
      }
    }
    return url.toString();
  }

  async requestJSON(method, url, { form = null, absolute = false } = {}) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), this.timeoutSeconds * 1000);

    const headers = {
      Authorization: `Bearer ${this.token}`,
      Accept: "application/json",
    };
    let body = undefined;

    if (form) {
      const search = new URLSearchParams();
      for (const [key, value] of form) {
        search.append(key, value);
      }
      headers["Content-Type"] = "application/x-www-form-urlencoded";
      body = search.toString();
    }

    try {
      const response = await fetch(absolute ? url : url, {
        method,
        headers,
        body,
        signal: controller.signal,
      });
      const text = await response.text();
      if (!response.ok) {
        throw new CanvasAPIError(`${method} ${url} failed with ${response.status}: ${text}`);
      }
      return {
        payload: text ? JSON.parse(text) : {},
        headers: response.headers,
        finalURL: response.url,
      };
    } finally {
      clearTimeout(timeout);
    }
  }

  async listCourseStudents(courseId) {
    let nextURL = this.buildURL(`/api/v1/courses/${courseId}/users`, {
      "enrollment_type[]": "student",
      per_page: "100",
    });
    const students = [];

    while (nextURL) {
      const { payload, headers } = await this.requestJSON("GET", nextURL, { absolute: true });
      for (const item of payload) {
        students.push({
          userId: Number(item.id),
          name: item.name || item.sortable_name || String(item.id),
          sortableName: item.sortable_name || "",
          shortName: item.short_name || "",
          sisUserId: item.sis_user_id || "",
          loginId: item.login_id || "",
          section: "",
        });
      }
      nextURL = nextLink(headers.get("link"));
    }
    return students;
  }

  async getAssignment(courseId, assignmentId) {
    const { payload } = await this.requestJSON("GET", this.buildURL(`/api/v1/courses/${courseId}/assignments/${assignmentId}`));
    return payload;
  }

  async updateAssignment(courseId, assignmentId, fields) {
    const form = Object.entries(fields).map(([key, value]) => [key, String(value)]);
    const { payload } = await this.requestJSON("PUT", this.buildURL(`/api/v1/courses/${courseId}/assignments/${assignmentId}`), { form });
    return payload;
  }

  async uploadSubmissionCommentFile(courseId, assignmentId, userId, filePath) {
    const stats = await fs.stat(filePath);
    const fileName = path.basename(filePath);
    const init = await this.requestJSON(
      "POST",
      this.buildURL(`/api/v1/courses/${courseId}/assignments/${assignmentId}/submissions/${userId}/comments/files`),
      {
        form: [
          ["name", fileName],
          ["size", String(stats.size)],
          ["content_type", mimeTypeForPath(filePath)],
        ],
      }
    );
    return this.multipartUpload(init.payload.upload_url, init.payload.upload_params || {}, filePath);
  }

  async gradeOrCommentSubmission(courseId, assignmentId, userId, { postedGrade = null, commentText = null, commentFileIds = [] } = {}) {
    const form = [];
    if (commentText) {
      form.push(["comment[text_comment]", commentText]);
    }
    for (const fileId of commentFileIds || []) {
      form.push(["comment[file_ids][]", String(fileId)]);
    }
    if (postedGrade != null) {
      form.push(["submission[posted_grade]", postedGrade]);
      form.push(["prefer_points_over_scheme", "true"]);
    }
    const { payload } = await this.requestJSON(
      "PUT",
      this.buildURL(`/api/v1/courses/${courseId}/assignments/${assignmentId}/submissions/${userId}`),
      { form }
    );
    return payload;
  }

  async updateAssignmentGrades(courseId, assignmentId, gradeMap) {
    const form = [];
    for (const [studentId, grade] of Object.entries(gradeMap)) {
      form.push([`grade_data[${studentId}][posted_grade]`, String(grade)]);
    }
    const { payload } = await this.requestJSON(
      "POST",
      this.buildURL(`/api/v1/courses/${courseId}/assignments/${assignmentId}/submissions/update_grades`),
      { form }
    );
    return payload;
  }

  async getProgress(progressId) {
    const { payload } = await this.requestJSON("GET", this.buildURL(`/api/v1/progress/${progressId}`));
    return payload;
  }

  async waitForProgress(progressId, { pollIntervalSeconds = 1.5, timeoutSeconds = 300 } = {}) {
    const started = Date.now();
    while (true) {
      const payload = await this.getProgress(progressId);
      const state = payload.workflow_state;
      if (state === "completed" || state === "failed") {
        return payload;
      }
      if ((Date.now() - started) / 1000 > timeoutSeconds) {
        throw new CanvasAPIError(`Timed out waiting for Canvas progress job ${progressId}.`);
      }
      await sleep(pollIntervalSeconds * 1000);
    }
  }

  async multipartUpload(uploadURL, uploadParams, filePath) {
    const buffer = await fs.readFile(filePath);
    const form = new FormData();
    for (const [key, value] of Object.entries(uploadParams || {})) {
      form.append(key, String(value));
    }
    form.append("file", new Blob([buffer], { type: mimeTypeForPath(filePath) }), path.basename(filePath));

    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), this.timeoutSeconds * 1000);
    try {
      const response = await fetch(uploadURL, {
        method: "POST",
        body: form,
        redirect: "follow",
        headers: {
          Accept: "application/json",
        },
        signal: controller.signal,
      });
      const text = await response.text();
      if (!response.ok) {
        throw new CanvasAPIError(`Upload failed with ${response.status}: ${text}`);
      }
      return text ? JSON.parse(text) : {};
    } finally {
      clearTimeout(timeout);
    }
  }
}

function nextLink(linkHeader) {
  if (!linkHeader) {
    return null;
  }
  const links = String(linkHeader)
    .split(",")
    .map((item) => item.trim());
  for (const link of links) {
    const match = link.match(/<([^>]+)>;\s*rel="([^"]+)"/);
    if (match && match[2] === "next") {
      return match[1];
    }
  }
  return null;
}

function mimeTypeForPath(filePath) {
  const ext = path.extname(filePath).toLowerCase();
  if (ext === ".pdf") return "application/pdf";
  if (ext === ".png") return "image/png";
  if (ext === ".webp") return "image/webp";
  return "image/jpeg";
}

function normalizeName(value) {
  return String(value || "")
    .normalize("NFKC")
    .toLowerCase()
    .replace(/[^0-9a-z\s]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function asciiFold(value) {
  return String(value || "")
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .trim();
}

function sequenceRatio(left, right) {
  const a = Array.from(String(left || ""));
  const b = Array.from(String(right || ""));
  const dp = Array.from({ length: a.length + 1 }, () => Array(b.length + 1).fill(0));

  for (let i = 1; i <= a.length; i += 1) {
    for (let j = 1; j <= b.length; j += 1) {
      if (a[i - 1] === b[j - 1]) {
        dp[i][j] = dp[i - 1][j - 1] + 1;
      } else {
        dp[i][j] = Math.max(dp[i - 1][j], dp[i][j - 1]);
      }
    }
  }
  const lcs = dp[a.length][b.length];
  return a.length + b.length === 0 ? 1 : (2 * lcs) / (a.length + b.length);
}

function scoreNameMatch(left, right) {
  const leftNorm = normalizeName(left);
  const rightNorm = normalizeName(right);
  const leftAscii = asciiFold(leftNorm);
  const rightAscii = asciiFold(rightNorm);
  const leftTokenSort = leftNorm.split(" ").filter(Boolean).sort().join(" ");
  const rightTokenSort = rightNorm.split(" ").filter(Boolean).sort().join(" ");

  if (leftNorm && leftNorm === rightNorm) return { score: 100, reason: "exact_normalized" };
  if (leftAscii && leftAscii === rightAscii) return { score: 100, reason: "exact_ascii" };
  if (leftTokenSort && leftTokenSort === rightTokenSort) return { score: 98, reason: "exact_token_set" };

  const scores = [
    ["fuzzy_full", Math.round(sequenceRatio(leftNorm, rightNorm) * 100)],
    ["fuzzy_ascii", Math.round(sequenceRatio(leftAscii, rightAscii) * 100)],
    ["fuzzy_token_sort", Math.round(sequenceRatio(leftTokenSort, rightTokenSort) * 100)],
  ];
  scores.sort((a, b) => (b[1] - a[1]) || String(a[0]).localeCompare(String(b[0])));
  return { reason: scores[0][0], score: scores[0][1] };
}

function rankCandidates(localName, roster) {
  return roster
    .map((student) => {
      const match = scoreNameMatch(localName, student.name);
      return {
        userId: Number(student.userId),
        name: student.name,
        score: match.score,
        reason: match.reason,
        sisUserId: student.sisUserId || "",
        loginId: student.loginId || "",
        section: student.section || "",
      };
    })
    .sort((a, b) => (b.score - a.score) || a.name.localeCompare(b.name) || (a.userId - b.userId));
}

function classifyMatch(localName, topCandidate, runnerUpScore, requiresReview, config) {
  const margin = topCandidate.score - (runnerUpScore || 0);
  if (topCandidate.score > Number(config.matchAutoAcceptScore) && margin >= Number(config.matchMargin)) {
    return { status: "auto", reason: topCandidate.reason };
  }
  if (topCandidate.score > Number(config.matchReviewFloor) && !requiresReview && margin >= Number(config.matchMargin)) {
    return { status: "auto", reason: topCandidate.reason };
  }
  return { status: "needs_review", reason: requiresReview ? "name_needs_review" : topCandidate.reason };
}

function buildMatchManifest(dataset, roster, config) {
  if (!roster.length) {
    throw new Error("Roster is empty. Load a roster before running matching.");
  }

  const records = dataset.submissions.map((submission) => {
    const ranked = rankCandidates(submission.studentName, roster);
    const topCandidates = ranked.slice(0, 3);
    const topCandidate = topCandidates[0] || null;
    const runnerUpScore = topCandidates[1]?.score ?? null;
    let status = "unmatched";
    let reason = "no_candidate";
    let matchedUserId = null;
    let matchedStudentName = null;
    let matchScore = null;

    if (topCandidate) {
      matchedUserId = topCandidate.userId;
      matchedStudentName = topCandidate.name;
      matchScore = topCandidate.score;
      const classified = classifyMatch(
        submission.studentName,
        topCandidate,
        runnerUpScore,
        submission.nameNeedsReview,
        config
      );
      status = classified.status;
      reason = classified.reason;
    }

    return {
      localSubmissionId: submission.submissionId,
      localStudentName: submission.studentName,
      totalScore: submission.totalScore,
      maxScore: submission.maxScore,
      pdfPath: submission.pdfPath,
      firstScanPath: submission.scanPaths[0] || "",
      nameNeedsReview: Boolean(submission.nameNeedsReview),
      teacherReviewed: Boolean(submission.teacherReviewed),
      status,
      reason,
      matchedUserId,
      matchedStudentName,
      matchScore,
      runnerUpScore,
      candidates: topCandidates,
      reviewerDecision: status === "auto" ? "auto_accepted" : "",
      reviewerSelectedUserId: status === "auto" ? matchedUserId : null,
      reviewerNote: status === "auto" ? "auto accepted" : "",
      finalStatus: status === "auto" && matchedUserId != null ? "matched" : "",
      finalUserId: status === "auto" ? matchedUserId : null,
      finalStudentName: status === "auto" ? matchedStudentName : null,
      finalSisUserId: status === "auto" ? (topCandidate?.sisUserId || "") : "",
      finalLoginId: status === "auto" ? (topCandidate?.loginId || "") : "",
      finalSection: status === "auto" ? (topCandidate?.section || "") : "",
      sourceStatus: status,
      sourceReason: reason,
    };
  });

  flagDuplicateAutoMatches(records);
  return records;
}

function flagDuplicateAutoMatches(records) {
  const claims = new Map();
  for (const record of records) {
    if (record.status !== "auto" || record.matchedUserId == null) continue;
    if (!claims.has(record.matchedUserId)) claims.set(record.matchedUserId, []);
    claims.get(record.matchedUserId).push(record);
  }
  for (const duplicates of claims.values()) {
    if (duplicates.length < 2) continue;
    for (const record of duplicates) {
      record.status = "duplicate_candidate";
      record.reason = "duplicate_auto_match";
      record.reviewerDecision = "";
      record.reviewerSelectedUserId = null;
      record.reviewerNote = "";
      record.finalStatus = "";
      record.finalUserId = null;
      record.finalStudentName = null;
      record.finalSisUserId = "";
      record.finalLoginId = "";
      record.finalSection = "";
    }
  }
}

function applyMatchSelection(record, rosterById, selection) {
  const choice = selection || {};
  const decision = choice.decision || "";
  const selectedUserId = choice.userId != null && choice.userId !== "" ? Number(choice.userId) : null;
  record.reviewerDecision = decision;
  record.reviewerSelectedUserId = selectedUserId;
  record.reviewerNote = choice.note || record.reviewerNote || "";

  if (decision === "skip") {
    record.finalStatus = "skipped";
    record.finalUserId = null;
    record.finalStudentName = null;
    record.finalSisUserId = "";
    record.finalLoginId = "";
    record.finalSection = "";
    return record;
  }

  const student = selectedUserId != null ? rosterById.get(selectedUserId) : null;
  if (!student) {
    record.finalStatus = "";
    record.finalUserId = null;
    record.finalStudentName = null;
    record.finalSisUserId = "";
    record.finalLoginId = "";
    record.finalSection = "";
    return record;
  }

  record.finalStatus = "matched";
  record.finalUserId = Number(student.userId);
  record.finalStudentName = student.name;
  record.finalSisUserId = student.sisUserId || "";
  record.finalLoginId = student.loginId || "";
  record.finalSection = student.section || "";
  return record;
}

function summarizeMatchRecords(records) {
  const summary = { auto: 0, needs_review: 0, unmatched: 0, duplicate_candidate: 0 };
  for (const record of records) {
    summary[record.status] = (summary[record.status] || 0) + 1;
  }
  return summary;
}

function summarizeLockedRecords(records) {
  const summary = { matched: 0, skipped: 0, pending: 0 };
  for (const record of records) {
    const status = record.finalStatus || "pending";
    summary[status] = (summary[status] || 0) + 1;
  }
  return summary;
}

function parseCSV(text) {
  const rows = [];
  let row = [];
  let field = "";
  let inQuotes = false;

  for (let i = 0; i < text.length; i += 1) {
    const char = text[i];
    const next = text[i + 1];

    if (char === "\"") {
      if (inQuotes && next === "\"") {
        field += "\"";
        i += 1;
      } else {
        inQuotes = !inQuotes;
      }
      continue;
    }

    if (char === "," && !inQuotes) {
      row.push(field);
      field = "";
      continue;
    }

    if ((char === "\n" || char === "\r") && !inQuotes) {
      if (char === "\r" && next === "\n") {
        i += 1;
      }
      row.push(field);
      field = "";
      rows.push(row);
      row = [];
      continue;
    }

    field += char;
  }

  if (field.length || row.length) {
    row.push(field);
    rows.push(row);
  }
  return rows;
}

function csvObjectsFromText(text) {
  const rows = parseCSV(text);
  const headers = rows.shift() || [];
  return rows.map((row) => {
    const object = {};
    headers.forEach((header, index) => {
      object[header] = row[index] || "";
    });
    return object;
  });
}

async function loadGradebookRoster(csvPath) {
  const text = await fs.readFile(csvPath, "utf8");
  const rows = csvObjectsFromText(stripUTF8BOM(text));
  const students = [];
  for (const row of rows) {
    const name = firstValue(row, ["Student Name", "Student"]);
    if (!name || name === "Points Possible") continue;
    const userId = firstValue(row, ["Student ID", "ID"]);
    students.push({
      userId: userId ? Number(userId) : 0,
      name,
      sortableName: row["Sortable Name"] || "",
      shortName: row["Short Name"] || "",
      sisUserId: firstValue(row, ["SIS User ID"]),
      loginId: firstValue(row, ["SIS Login ID", "Login ID"]),
      section: (row.Section || "").trim(),
    });
  }
  return students;
}

async function gradebookTemplateInfo(csvPath) {
  const text = await fs.readFile(csvPath, "utf8");
  const rows = parseCSV(stripUTF8BOM(text));
  return {
    headers: rows[0] || [],
  };
}

function mergeRosters(apiStudents, csvStudents) {
  if (!apiStudents.length) {
    return csvStudents.slice().sort((a, b) => a.name.localeCompare(b.name));
  }
  const merged = new Map(apiStudents.map((student) => [Number(student.userId), { ...student }]));
  for (const student of csvStudents) {
    const userId = Number(student.userId);
    if (!userId || !merged.has(userId)) continue;
    const existing = merged.get(userId);
    if (!existing.section && student.section) existing.section = student.section;
    if (!existing.sisUserId && student.sisUserId) existing.sisUserId = student.sisUserId;
    if (!existing.loginId && student.loginId) existing.loginId = student.loginId;
  }
  return Array.from(merged.values()).sort((a, b) => a.name.localeCompare(b.name));
}

async function buildSessionDataset(session, assetRoot, workingRoot) {
  const submissions = [];
  const sessionDir = path.join(workingRoot, safeName(session.title, "session"), "pdfs");
  await fs.mkdir(sessionDir, { recursive: true });

  for (const submission of (session.submissions || []).filter((item) => item.processingState === "completed")) {
    const scanPaths = (submission.assets || []).map((asset) => path.join(assetRoot, asset.storedPath));
    const pdfPath = await ensureSubmissionPdf(submission, assetRoot, sessionDir);
    submissions.push({
      submissionId: submission.id,
      folderName: safeName(submission.studentName || submission.id, "submission"),
      studentName: submission.studentName,
      totalScore: Number(submission.totalScore || 0),
      maxScore: Number(submission.maxScore || 0),
      teacherReviewed: Boolean(submission.teacherReviewed),
      nameNeedsReview: Boolean(submission.nameNeedsReview),
      createdAt: submission.createdAt,
      overallNotes: submission.overallNotes || "",
      scanPaths,
      pdfPath,
      grades: submission.grades || [],
    });
  }

  ensureUniqueStudentNames(submissions.map((submission) => submission.studentName), "canvas matching");

  return {
    title: session.title,
    createdAt: session.createdAt,
    questionCount: (session.questions || []).length,
    totalPoints: (session.questions || []).reduce((sum, question) => sum + Number(question.maxPoints || 0), 0),
    submissions,
  };
}

async function ensureSubmissionPdf(submission, assetRoot, outputDir) {
  const assets = submission.assets || [];
  if (!assets.length) {
    throw new Error(`No scan files were found for submission ${submission.studentName || submission.id}.`);
  }

  if (assets.length === 1 && assets[0].kind === "pdf") {
    return path.join(assetRoot, assets[0].storedPath);
  }

  const outputPath = path.join(outputDir, `${safeName(submission.studentName || submission.id, "submission")}-${String(submission.id).slice(0, 8)}.pdf`);
  const jpegImages = [];
  for (const asset of assets) {
    if (asset.kind !== "image") {
      throw new Error("A submission cannot mix PDFs with image files in the Canvas workflow.");
    }
    const sourcePath = path.join(assetRoot, asset.storedPath);
    const image = nativeImage.createFromPath(sourcePath);
    if (image.isEmpty()) {
      throw new Error(`Unable to decode image file ${path.basename(sourcePath)}.`);
    }
    const size = image.getSize();
    const jpegBuffer = sourcePath.toLowerCase().match(/\.(jpe?g)$/)
      ? await fs.readFile(sourcePath)
      : image.toJPEG(90);
    jpegImages.push({ width: size.width, height: size.height, jpegBuffer });
  }

  await fs.writeFile(outputPath, buildJPEGPDF(jpegImages));
  return outputPath;
}

function buildJPEGPDF(images) {
  const objects = [null, null];
  const pageIds = [];

  for (let index = 0; index < images.length; index += 1) {
    const image = images[index];
    const pageIndex = index + 1;
    const imageDict = [
      "<<",
      "/Type /XObject",
      "/Subtype /Image",
      `/Width ${image.width}`,
      `/Height ${image.height}`,
      "/ColorSpace /DeviceRGB",
      "/BitsPerComponent 8",
      "/Filter /DCTDecode",
      `/Length ${image.jpegBuffer.length}`,
      ">>",
    ].join("\n");
    const imageObjectId = objects.length + 1;
    objects.push(streamObject(Buffer.from(imageDict, "ascii"), image.jpegBuffer));

    const contentStream = Buffer.from(`q\n${image.width} 0 0 ${image.height} 0 0 cm\n/Im${pageIndex} Do\nQ\n`, "ascii");
    const contentObjectId = objects.length + 1;
    objects.push(streamObject(Buffer.from(`<< /Length ${contentStream.length} >>`, "ascii"), contentStream));

    const pageObjectId = objects.length + 1;
    objects.push(
      Buffer.from(
        [
          "<<",
          "/Type /Page",
          "/Parent 2 0 R",
          `/MediaBox [0 0 ${image.width} ${image.height}]`,
          `/Contents ${contentObjectId} 0 R`,
          `/Resources << /ProcSet [/PDF /ImageC] /XObject << /Im${pageIndex} ${imageObjectId} 0 R >> >>`,
          ">>",
        ].join("\n"),
        "ascii"
      )
    );
    pageIds.push(pageObjectId);
  }

  objects[0] = Buffer.from("<< /Type /Catalog /Pages 2 0 R >>", "ascii");
  objects[1] = Buffer.from(
    ["<<", "/Type /Pages", `/Count ${pageIds.length}`, `/Kids [${pageIds.map((id) => `${id} 0 R`).join(" ")}]`, ">>"].join("\n"),
    "ascii"
  );

  const output = [Buffer.from("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n", "binary")];
  const offsets = [0];
  let length = output[0].length;

  for (let i = 0; i < objects.length; i += 1) {
    const objectId = i + 1;
    offsets.push(length);
    const prefix = Buffer.from(`${objectId} 0 obj\n`, "ascii");
    const suffix = Buffer.from("\nendobj\n", "ascii");
    output.push(prefix, objects[i], suffix);
    length += prefix.length + objects[i].length + suffix.length;
  }

  const xrefOffset = length;
  const xrefParts = [Buffer.from(`xref\n0 ${objects.length + 1}\n`, "ascii"), Buffer.from("0000000000 65535 f \n", "ascii")];
  for (const offset of offsets.slice(1)) {
    xrefParts.push(Buffer.from(`${String(offset).padStart(10, "0")} 00000 n \n`, "ascii"));
  }
  const trailer = Buffer.from(
    `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xrefOffset}\n%%EOF\n`,
    "ascii"
  );
  return Buffer.concat([...output, ...xrefParts, trailer]);
}

function streamObject(header, stream) {
  return Buffer.concat([header, Buffer.from("\nstream\n", "ascii"), stream, Buffer.from("\nendstream", "ascii")]);
}

async function buildGradeImportCSV(templatePath, outputPath, assignmentColumn, lockedRecords) {
  const text = await fs.readFile(templatePath, "utf8");
  const rows = parseCSV(stripUTF8BOM(text));
  const headers = rows[0] || [];
  if (!headers.includes(assignmentColumn)) {
    throw new Error(`Assignment column '${assignmentColumn}' was not found in the template CSV.`);
  }

  const objects = rows.slice(1).map((row) => {
    const obj = {};
    headers.forEach((header, index) => {
      obj[header] = row[index] || "";
    });
    return obj;
  });

  const matchedByUserId = new Map(
    lockedRecords
      .filter((record) => record.finalStatus === "matched" && record.finalUserId != null)
      .map((record) => [String(record.finalUserId), record])
  );

  let updatedRows = 0;
  let templateRowsWithoutId = 0;
  for (const row of objects) {
    if (firstValue(row, ["Student Name", "Student"]) === "Points Possible") continue;
    const userId = firstValue(row, ["Student ID", "ID"]);
    if (!userId) {
      templateRowsWithoutId += 1;
      continue;
    }
    const record = matchedByUserId.get(userId);
    if (!record) continue;
    row[assignmentColumn] = formatPoints(record.totalScore);
    updatedRows += 1;
  }

  const output = [headers.map(escapeCSV).join(",")];
  for (const row of objects) {
    output.push(headers.map((header) => escapeCSV(row[header] || "")).join(","));
  }
  await fs.writeFile(outputPath, output.join("\n"), "utf8");
  return { updatedRows, templateRowsWithoutId };
}

function formatPoints(value) {
  return scoreString(Number(value || 0));
}

function buildCommentText(localSubmission, config) {
  if (!config.uploadCommentEnabled) {
    return null;
  }

  const lines = [];
  const grades = (localSubmission.grades || []).slice().sort((a, b) => questionSortKey(a.displayLabel).localeCompare(questionSortKey(b.displayLabel), undefined, { numeric: true }));

  if (config.uploadCommentIncludeTotalScore) {
    lines.push(`Total Score: ${formatPoints(localSubmission.totalScore)}/${formatPoints(localSubmission.maxScore)}`);
  }

  if (config.uploadCommentIncludeQuestionScores) {
    if (lines.length) lines.push("");
    lines.push("Question Scores:");
    for (const grade of grades) {
      const label = String(grade.displayLabel || grade.questionID || "Question").trim();
      lines.push(`- ${label}: ${formatPoints(grade.awardedPoints)}/${formatPoints(grade.maxPoints)}`);
    }
  }

  if (config.uploadCommentIncludeIndividualNotes) {
    const notes = grades
      .filter((grade) => String(grade.feedback || "").trim())
      .map((grade) => {
        const label = String(grade.displayLabel || grade.questionID || "Question").trim();
        return `- ${label}: ${String(grade.feedback).trim()}`;
      });
    if (notes.length) {
      if (lines.length) lines.push("");
      lines.push("Individual Notes:");
      lines.push(...notes);
    }
  }

  const overallNotes = String(localSubmission.overallNotes || "").trim();
  if (config.uploadCommentIncludeOverallNotes && overallNotes) {
    if (lines.length) lines.push("");
    lines.push("Notes:");
    lines.push(overallNotes);
  }

  const text = lines.join("\n").trim();
  return text || null;
}

async function postGrades(client, config, lockedRecords) {
  if (!config.courseId || !config.assignmentId) {
    throw new Error("Canvas API grading requires course id and assignment id.");
  }
  const assignment = await client.getAssignment(config.courseId, config.assignmentId);
  validateAssignmentForGrading(assignment);

  if (config.enforceManualPostPolicy) {
    await client.updateAssignment(config.courseId, config.assignmentId, { "assignment[post_manually]": "true" });
  }

  const matched = lockedRecords.filter((record) => record.finalStatus === "matched" && record.finalUserId != null);
  const gradeMap = Object.fromEntries(matched.map((record) => [record.finalUserId, formatPoints(record.totalScore)]));
  const progressPayload = await client.updateAssignmentGrades(config.courseId, config.assignmentId, gradeMap);
  let finalProgress = progressPayload;
  if (progressPayload.id != null) {
    finalProgress = await client.waitForProgress(Number(progressPayload.id));
  }
  return {
    mode: "bulk",
    initialProgress: progressPayload,
    finalProgress,
    recordCount: matched.length,
  };
}

async function uploadSubmissions(client, config, lockedRecords, submissionsById) {
  if (!config.courseId || !config.assignmentId) {
    throw new Error("Canvas API upload requires course id and assignment id.");
  }
  const assignment = await client.getAssignment(config.courseId, config.assignmentId);
  validateAssignmentForCommentWorkflow(assignment);

  const matched = lockedRecords.filter((record) => record.finalStatus === "matched" && record.finalUserId != null);
  if (!config.uploadAttachPdfAsComment && !config.uploadPostGrade && !config.uploadCommentEnabled) {
    throw new Error("Upload configuration would send nothing.");
  }

  const results = [];
  for (const record of matched) {
    const localSubmission = submissionsById.get(record.localSubmissionId);
    if (!localSubmission) {
      results.push({
        localSubmissionId: record.localSubmissionId,
        localStudentName: record.localStudentName,
        finalUserId: record.finalUserId,
        finalStudentName: record.finalStudentName,
        status: "failed",
        step: "precheck",
        message: `Missing local submission data for ${record.localSubmissionId}.`,
      });
      continue;
    }

    let fileId = null;
    try {
      if (config.uploadAttachPdfAsComment) {
        const filePayload = await client.uploadSubmissionCommentFile(config.courseId, config.assignmentId, record.finalUserId, record.pdfPath);
        fileId = Number(filePayload.id);
      }
      const commentText = buildCommentText(localSubmission, config);
      const submissionPayload = await client.gradeOrCommentSubmission(config.courseId, config.assignmentId, record.finalUserId, {
        postedGrade: config.uploadPostGrade ? formatPoints(record.totalScore) : null,
        commentText,
        commentFileIds: fileId != null ? [fileId] : [],
      });
      results.push({
        localSubmissionId: record.localSubmissionId,
        localStudentName: record.localStudentName,
        finalUserId: record.finalUserId,
        finalStudentName: record.finalStudentName,
        status: "uploaded",
        step: "comment_and_grade",
        fileId,
        submissionId: submissionPayload.id != null ? Number(submissionPayload.id) : null,
        message: uploadSuccessMessage(config),
      });
    } catch (error) {
      const errorText = String(error.message || error);
      results.push({
        localSubmissionId: record.localSubmissionId,
        localStudentName: record.localStudentName,
        finalUserId: record.finalUserId,
        finalStudentName: record.finalStudentName,
        status: "failed",
        step: errorText.includes("/submissions/") ? "comment_and_grade" : "comment_file_upload",
        fileId,
        message: errorText,
      });
    }
  }

  if (config.enforceManualPostPolicy) {
    await client.updateAssignment(config.courseId, config.assignmentId, { "assignment[post_manually]": "true" });
  }
  return results;
}

function uploadSuccessMessage(config) {
  const parts = [];
  if (config.uploadAttachPdfAsComment) parts.push("attached PDF as comment");
  if (config.uploadCommentEnabled) parts.push("posted comment text");
  if (config.uploadPostGrade) parts.push("updated grade");
  return parts.length ? `${capitalize(parts.join(", "))}.` : "Uploaded.";
}

function validateAssignmentForGrading(assignment) {
  if (assignment.id == null) {
    throw new Error("Canvas assignment lookup did not return an assignment id.");
  }
}

function validateAssignmentForCommentWorkflow(assignment) {
  validateAssignmentForGrading(assignment);
}

function stripUTF8BOM(text) {
  return text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
}

function firstValue(row, headers) {
  for (const header of headers) {
    const value = String(row[header] || "").trim();
    if (value) return value;
  }
  return "";
}

function questionSortKey(label) {
  const digits = String(label || "").replace(/\D/g, "");
  return digits ? digits.padStart(10, "0") : `zzzz-${String(label || "").toLowerCase()}`;
}

function capitalize(value) {
  const text = String(value || "");
  return text ? text.charAt(0).toUpperCase() + text.slice(1) : text;
}

function ensureUniqueStudentNames(names, context) {
  const seen = new Map();
  const duplicates = [];
  for (const rawName of names) {
    const normalized = normalizeName(rawName) || String(rawName || "").trim().toLowerCase();
    if (!normalized) continue;
    if (seen.has(normalized)) {
      duplicates.push(`${normalized}: ${seen.get(normalized)}, ${rawName}`);
    } else {
      seen.set(normalized, rawName);
    }
  }
  if (duplicates.length) {
    throw new Error(`Duplicate student names detected during ${context}: ${duplicates.join("; ")}`);
  }
}

function summarizeUploadResults(results) {
  const summary = {};
  for (const result of results) {
    summary[result.status] = (summary[result.status] || 0) + 1;
  }
  return summary;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

module.exports = {
  CanvasAPI,
  CanvasAPIError,
  applyMatchSelection,
  buildCommentText,
  buildGradeImportCSV,
  buildMatchManifest,
  buildSessionDataset,
  defaultCanvasModule,
  ensureCanvasModule,
  ensureUniqueStudentNames,
  formatPoints,
  gradebookTemplateInfo,
  loadGradebookRoster,
  mergeRosters,
  postGrades,
  rankCandidates,
  scoreNameMatch,
  summarizeLockedRecords,
  summarizeMatchRecords,
  summarizeUploadResults,
  uploadSubmissions,
};
