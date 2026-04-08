"use strict";

const appRoot = document.getElementById("app");

const ui = {
  selectedSessionId: null,
  selectedTab: "overview",
  resultsSearch: "",
  modal: null,
  busy: null,
  toast: null,
  scrollPositions: {},
};

let snapshot = null;
let toastTimer = null;
const deepClone = (value) => JSON.parse(JSON.stringify(value));

boot().catch((error) => {
  console.error(error);
  appRoot.innerHTML = `<div class="empty-state"><h3>Renderer failed to boot</h3><p>${escapeHTML(error.message || String(error))}</p></div>`;
});

async function boot() {
  snapshot = await window.hgrader.getSnapshot();
  const unsubscribe = window.hgrader.onStateUpdated((nextSnapshot) => {
    snapshot = nextSnapshot;
    syncUIWithSnapshot();
    render();
  });
  window.addEventListener("beforeunload", () => unsubscribe());
  installEventDelegates();
  syncUIWithSnapshot();
  render();
}

function syncUIWithSnapshot() {
  const sessions = snapshot?.state?.sessions || [];
  if (!sessions.length) {
    ui.selectedSessionId = null;
    return;
  }
  if (!ui.selectedSessionId || !sessions.some((session) => session.id === ui.selectedSessionId)) {
    ui.selectedSessionId = sessions[0].id;
  }
}

function render() {
  captureScrollPositions();
  const sessions = snapshot?.state?.sessions || [];
  const session = sessions.find((item) => item.id === ui.selectedSessionId) || null;

  appRoot.innerHTML = `
    <div class="shell">
      ${renderSidebar(sessions)}
      <main class="main">
        <div class="topbar">
          <div class="headline">
            <h1>HGrader Mac</h1>
            <p>Electron desktop port of HomeworkGrader, extended into an end-to-end grading workspace with optional Canvas publishing after review.</p>
          </div>
          <div class="toolbar-actions">
            <button type="button" class="ghost-button" data-action="open-settings">Settings</button>
            <button type="button" class="primary-button" data-action="open-new-session">New Session</button>
          </div>
        </div>
        <div class="workspace scroll-area" data-scroll-key="workspace">
          ${session ? renderSessionWorkspace(session) : renderWelcomeState()}
        </div>
      </main>
      ${renderModal(session)}
      ${ui.busy ? `<div class="busy-overlay"><strong>${escapeHTML(ui.busy.title)}</strong><div class="muted">${escapeHTML(ui.busy.detail || "")}</div></div>` : ""}
      ${ui.toast ? `<div class="toast ${ui.toast.tone}">${escapeHTML(ui.toast.message)}</div>` : ""}
    </div>
  `;

  restoreScrollPositions();
  hydrateMath();
}

function renderSidebar(sessions) {
  return `
    <aside class="sidebar">
      <div class="brand">
        <div class="brand-mark">
          <div class="brand-kicker">Paper To Canvas</div>
          <div class="brand-title">HGrader</div>
        </div>
        <button type="button" class="chip-button" data-action="open-new-session">Create</button>
      </div>
      <div class="session-list" data-scroll-key="sidebar-list">
        ${sessions.length ? sessions.map(renderSessionCard).join("") : `
          <div class="sidebar-empty">
            No grading sessions yet. Create one, upload the blank assignment, approve the rubric, and start grading.
          </div>
        `}
      </div>
    </aside>
  `;
}

function renderSessionCard(session) {
  return `
    <button type="button" class="session-card ${session.id === ui.selectedSessionId ? "active" : ""}" data-action="select-session" data-session-id="${session.id}">
      <div class="session-card-title">${escapeHTML(session.title)}</div>
      <div class="status-row">${renderSessionChips(session)}</div>
      <div class="session-meta">Created ${formatDateTime(session.createdAt)}</div>
      <div class="session-meta">${session.questions.length} questions • ${session.submissions.length} submissions</div>
      <div class="session-meta">API cost: ${escapeHTML(session.sessionCostLabel)}</div>
    </button>
  `;
}

function renderSessionWorkspace(session) {
  return `
    <section class="hero-panel">
      <div class="panel-header">
        <div>
          <div class="brand-kicker">Active Session</div>
          <h2 class="hero-title">${escapeHTML(session.title)}</h2>
          <p class="hero-copy">The original iPhone app flowed through Overview, Rubric, and Results. This desktop build keeps the same lifecycle, but file ingestion replaces camera capture and review surfaces are widened so scans can sit beside grading controls.</p>
        </div>
        <div class="panel-actions">
          <button type="button" class="secondary-button" data-action="refresh-session" data-session-id="${session.id}">Refresh Jobs</button>
          <button type="button" class="ghost-button" data-action="open-edit-session" data-session-id="${session.id}">Edit Config</button>
          <button type="button" class="danger-button" data-action="delete-session" data-session-id="${session.id}">Delete Session</button>
        </div>
      </div>
      <div class="tabbar">
        ${["overview", "rubric", "results", "canvas"].map((tab) => `
          <button type="button" class="tab-button ${ui.selectedTab === tab ? "active" : ""}" data-action="select-tab" data-tab="${tab}">
            ${tab[0].toUpperCase()}${tab.slice(1)}
          </button>
        `).join("")}
      </div>
    </section>
    ${ui.selectedTab === "overview" ? renderOverviewTab(session) : ""}
    ${ui.selectedTab === "rubric" ? renderRubricTab(session) : ""}
    ${ui.selectedTab === "results" ? renderResultsTab(session) : ""}
    ${ui.selectedTab === "canvas" ? renderCanvasTab(session) : ""}
  `;
}

function renderWelcomeState() {
  return `
    <section class="empty-state">
      <h3>Desktop grading workspace</h3>
      <p>Create a grading session, save your OpenAI key in Settings, upload the blank assignment, approve the generated rubric, and then drag in student PDFs or scan-image sets. Batch jobs poll in the background and the final export stays compatible with CanvasConnect.</p>
      <div class="panel-actions" style="justify-content:center">
        <button type="button" class="primary-button" data-action="open-new-session">Create First Session</button>
        <button type="button" class="ghost-button" data-action="open-settings">Open Settings</button>
      </div>
    </section>
  `;
}

function renderOverviewTab(session) {
  return `
    <section class="content-panel">
      <div class="panel-header">
        <div>
          <h3 class="panel-title">Overview</h3>
          <p class="panel-copy">Master upload generates the rubric, student uploads feed the grading queue, and the session summary mirrors the original HomeworkGrader controls.</p>
        </div>
      </div>
      <div class="grid-two">
        <div class="dropzone" data-upload="master" data-session-id="${session.id}">
          <strong>Blank Assignment</strong>
          <p>${snapshot.meta.hasAPIKey ? "Upload or drag the teacher copy, blank exam pages, or a clean master PDF. The app will submit an OpenAI answer-key batch immediately." : "Add your OpenAI API key in Settings before uploading the blank assignment."}</p>
          <button type="button" class="primary-button" data-action="choose-master-files" data-session-id="${session.id}">Upload Blank Assignment</button>
        </div>
        <div class="dropzone" data-upload="batch" data-session-id="${session.id}">
          <strong>Student Scan Batch</strong>
          <p>${session.questions.length ? "Drag student PDFs or image files here. Each PDF should represent one submission; image sets can be grouped by file count in the next step." : "You can queue student scans before rubric approval. They stay local until the rubric is approved, then you can submit them all in one batch."}</p>
          <button type="button" class="primary-button" data-action="choose-batch-files" data-session-id="${session.id}" ${session.isFinished ? "disabled" : ""}>Batch Add Student Files</button>
        </div>
      </div>
      ${session.questions.length ? `
        <div class="dropzone" data-upload="single" data-session-id="${session.id}" style="margin-top:18px">
          <strong>Single Submission</strong>
          <p>Use this for irregular page counts or immediate one-off review. Upload one PDF or one image-only set and the model will return a review draft before anything is saved.</p>
          <button type="button" class="secondary-button" data-action="choose-single-files" data-session-id="${session.id}" ${!snapshot.meta.hasAPIKey || session.isFinished ? "disabled" : ""}>Grade One Submission</button>
        </div>
      ` : ""}
    </section>
    ${session.masterAssets.length ? `
      <section class="content-panel">
        <div class="panel-header">
          <div>
            <h3 class="panel-title">Master Files</h3>
            <p class="panel-copy">${session.hasPendingRubricGeneration ? escapeHTML(session.rubricProcessing?.detail || "Answer key batch pending.") : session.hasPendingRubricReview ? "A generated rubric is ready for review." : "The saved master files drive rubric generation and stay in the export package."}</p>
          </div>
          <div class="panel-actions">
            ${session.hasPendingRubricReview ? `<button type="button" class="primary-button" data-action="open-rubric-review" data-session-id="${session.id}">Review Generated Answer Key</button>` : ""}
          </div>
        </div>
        <div class="asset-grid">${renderAssets(session.masterAssets)}</div>
      </section>
    ` : ""}
    <section class="summary-grid">
      <div class="summary-card">
        <div class="summary-label">Questions</div>
        <div class="summary-value">${session.questions.length}</div>
        <div class="summary-subvalue">Total points: ${score(session.totalPossiblePoints)}</div>
      </div>
      <div class="summary-card">
        <div class="summary-label">Saved Submissions</div>
        <div class="summary-value">${session.submissions.length}</div>
        <div class="summary-subvalue">${completedSubmissions(session).length} completed</div>
      </div>
      <div class="summary-card">
        <div class="summary-label">API Cost</div>
        <div class="summary-value">${escapeHTML(session.sessionCostLabel)}</div>
        <div class="summary-subvalue">${session.validationEnabled ? "Validation enabled" : "Validation disabled"}</div>
      </div>
    </section>
    <section class="content-panel">
      <div class="panel-header">
        <div>
          <h3 class="panel-title">Session Configuration</h3>
          <p class="panel-copy">These values are carried from the iOS app one-for-one: model ids, scoring policy, relaxed grading, reasoning/verbosity, service tier, and validation attempt count.</p>
        </div>
        <div class="panel-actions">
          <button type="button" class="ghost-button" data-action="open-edit-session" data-session-id="${session.id}">Edit Config</button>
        </div>
      </div>
      <div class="grid-two">
        <div class="detail-pane">
          <div class="detail-section">
            <div class="detail-label">Scoring</div>
            <div class="kv-list">
              ${kvRow("Point mode", session.pointModeLabel)}
              ${kvRow("Relaxed grading", session.relaxedModeLabel)}
              ${kvRow("Session ended", session.isFinished ? "On" : "Off")}
              ${kvRow("Validation model", session.validationModelLabel)}
            </div>
          </div>
        </div>
        <div class="detail-pane">
          <div class="detail-section">
            <div class="detail-label">OpenAI Tuning</div>
            <div class="kv-list">
              ${kvRow("Answer model", session.answerModelID)}
              ${kvRow("Grading model", session.gradingModelID)}
              ${kvRow("Answer reasoning", session.answerReasoningLabel)}
              ${kvRow("Grading reasoning", session.gradingReasoningLabel)}
              ${kvRow("Validation reasoning", session.validationReasoningLabel)}
              ${kvRow("Validation attempts", String(session.validationMaxAttemptsResolved))}
            </div>
          </div>
        </div>
      </div>
    </section>
  `;
}

function renderRubricTab(session) {
  if (!session.questions.length) {
    return `
      <section class="content-panel">
        <div class="panel-header">
          <div>
            <h3 class="panel-title">Rubric</h3>
            <p class="panel-copy">${session.hasPendingRubricGeneration ? escapeHTML(session.rubricProcessing?.detail || "Answer key pending.") : session.hasPendingRubricReview ? "A generated rubric is ready for review and approval." : session.hasFailedRubricGeneration ? escapeHTML(session.rubricProcessing?.detail || "The last answer-key request failed.") : "Upload the blank assignment from the Overview tab first."}</p>
          </div>
          <div class="panel-actions">
            ${session.hasPendingRubricReview ? `<button type="button" class="primary-button" data-action="open-rubric-review" data-session-id="${session.id}">Review Generated Answer Key</button>` : ""}
          </div>
        </div>
        ${session.masterAssets.length ? `<div class="asset-grid">${renderAssets(session.masterAssets)}</div>` : ""}
      </section>
    `;
  }

  return `
    <section class="content-panel">
      <div class="panel-header">
        <div>
          <h3 class="panel-title">Approved Rubric</h3>
          <p class="panel-copy">The desktop port keeps the same rubric structure as HomeworkGrader: teacher-reviewed questions, an overall grading rule block, and per-question prompt/ideal-answer/criteria fields.</p>
        </div>
      </div>
      <div class="grid-two">
        <div class="detail-pane">
          <div class="detail-label">Overall Rules</div>
          ${renderMathBlock(session.overallGradingRules || "No overall rules added yet.")}
        </div>
        <div class="detail-pane">
          <div class="detail-label">Master Files</div>
          <div class="asset-grid">${renderAssets(session.masterAssets)}</div>
        </div>
      </div>
      <div class="question-grid" style="margin-top:18px">
        ${(session.questions || []).slice().sort((a, b) => a.orderIndex - b.orderIndex).map((question) => `
          <div class="question-card">
            <div class="submission-header">
              <h4>${escapeHTML(question.displayLabel)}</h4>
              <div class="submission-score">${score(question.maxPoints)} pts</div>
            </div>
            <div class="detail-label">Prompt</div>
            ${renderMathBlock(question.promptText)}
            <div class="detail-label" style="margin-top:14px">Ideal Answer</div>
            ${renderMathBlock(question.idealAnswer)}
            <div class="detail-label" style="margin-top:14px">Grading Criteria</div>
            ${renderMathBlock(question.gradingCriteria)}
          </div>
        `).join("")}
      </div>
    </section>
  `;
}

function renderResultsTab(session) {
  const search = ui.resultsSearch.trim().toLowerCase();
  const submissions = (session.submissions || [])
    .slice()
    .sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)))
    .filter((submission) => !search || (submission.listDisplayName || "").toLowerCase().includes(search));

  return `
    <section class="content-panel">
      <div class="results-toolbar">
        <div class="panel-actions">
          <button type="button" class="secondary-button" data-action="export-csv" data-session-id="${session.id}" ${session.submissions.length ? "" : "disabled"}>Export Session CSV</button>
          <button type="button" class="secondary-button" data-action="export-package" data-session-id="${session.id}" ${session.submissions.length ? "" : "disabled"}>Export Full Session Package</button>
          <button type="button" class="ghost-button" data-action="regrade-all" data-session-id="${session.id}" ${canRegradeAll(session) ? "" : "disabled"}>Regrade All Saved Scans</button>
          ${(session.submissions || []).some((submission) => submission.isQueuedForRubric) ? `<button type="button" class="primary-button" data-action="submit-queued" data-session-id="${session.id}" ${canSubmitQueued(session) ? "" : "disabled"}>Submit All Queued Scans</button>` : ""}
        </div>
        <input class="search-input" data-action="results-search" placeholder="Search by student name" value="${escapeHTML(ui.resultsSearch)}" />
      </div>
      ${(session.submissions || []).some((submission) => submission.isAwaitingRemoteProcessing) ? `
        <div class="dropzone" style="margin-bottom:18px">
          <strong>Pending Batch Jobs</strong>
          <p>Batch submissions show up here immediately as pending. Polling runs in the background while the app is open, and you can force a check any time.</p>
          <button type="button" class="secondary-button" data-action="refresh-session" data-session-id="${session.id}">Check Pending Jobs</button>
        </div>
      ` : ""}
      ${submissions.length ? `
        <div class="list-stack">
          ${submissions.map((submission) => `
            <button type="button" class="submission-card" data-action="view-submission" data-session-id="${session.id}" data-submission-id="${submission.id}">
              <div class="submission-header">
                <div>
                  <h4>${escapeHTML(submission.listDisplayName)}</h4>
                  <p>${formatDateTime(submission.createdAt)}</p>
                </div>
                <div class="submission-score">${submission.isProcessingCompleted ? `${score(submission.totalScore)} / ${score(submission.maxScore)}` : escapeHTML(pendingLabel(submission))}</div>
              </div>
              <div class="chip-row">${renderSubmissionChips(submission)}</div>
              ${submission.processingDetail ? `<p style="margin-top:10px">${escapeHTML(submission.processingDetail)}</p>` : ""}
            </button>
          `).join("")}
        </div>
      ` : `
        <div class="empty-state">
          <h3>No results yet</h3>
          <p>Upload student work from the Overview tab. Queued, pending, completed, and failed submissions all appear here with the same review/export lifecycle as the original app.</p>
        </div>
      `}
    </section>
  `;
}

function renderCanvasTab(session) {
  const canvas = session.canvasModule;
  const matches = (canvas.matches || []).slice().sort((a, b) => a.localStudentName.localeCompare(b.localStudentName));
  const matchedCount = matches.filter((record) => record.finalStatus === "matched").length;
  const skippedCount = matches.filter((record) => record.finalStatus === "skipped").length;
  const pendingCount = Math.max(matches.length - matchedCount - skippedCount, 0);
  const uploadSummary = summarizeStatuses(canvas.lastUploadResults || []);

  return `
    <section class="content-panel">
      <div class="panel-header">
        <div>
          <h3 class="panel-title">Canvas Module</h3>
          <p class="panel-copy">This is the GUI adaptation of CanvasConnect: configure Canvas, load a roster, review fuzzy matches, then export a Gradebook CSV or push grades and PDF comments directly to Canvas.</p>
        </div>
        <div class="panel-actions">
          <button type="button" class="ghost-button" data-action="open-settings">Tokens</button>
          <button type="button" class="secondary-button" data-action="load-canvas-roster" data-session-id="${session.id}" ${snapshot.meta.hasCanvasToken ? "" : "disabled"}>Load Roster From Canvas</button>
          <button type="button" class="secondary-button" data-action="choose-gradebook-template" data-session-id="${session.id}">Choose Gradebook CSV</button>
          <button type="button" class="primary-button" data-action="run-canvas-matching" data-session-id="${session.id}" ${canvas.rosterCount ? "" : "disabled"}>Run Matching</button>
        </div>
      </div>
      <form id="canvas-config-form">
        <input type="hidden" name="sessionId" value="${session.id}" />
        <div class="grid-two">
          <div class="detail-pane">
            <div class="field">
              <label>Canvas Base URL</label>
              <input name="canvasBaseUrl" placeholder="https://canvas.example.edu" value="${escapeHTML(canvas.canvasBaseUrl || "")}" />
            </div>
            <div class="grid-two">
              <div class="field">
                <label>Course ID</label>
                <input name="courseId" value="${escapeHTML(String(canvas.courseId || ""))}" />
              </div>
              <div class="field">
                <label>Assignment ID</label>
                <input name="assignmentId" value="${escapeHTML(String(canvas.assignmentId || ""))}" />
              </div>
            </div>
            <div class="field">
              <label>Gradebook Template CSV</label>
              <input name="gradebookTemplatePath" value="${escapeHTML(canvas.gradebookTemplatePath || "")}" placeholder="Choose a Canvas Gradebook export CSV" />
            </div>
            ${renderAssignmentColumnField(canvas)}
            <div class="grid-three">
              <div class="field">
                <label>Auto Accept Score</label>
                <input name="matchAutoAcceptScore" type="number" min="0" max="100" value="${escapeHTML(String(canvas.matchAutoAcceptScore))}" />
              </div>
              <div class="field">
                <label>Review Floor</label>
                <input name="matchReviewFloor" type="number" min="0" max="100" value="${escapeHTML(String(canvas.matchReviewFloor))}" />
              </div>
              <div class="field">
                <label>Match Margin</label>
                <input name="matchMargin" type="number" min="0" max="100" value="${escapeHTML(String(canvas.matchMargin))}" />
              </div>
            </div>
          </div>
          <div class="detail-pane">
            <div class="detail-label">Canvas Publish Options</div>
            <div class="boolean-row">
              ${toggleField("enforceManualPostPolicy", "Keep Manual Posting Policy", Boolean(canvas.enforceManualPostPolicy))}
              ${toggleField("uploadAttachPdfAsComment", "Attach PDF As Comment", Boolean(canvas.uploadAttachPdfAsComment))}
              ${toggleField("uploadPostGrade", "Post Grade With Upload", Boolean(canvas.uploadPostGrade))}
              ${toggleField("uploadCommentEnabled", "Post Comment Text", Boolean(canvas.uploadCommentEnabled))}
              ${toggleField("uploadCommentIncludeTotalScore", "Include Total Score", Boolean(canvas.uploadCommentIncludeTotalScore))}
              ${toggleField("uploadCommentIncludeQuestionScores", "Include Question Scores", Boolean(canvas.uploadCommentIncludeQuestionScores))}
              ${toggleField("uploadCommentIncludeIndividualNotes", "Include Per-Question Notes", Boolean(canvas.uploadCommentIncludeIndividualNotes))}
              ${toggleField("uploadCommentIncludeOverallNotes", "Include Overall Notes", Boolean(canvas.uploadCommentIncludeOverallNotes))}
            </div>
            <div class="field" style="margin-top:18px">
              <label>Request Timeout Seconds</label>
              <input name="requestTimeoutSeconds" type="number" min="10" value="${escapeHTML(String(canvas.requestTimeoutSeconds || 60))}" />
            </div>
            <div class="panel-actions" style="margin-top:18px">
              <button type="submit" class="primary-button">Save Canvas Config</button>
            </div>
            <p class="panel-copy" style="margin-top:14px">${snapshot.meta.hasCanvasToken ? "Canvas token is saved." : "Canvas token is not saved yet. Open Settings to add it."}</p>
            <p class="panel-copy">${canvas.gradebookTemplateColumns?.length ? `Template columns loaded: ${canvas.gradebookTemplateColumns.length}.` : "No Gradebook template loaded yet."}</p>
          </div>
        </div>
      </form>
    </section>
    <section class="summary-grid">
      <div class="summary-card">
        <div class="summary-label">Roster</div>
        <div class="summary-value">${canvas.rosterCount || 0}</div>
        <div class="summary-subvalue">${canvas.rosterLoadedAt ? `Loaded ${formatDateTime(canvas.rosterLoadedAt)}` : "No roster loaded"}</div>
      </div>
      <div class="summary-card">
        <div class="summary-label">Match Review</div>
        <div class="summary-value">${matchedCount}</div>
        <div class="summary-subvalue">${pendingCount} pending • ${skippedCount} skipped</div>
      </div>
      <div class="summary-card">
        <div class="summary-label">Last Upload</div>
        <div class="summary-value">${canvas.lastUploadResults?.length ? canvas.lastUploadResults.length : 0}</div>
        <div class="summary-subvalue">${canvas.lastUploadResults?.length ? `${uploadSummary.uploaded || 0} uploaded • ${uploadSummary.failed || 0} failed` : "No Canvas upload run yet"}</div>
      </div>
    </section>
    <section class="content-panel">
      <div class="panel-header">
        <div>
          <h3 class="panel-title">Match Review</h3>
          <p class="panel-copy">Auto-accepted matches are prefilled. Review candidates, then change the selection to another roster entry or explicitly skip a submission.</p>
        </div>
        <div class="panel-actions">
          <button type="button" class="ghost-button" data-action="run-canvas-matching" data-session-id="${session.id}" ${canvas.rosterCount ? "" : "disabled"}>Re-run Matching</button>
        </div>
      </div>
      ${matches.length ? `
        <div class="list-stack">
          ${matches.map((record) => renderCanvasMatchRow(session, record, canvas)).join("")}
        </div>
      ` : `
        <div class="empty-state">
          <h3>No match manifest yet</h3>
          <p>Load a Canvas roster or Gradebook CSV, then run matching. The GUI replaces the CLI prompt loop with editable rows and explicit final selections.</p>
        </div>
      `}
    </section>
    <section class="content-panel">
      <div class="panel-header">
        <div>
          <h3 class="panel-title">Publish</h3>
          <p class="panel-copy">Use the current session directly. No export/import round trip is required inside the desktop app.</p>
        </div>
      </div>
      <div class="panel-actions">
        <button type="button" class="secondary-button" data-action="export-canvas-gradebook" data-session-id="${session.id}" ${(matchedCount && canvas.gradebookTemplatePath && canvas.assignmentColumn) ? "" : "disabled"}>Build Gradebook CSV</button>
        <button type="button" class="secondary-button" data-action="post-canvas-grades" data-session-id="${session.id}" ${(matchedCount && snapshot.meta.hasCanvasToken) ? "" : "disabled"}>Post Grades</button>
        <button type="button" class="primary-button" data-action="upload-canvas-submissions" data-session-id="${session.id}" ${(matchedCount && snapshot.meta.hasCanvasToken) ? "" : "disabled"}>Upload PDFs + Comments</button>
      </div>
      ${canvas.lastGradeResults ? `
        <div class="detail-pane" style="margin-top:18px">
          <div class="detail-label">Last Grade Post</div>
          <div class="kv-list">
            ${kvRow("Mode", canvas.lastGradeResults.mode || "bulk")}
            ${kvRow("Canvas Progress", canvas.lastGradeResults.finalProgress?.workflow_state || "unknown")}
            ${kvRow("Record Count", String(canvas.lastGradeResults.recordCount || 0))}
          </div>
        </div>
      ` : ""}
      ${canvas.lastUploadResults?.length ? `
        <div class="detail-pane" style="margin-top:18px">
          <div class="detail-label">Last Upload Result Summary</div>
          <div class="kv-list">
            ${Object.entries(uploadSummary).map(([status, count]) => kvRow(capitalize(status), String(count))).join("")}
          </div>
        </div>
      ` : ""}
    </section>
  `;
}

function renderAssignmentColumnField(canvas) {
  if (canvas.gradebookTemplateColumns?.length) {
    return `
      <div class="field">
        <label>Assignment Column</label>
        <select name="assignmentColumn">
          <option value="">Choose a column</option>
          ${canvas.gradebookTemplateColumns.map((column) => `
            <option value="${escapeHTML(column)}" ${canvas.assignmentColumn === column ? "selected" : ""}>${escapeHTML(column)}</option>
          `).join("")}
        </select>
      </div>
    `;
  }
  return `
    <div class="field">
      <label>Assignment Column</label>
      <input name="assignmentColumn" value="${escapeHTML(canvas.assignmentColumn || "")}" placeholder="Exam 1" />
    </div>
  `;
}

function renderCanvasMatchRow(session, record, canvas) {
  const selectionValue = record.finalStatus === "matched"
    ? `user:${record.finalUserId}`
    : record.finalStatus === "skipped"
      ? "skip"
      : "";
  return `
    <div class="question-card">
      <div class="submission-header">
        <div>
          <h4>${escapeHTML(record.localStudentName || "Unnamed Student")}</h4>
          <p>${score(record.totalScore)} / ${score(record.maxScore)}</p>
        </div>
        <div class="chip-row">
          ${chip(record.status.replace(/_/g, " "), record.status === "auto" ? "ready" : record.status === "duplicate_candidate" ? "failed" : "pending")}
          ${record.finalStatus === "matched" ? chip("Matched", "ready") : ""}
          ${record.finalStatus === "skipped" ? chip("Skipped", "info") : ""}
          ${record.nameNeedsReview ? chip("Name Review", "pending") : ""}
        </div>
      </div>
      <div class="grid-two">
        <div class="detail-pane">
          <div class="detail-label">Top Candidates</div>
          <div class="list-stack">
            ${(record.candidates || []).map((candidate) => `
              <div class="kv-row">
                <span>${escapeHTML(candidate.name)}</span>
                <strong>${candidate.score} • ${escapeHTML(candidate.reason)}</strong>
              </div>
            `).join("") || `<div class="render-block empty">No candidates returned.</div>`}
          </div>
        </div>
        <div class="detail-pane">
          <div class="field">
            <label>Final Selection</label>
            <select data-action="canvas-match-select" data-session-id="${session.id}" data-local-submission-id="${record.localSubmissionId}">
              <option value="" ${selectionValue === "" ? "selected" : ""}>Pending review</option>
              <option value="skip" ${selectionValue === "skip" ? "selected" : ""}>Skip this submission</option>
              ${(canvas.roster || []).map((student) => `
                <option value="user:${student.userId}" ${selectionValue === `user:${student.userId}` ? "selected" : ""}>
                  ${escapeHTML(student.name)}${student.section ? ` • ${escapeHTML(student.section)}` : ""}${student.loginId ? ` • ${escapeHTML(student.loginId)}` : ""}
                </option>
              `).join("")}
            </select>
          </div>
          ${record.finalStatus === "matched" ? `<p class="panel-copy">Final target: ${escapeHTML(record.finalStudentName)} (${escapeHTML(String(record.finalUserId))}).</p>` : `<p class="panel-copy">Choose a roster entry or skip this submission before publishing.</p>`}
          <div class="panel-actions" style="margin-top:12px">
            <button type="button" class="ghost-button" data-action="view-submission" data-session-id="${session.id}" data-submission-id="${record.localSubmissionId}">Open Submission</button>
          </div>
        </div>
      </div>
    </div>
  `;
}

function renderModal(session) {
  if (!ui.modal) {
    return "";
  }

  switch (ui.modal.type) {
    case "new-session":
      return modalShell("Create New Session", renderSessionForm(snapshot.meta.defaults), "Create", "new-session-form");
    case "settings":
      return renderSettingsModal();
    case "edit-session":
      return modalShell("Edit Session Config", renderSessionForm(ui.modal.session, true), "Save Changes", "edit-session-form");
    case "rubric-review":
      return renderRubricReviewModal(session);
    case "batch-upload":
      return renderBatchUploadModal();
    case "review-draft":
      return renderDraftReviewModal(session, ui.modal.draft, Boolean(ui.modal.draft?.existingSubmissionId));
    case "view-submission":
      return renderSubmissionDetailModal(session, ui.modal.submissionId);
    default:
      return "";
  }
}

function renderSettingsModal() {
  const orgCost = snapshot.state.settings.organizationCostSummary;
  return `
    <div class="modal-backdrop">
      <div class="modal-card" style="max-width:760px">
        <div class="modal-header">
          <div>
            <h2>Settings</h2>
            <p class="panel-copy">The API key is kept in Electron secure storage when available. The desktop port uses the same OpenAI Responses and Batch APIs as HomeworkGrader.</p>
          </div>
          <button type="button" class="ghost-button" data-action="close-modal">Close</button>
        </div>
        <div class="modal-body" data-scroll-key="modal-body">
          <form id="settings-form" class="grid-two">
            <div class="detail-pane">
              <div class="field">
                <label for="settings-api-key">OpenAI API Key</label>
                <input id="settings-api-key" name="apiKey" type="password" placeholder="${snapshot.meta.hasAPIKey ? "A key is already saved. Enter a new one to replace it." : "sk-..."}" autocomplete="off" />
              </div>
              <div class="field">
                <label for="settings-canvas-token">Canvas API Token</label>
                <input id="settings-canvas-token" name="canvasToken" type="password" placeholder="${snapshot.meta.hasCanvasToken ? "A token is already saved. Enter a new one to replace it." : "Canvas access token"}" autocomplete="off" />
              </div>
              <div class="panel-actions" style="margin-top:14px">
                <button class="primary-button" type="submit">Save Tokens</button>
                <button class="secondary-button" type="button" data-action="test-api-key">Test OpenAI Key</button>
                <button class="ghost-button" type="button" data-action="clear-api-key">Clear Saved Key</button>
                <button class="ghost-button" type="button" data-action="clear-canvas-token">Clear Canvas Token</button>
              </div>
            </div>
            <div class="detail-pane">
              <div class="detail-label">Organization Cost Summary</div>
              <div class="summary-value">${orgCost ? currency(orgCost.totalCostUSD) : "$0.00"}</div>
              <p class="panel-copy">${orgCost ? `Fetched ${formatDateTime(orgCost.fetchedAt)}.` : "Not fetched yet. This endpoint requires an admin-capable key."}</p>
              <div class="panel-actions" style="margin-top:14px">
                <button class="secondary-button" type="button" data-action="fetch-org-cost">Fetch Org Cost</button>
              </div>
            </div>
          </form>
        </div>
      </div>
    </div>
  `;
}

function modalShell(title, body, submitLabel, formId) {
  return `
    <div class="modal-backdrop">
      <div class="modal-card" style="max-width:980px">
        <div class="modal-header">
          <h2>${escapeHTML(title)}</h2>
          <button type="button" class="ghost-button" data-action="close-modal">Close</button>
        </div>
        <div class="modal-body" data-scroll-key="modal-body">
          <form id="${formId}" class="grid-two">
            ${body}
            <div class="detail-pane" style="grid-column:1 / -1">
              <div class="panel-actions" style="justify-content:flex-end">
                <button class="ghost-button" type="button" data-action="close-modal">Cancel</button>
                <button class="primary-button" type="submit">${escapeHTML(submitLabel)}</button>
              </div>
            </div>
          </form>
        </div>
      </div>
    </div>
  `;
}

function renderSessionForm(sessionLike, editing = false) {
  return `
    <div class="detail-pane">
      <div class="field">
        <label>Assignment Title</label>
        <input name="title" value="${escapeHTML(sessionLike.title || "")}" ${editing ? "disabled" : ""} />
      </div>
      <div class="field">
        <label>Answer Generation Model</label>
        <input name="answerModelID" value="${escapeHTML(sessionLike.answerModelID || DEFAULTS().answer)}" list="model-suggestions" />
      </div>
      <div class="field">
        <label>Grading Model</label>
        <input name="gradingModelID" value="${escapeHTML(sessionLike.gradingModelID || DEFAULTS().grading)}" list="model-suggestions" />
      </div>
      <div class="field">
        <label>Validation Model</label>
        <input name="validationModelID" value="${escapeHTML(sessionLike.validationModelID || DEFAULTS().validation)}" list="model-suggestions" />
      </div>
      <div class="boolean-row">
        ${toggleField("validationEnabled", "Enable Validation", Boolean(sessionLike.validationEnabled ?? true))}
        ${toggleField("integerPointsOnly", "Integer Points Only", Boolean(sessionLike.integerPointsOnly ?? true))}
        ${toggleField("relaxedGradingMode", "Relaxed Grading", Boolean(sessionLike.relaxedGradingMode))}
        ${editing ? toggleField("isFinished", "Session Ended", Boolean(sessionLike.isFinished)) : ""}
      </div>
    </div>
    <div class="detail-pane">
      <div class="grid-two">
        ${renderSelectField("answerReasoningEffort", "Answer Reasoning", snapshot.meta.options.reasoning, sessionLike.answerReasoningEffort ?? "high")}
        ${renderSelectField("gradingReasoningEffort", "Grading Reasoning", snapshot.meta.options.reasoning, sessionLike.gradingReasoningEffort ?? "high")}
        ${renderSelectField("validationReasoningEffort", "Validation Reasoning", snapshot.meta.options.reasoning, sessionLike.validationReasoningEffort ?? "high")}
        ${renderSelectField("answerVerbosity", "Answer Verbosity", snapshot.meta.options.verbosity, sessionLike.answerVerbosity ?? null)}
        ${renderSelectField("gradingVerbosity", "Grading Verbosity", snapshot.meta.options.verbosity, sessionLike.gradingVerbosity ?? null)}
        ${renderSelectField("validationVerbosity", "Validation Verbosity", snapshot.meta.options.verbosity, sessionLike.validationVerbosity ?? null)}
        ${renderSelectField("answerServiceTier", "Answer Service Tier", snapshot.meta.options.serviceTier, sessionLike.answerServiceTier ?? "flex")}
        ${renderSelectField("gradingServiceTier", "Grading Service Tier", snapshot.meta.options.serviceTier, sessionLike.gradingServiceTier ?? "flex")}
        ${renderSelectField("validationServiceTier", "Validation Service Tier", snapshot.meta.options.serviceTier, sessionLike.validationServiceTier ?? "flex")}
        <div class="field">
          <label>Validation Max Attempts</label>
          <input type="number" min="1" max="5" name="validationMaxAttempts" value="${escapeHTML(String(sessionLike.validationMaxAttempts || 2))}" />
        </div>
      </div>
    </div>
    <datalist id="model-suggestions">
      ${snapshot.meta.modelSuggestions.map((model) => `<option value="${escapeHTML(model)}"></option>`).join("")}
    </datalist>
  `;
}

function renderRubricReviewModal(session) {
  const payload = session?.pendingRubricPayload;
  if (!payload) {
    return "";
  }
  const drafts = (payload.questions || []).map((question, index) => ({
    questionID: question.question_id || `q${index + 1}`,
    displayLabel: question.display_label || `Question ${index + 1}`,
    promptText: question.prompt_text || "",
    idealAnswer: question.ideal_answer || "",
    gradingCriteria: question.grading_criteria || "",
    maxPointsText: "1",
  }));
  return `
    <div class="modal-backdrop">
      <div class="modal-card">
        <div class="modal-header">
          <div>
            <h2>Approve Rubric</h2>
            <p class="panel-copy">Desktop-specific change: instead of sequential mobile pages, the master files stay visible in a full-width asset grid while you edit the rubric beside them.</p>
          </div>
          <button type="button" class="ghost-button" data-action="close-modal">Close</button>
        </div>
        <div class="modal-body" data-scroll-key="modal-body">
          <form id="rubric-review-form">
            <input type="hidden" name="sessionId" value="${session.id}" />
            <div class="review-layout">
              <div class="detail-pane">
                <div class="detail-label">Master Files</div>
                <div class="asset-grid">${renderAssets(session.masterAssets)}</div>
                <div class="field" style="margin-top:18px">
                  <label>Default Points For All Questions</label>
                  <input name="defaultPoints" value="1" />
                </div>
                <div class="panel-actions" style="margin-top:10px">
                  <button type="button" class="secondary-button" data-action="apply-default-points">Apply To All Questions</button>
                </div>
              </div>
              <div class="detail-pane">
                <div class="field">
                  <label>Overall Grading Rules</label>
                  <textarea name="overallRules">Apply the approved rubric consistently across all questions. Give partial credit when justified by the shown work, and mark uncertain cases for teacher review.</textarea>
                </div>
                <div class="list-stack" style="margin-top:18px">
                  ${drafts.map((draft, index) => renderRubricQuestionEditor(draft, index)).join("")}
                </div>
              </div>
            </div>
            <div class="modal-footer">
              <button type="button" class="ghost-button" data-action="close-modal">Cancel</button>
              <button type="submit" class="primary-button">Approve Rubric</button>
            </div>
          </form>
        </div>
      </div>
    </div>
  `;
}

function renderRubricQuestionEditor(draft, index) {
  return `
    <div class="question-card">
      <div class="submission-header">
        <h4>${escapeHTML(draft.displayLabel)}</h4>
        <div class="muted">Question ${index + 1}</div>
      </div>
      <div class="field">
        <label>Question ID</label>
        <input name="questionID-${index}" value="${escapeHTML(draft.questionID)}" />
      </div>
      <div class="field">
        <label>Display Label</label>
        <input name="displayLabel-${index}" value="${escapeHTML(draft.displayLabel)}" />
      </div>
      <div class="field compact">
        <label>Prompt</label>
        <textarea name="promptText-${index}">${escapeHTML(draft.promptText)}</textarea>
      </div>
      <div class="field compact">
        <label>Ideal Answer</label>
        <textarea name="idealAnswer-${index}">${escapeHTML(draft.idealAnswer)}</textarea>
      </div>
      <div class="field compact">
        <label>Grading Criteria</label>
        <textarea name="gradingCriteria-${index}">${escapeHTML(draft.gradingCriteria)}</textarea>
      </div>
      <div class="field">
        <label>Max Points</label>
        <input name="maxPoints-${index}" value="${escapeHTML(draft.maxPointsText)}" />
      </div>
    </div>
  `;
}

function renderBatchUploadModal() {
  return `
    <div class="modal-backdrop">
      <div class="modal-card" style="max-width:720px">
        <div class="modal-header">
          <div>
            <h2>Batch Upload Setup</h2>
            <p class="panel-copy">${ui.modal.filePaths.length} files selected. PDFs should usually use <em>Each file is one submission</em>. Loose page images can be grouped by file count.</p>
          </div>
          <button type="button" class="ghost-button" data-action="close-modal">Close</button>
        </div>
        <div class="modal-body" data-scroll-key="modal-body">
          <form id="batch-upload-form" class="grid-two">
            <input type="hidden" name="sessionId" value="${ui.modal.sessionId}" />
            <div class="detail-pane">
              ${renderSelectField("groupingMode", "Grouping Mode", [
                { label: "Each file is one submission", value: "each-file" },
                { label: "Every N files is one submission", value: "fixed-size" },
              ], ui.modal.groupingMode || "each-file")}
              <div class="field">
                <label>Files Per Submission</label>
                <input name="filesPerSubmission" type="number" min="1" value="${escapeHTML(String(ui.modal.filesPerSubmission || 1))}" />
              </div>
            </div>
            <div class="detail-pane">
              <div class="detail-label">Selected Files</div>
              <div class="list-stack">
                ${ui.modal.filePaths.map((filePath) => `<div class="question-card"><strong>${escapeHTML(fileName(filePath))}</strong><p>${escapeHTML(filePath)}</p></div>`).join("")}
              </div>
            </div>
            <div class="detail-pane" style="grid-column:1 / -1">
              <div class="panel-actions" style="justify-content:flex-end">
                <button type="button" class="ghost-button" data-action="close-modal">Cancel</button>
                <button type="submit" class="primary-button">Continue</button>
              </div>
            </div>
          </form>
        </div>
      </div>
    </div>
  `;
}

function renderDraftReviewModal(session, draft, isExisting) {
  const assets = draft.sourceFiles || draft.assets || [];
  return `
    <div class="modal-backdrop">
      <div class="modal-card">
        <div class="modal-header">
          <div>
            <h2>${isExisting ? "Review Regrade" : "Review Grade"}</h2>
            <p class="panel-copy">Desktop review swaps the sequential mobile layout for a two-pane workspace: scans on the left, editable grading detail on the right.</p>
          </div>
          <button type="button" class="ghost-button" data-action="close-modal">Close</button>
        </div>
        <div class="modal-body" data-scroll-key="modal-body">
          <form id="review-draft-form">
            <input type="hidden" name="sessionId" value="${session.id}" />
            <input type="hidden" name="existingSubmissionId" value="${escapeHTML(draft.existingSubmissionId || "")}" />
            <div class="review-layout">
              <div class="detail-pane">
                <div class="detail-label">Submission Files</div>
                <div class="asset-grid">${renderAssets(assets)}</div>
              </div>
              <div class="detail-pane">
                ${renderSubmissionEditorFields(draft, session.integerPointsOnly)}
              </div>
            </div>
            <div class="modal-footer">
              <button type="button" class="ghost-button" data-action="close-modal">Cancel</button>
              <button type="submit" class="primary-button">Save</button>
            </div>
          </form>
        </div>
      </div>
    </div>
  `;
}

function renderSubmissionDetailModal(session, submissionId) {
  const submission = (session.submissions || []).find((item) => item.id === submissionId);
  if (!submission) {
    return "";
  }

  if (!submission.isProcessingCompleted) {
    return `
      <div class="modal-backdrop">
        <div class="modal-card" style="max-width:920px">
          <div class="modal-header">
            <div>
              <h2>${escapeHTML(submission.listDisplayName)}</h2>
              <p class="panel-copy">Pending and failed submissions stay inspectable even before the final grade exists.</p>
            </div>
            <button type="button" class="ghost-button" data-action="close-modal">Close</button>
          </div>
          <div class="modal-body" data-scroll-key="modal-body">
            <div class="detail-layout">
              <div class="detail-pane">
                <div class="detail-label">Saved Files</div>
                <div class="asset-grid">${renderAssets(submission.assets || [])}</div>
              </div>
              <div class="detail-pane">
                <div class="kv-list">
                  ${kvRow("State", capitalize(submission.processingState))}
                  ${kvRow("Pipeline", submission.batchStage ? capitalize(submission.batchStage) : "None")}
                  ${kvRow("Saved", formatDateTime(submission.createdAt))}
                </div>
                ${submission.processingDetail ? `<div class="detail-section" style="margin-top:18px"><div class="detail-label">Detail</div>${renderMathBlock(submission.processingDetail)}</div>` : ""}
                ${submission.overallNotes ? `<div class="detail-section"><div class="detail-label">Overall Notes</div>${renderMathBlock(submission.overallNotes)}</div>` : ""}
              </div>
            </div>
          </div>
        </div>
      </div>
    `;
  }

  return `
    <div class="modal-backdrop">
      <div class="modal-card">
        <div class="modal-header">
          <div>
            <h2>${escapeHTML(submission.listDisplayName)}</h2>
            <p class="panel-copy">Saved results remain editable. This mirrors the iOS detail view, but the file viewer is fixed beside the scoring form instead of stacked below it.</p>
          </div>
          <div class="panel-actions">
            <button type="button" class="secondary-button" data-action="regrade-submission" data-session-id="${session.id}" data-submission-id="${submission.id}">Regrade</button>
            <button type="button" class="danger-button" data-action="delete-submission" data-session-id="${session.id}" data-submission-id="${submission.id}">Delete</button>
            <button type="button" class="ghost-button" data-action="close-modal">Close</button>
          </div>
        </div>
        <div class="modal-body" data-scroll-key="modal-body">
          <form id="saved-submission-form">
            <input type="hidden" name="sessionId" value="${session.id}" />
            <input type="hidden" name="existingSubmissionId" value="${submission.id}" />
            <div class="review-layout">
              <div class="detail-pane">
                <div class="detail-label">Saved Files</div>
                <div class="asset-grid">${renderAssets(submission.assets || [])}</div>
              </div>
              <div class="detail-pane">
                ${renderSubmissionEditorFields(submission, session.integerPointsOnly)}
              </div>
            </div>
            <div class="modal-footer">
              <button type="button" class="ghost-button" data-action="close-modal">Close</button>
              <button type="submit" class="primary-button">Save Changes</button>
            </div>
          </form>
        </div>
      </div>
    </div>
  `;
}

function renderSubmissionEditorFields(submission, integerPointsOnly) {
  return `
    <div class="field">
      <label>Student Name</label>
      <input name="studentName" value="${escapeHTML(submission.studentName || "")}" />
    </div>
    <div class="boolean-row">
      ${toggleField("nameNeedsReview", "Name Needs Review", Boolean(submission.nameNeedsReview))}
      ${toggleField("needsAttention", "Needs Attention", Boolean(submission.needsAttention))}
      ${toggleField("validationNeedsReview", "Validation Needs Review", Boolean(submission.validationNeedsReview))}
    </div>
    <div class="field compact">
      <label>Attention Reasons</label>
      <textarea name="attentionReasonsText">${escapeHTML(submission.attentionReasonsText || "")}</textarea>
    </div>
    <div class="field compact">
      <label>Overall Notes</label>
      <textarea name="overallNotes">${escapeHTML(submission.overallNotes || "")}</textarea>
    </div>
    <div class="detail-section">
      <div class="detail-label">Total</div>
      <div class="summary-value">${score(submission.totalScore)} / ${score(submission.maxScore)}</div>
      <p class="panel-copy">${integerPointsOnly ? "Integer-points mode is on, so awarded points are normalized to whole numbers." : "Fractional scores are allowed when justified by the rubric."}</p>
    </div>
    <div class="list-stack">
            ${(submission.grades || []).map((grade, index) => `
        <div class="question-card">
          <div class="submission-header">
            <h4>${escapeHTML(grade.displayLabel)}</h4>
            <div class="chip-row">${grade.needsReview ? `<span class="status-chip pending">Needs Review</span>` : ""}</div>
          </div>
          <input type="hidden" name="grade-question-id-${index}" value="${escapeHTML(grade.questionID)}" />
          <input type="hidden" name="grade-display-label-${index}" value="${escapeHTML(grade.displayLabel)}" />
          <div class="grid-two">
            <div class="field">
              <label>Awarded Points</label>
              <input name="grade-awarded-${index}" type="number" step="${integerPointsOnly ? "1" : "0.5"}" min="0" max="${escapeHTML(String(grade.maxPoints))}" value="${escapeHTML(String(grade.awardedPoints))}" />
            </div>
            <div class="field">
              <label>Max Points</label>
              <input name="grade-max-${index}" type="number" step="${integerPointsOnly ? "1" : "0.5"}" min="0" value="${escapeHTML(String(grade.maxPoints))}" />
            </div>
          </div>
          <div class="boolean-row">
            ${toggleField(`grade-answer-${index}`, "Final Answer Correct", Boolean(grade.isAnswerCorrect))}
            ${toggleField(`grade-process-${index}`, "Work Process Correct", Boolean(grade.isProcessCorrect))}
            ${toggleField(`grade-review-${index}`, "Needs Review", Boolean(grade.needsReview))}
          </div>
          <div class="field compact">
            <label>Feedback</label>
            <textarea name="grade-feedback-${index}">${escapeHTML(grade.feedback || "")}</textarea>
          </div>
        </div>
      `).join("")}
    </div>
  `;
}

function renderAssets(assets) {
  if (!assets.length) {
    return `<div class="render-block empty">No files attached.</div>`;
  }

  return assets.map((asset) => `
    <div class="asset-card">
      ${asset.kind === "pdf"
        ? `<embed src="${escapeHTML(asset.previewURL)}#toolbar=0&navpanes=0" type="application/pdf" />`
        : `<img src="${escapeHTML(asset.previewURL)}" alt="${escapeHTML(asset.originalName || "Image asset")}" />`}
      <div class="asset-meta">
        <div class="asset-name">${escapeHTML(asset.originalName || "Saved file")}</div>
        <div class="asset-kind">${asset.kind === "pdf" ? "PDF" : "Image"} • ${formatFileSize(asset.size || 0)}</div>
      </div>
    </div>
  `).join("");
}

function renderMathBlock(text) {
  if (!text || !String(text).trim()) {
    return `<div class="render-block empty">Nothing entered.</div>`;
  }
  return `<div class="render-block math-block">${escapeHTML(String(text)).replace(/\n/g, "<br>")}</div>`;
}

function renderSessionChips(session) {
  const chips = [];
  if (session.isFinished) {
    chips.push(chip("Ended", "info"));
  } else if (session.hasPendingRubricReview) {
    chips.push(chip("Rubric Ready", "queued"));
  } else if (session.submissions.some((submission) => submission.isQueuedForRubric)) {
    chips.push(chip("Scans Queued", "queued"));
  } else if (!session.questions.length) {
    chips.push(chip("Needs Rubric", "pending"));
  } else if (session.submissions.some((submission) => submission.isProcessingPending)) {
    chips.push(chip("Batch Pending", "pending"));
  } else {
    chips.push(chip("Ready", "ready"));
  }
  return chips.join("");
}

function renderSubmissionChips(submission) {
  const chips = [];
  if (submission.isQueuedForRubric) chips.push(chip("Queued", "queued"));
  if (submission.isProcessingPending && !submission.isQueuedForRubric) chips.push(chip("Pending", "pending"));
  if (submission.isProcessingFailed) chips.push(chip("Failed", "failed"));
  if (submission.validationNeedsReviewEnabled) chips.push(chip("Validation Inconclusive", "pending"));
  if (submission.needsAttentionEnabled) chips.push(chip("Needs Attention", "failed"));
  if (submission.nameNeedsReviewEnabled) chips.push(chip("Name Review", "info"));
  if (submission.isProcessingCompleted && submission.hasQuestionNeedingReview) chips.push(chip("Question Review", "pending"));
  return chips.join("");
}

function chip(label, tone) {
  return `<span class="status-chip ${tone}">${escapeHTML(label)}</span>`;
}

function kvRow(label, value) {
  return `<div class="kv-row"><span>${escapeHTML(label)}</span><strong>${escapeHTML(String(value || ""))}</strong></div>`;
}

function renderSelectField(name, label, options, selectedValue) {
  return `
    <div class="field">
      <label>${escapeHTML(label)}</label>
      <select name="${escapeHTML(name)}">
        ${options.map((option) => `
          <option value="${escapeHTML(option.value == null ? "__nil__" : option.value)}" ${normalizeOptionValue(selectedValue) === normalizeOptionValue(option.value) ? "selected" : ""}>
            ${escapeHTML(option.label)}
          </option>
        `).join("")}
      </select>
    </div>
  `;
}

function toggleField(name, label, checked) {
  return `<label class="toggle"><input type="checkbox" name="${escapeHTML(name)}" ${checked ? "checked" : ""} /><span>${escapeHTML(label)}</span></label>`;
}

function normalizeOptionValue(value) {
  return value == null ? "__nil__" : String(value);
}

function installEventDelegates() {
  document.addEventListener("click", handleClick);
  document.addEventListener("submit", handleSubmit);
  document.addEventListener("input", handleInput);
  document.addEventListener("change", handleChange);
  document.addEventListener("dragover", handleDragOver);
  document.addEventListener("drop", handleDrop);
}

async function handleClick(event) {
  const actionEl = event.target.closest("[data-action]");
  if (!actionEl) {
    return;
  }

  const action = actionEl.dataset.action;
  const sessionId = actionEl.dataset.sessionId;
  const submissionId = actionEl.dataset.submissionId;
  event.preventDefault();

  try {
    switch (action) {
      case "open-new-session":
        ui.modal = { type: "new-session" };
        return render();
      case "open-settings":
        ui.modal = { type: "settings" };
        return render();
      case "close-modal":
        ui.modal = null;
        return render();
      case "select-session":
        ui.selectedSessionId = sessionId;
        ui.selectedTab = "overview";
        ui.resultsSearch = "";
        return render();
      case "select-tab":
        ui.selectedTab = actionEl.dataset.tab;
        return render();
      case "open-edit-session": {
        const session = currentSession();
        ui.modal = { type: "edit-session", session: deepClone(session) };
        return render();
      }
      case "choose-master-files":
        if (!snapshot.meta.hasAPIKey) {
          ui.modal = { type: "settings" };
          render();
          showToast("Add your OpenAI API key first.", "info");
          return;
        }
        return chooseAndUploadMaster(sessionId);
      case "choose-single-files":
        return chooseAndGradeSingle(sessionId);
      case "choose-batch-files":
        return chooseAndOpenBatch(sessionId);
      case "open-rubric-review":
        ui.modal = { type: "rubric-review" };
        return render();
      case "apply-default-points":
        return applyDefaultPoints();
      case "view-submission":
        ui.modal = { type: "view-submission", submissionId };
        return render();
      case "refresh-session":
        return withBusy("Refreshing jobs", async () => {
          await window.hgrader.refreshSession(sessionId);
          showToast("Checked pending jobs.", "info");
        });
      case "submit-queued":
        return withBusy("Submitting queued scans", async () => {
          const result = await window.hgrader.submitQueued(sessionId);
          showToast(`Submitted ${result.submitted} queued scan sets for grading.`, "success");
        });
      case "regrade-all":
        return withBusy("Submitting regrade batch", async () => {
          const result = await window.hgrader.regradeAll(sessionId);
          showToast(`Submitted ${result.submitted} saved submissions for regrading.`, "success");
        });
      case "regrade-submission":
        return withBusy("Regrading submission", async () => {
          const result = await window.hgrader.regradeSubmission({ sessionId, submissionId });
          ui.modal = { type: "review-draft", draft: result.draft };
          render();
        });
      case "delete-submission":
        if (!window.confirm("Delete this saved result?")) return;
        return withBusy("Deleting result", async () => {
          await window.hgrader.deleteSubmission({ sessionId, submissionId });
          ui.modal = null;
          showToast("Result deleted.", "info");
        });
      case "delete-session":
        if (!window.confirm("Delete this session and its stored files?")) return;
        return withBusy("Deleting session", async () => {
          await window.hgrader.deleteSession(sessionId);
          ui.modal = null;
          showToast("Session deleted.", "info");
        });
      case "test-api-key":
        return withBusy("Testing API key", async () => {
          await window.hgrader.testAPIKey();
          showToast("API key validated.", "success");
        });
      case "clear-api-key":
        return withBusy("Clearing API key", async () => {
          await window.hgrader.saveAPIKey("");
          showToast("Saved API key removed.", "info");
        });
      case "clear-canvas-token":
        return withBusy("Clearing Canvas token", async () => {
          await window.hgrader.saveCanvasToken("");
          showToast("Saved Canvas token removed.", "info");
        });
      case "fetch-org-cost":
        return withBusy("Fetching organization cost", async () => {
          await window.hgrader.fetchOrganizationCost();
          showToast("Organization cost summary updated.", "success");
        });
      case "export-csv":
        return withBusy("Preparing CSV export", async () => {
          const result = await window.hgrader.exportCSV(sessionId);
          if (!result.canceled) {
            showToast(`CSV exported to ${fileName(result.filePath)}.`, "success");
            await window.hgrader.revealFile(result.filePath);
          }
        });
      case "export-package":
        return withBusy("Preparing full export", async () => {
          const result = await window.hgrader.exportPackage(sessionId);
          if (!result.canceled) {
            showToast(`ZIP exported to ${fileName(result.filePath)}.`, "success");
            await window.hgrader.revealFile(result.filePath);
          }
        });
      case "choose-gradebook-template":
        await syncCanvasConfigFromPage();
        return chooseGradebookTemplate(sessionId);
      case "load-canvas-roster":
        return withBusy("Loading Canvas roster", async () => {
          await syncCanvasConfigFromPage();
          const result = await window.hgrader.loadCanvasRosterFromAPI(sessionId);
          showToast(`Loaded ${result.count} roster entries from Canvas.`, "success");
        });
      case "run-canvas-matching":
        return withBusy("Running matching", async () => {
          await syncCanvasConfigFromPage();
          const result = await window.hgrader.runCanvasMatching(sessionId);
          showToast(`Matching complete: ${result.lockedSummary.matched || 0} matched, ${result.lockedSummary.pending || 0} pending review.`, "success");
        });
      case "export-canvas-gradebook":
        return withBusy("Building Gradebook CSV", async () => {
          await syncCanvasConfigFromPage();
          const result = await window.hgrader.exportCanvasGradebook(sessionId);
          if (!result.canceled) {
            showToast(`Gradebook CSV saved to ${fileName(result.filePath)}.`, "success");
            await window.hgrader.revealFile(result.filePath);
          }
        });
      case "post-canvas-grades":
        return withBusy("Posting Canvas grades", async () => {
          await syncCanvasConfigFromPage();
          const result = await window.hgrader.postCanvasGrades(sessionId);
          showToast(`Canvas grades posted. Progress state: ${result.finalProgress?.workflow_state || "unknown"}.`, "success");
        });
      case "upload-canvas-submissions":
        return withBusy("Uploading PDFs and comments", async () => {
          await syncCanvasConfigFromPage();
          const result = await window.hgrader.uploadCanvasSubmissions(sessionId);
          showToast(`Canvas upload finished: ${result.summary.uploaded || 0} uploaded, ${result.summary.failed || 0} failed.`, "success");
        });
      default:
        break;
    }
  } catch (error) {
    handleError(error);
  }
}

async function handleSubmit(event) {
  const form = event.target;
  event.preventDefault();

  try {
    if (form.id === "new-session-form") {
      const payload = collectSessionForm(form, false);
      await withBusy("Creating session", async () => {
        await window.hgrader.createSession(payload);
      });
      ui.modal = null;
      showToast("Session created.", "success");
      return;
    }

    if (form.id === "edit-session-form") {
      const session = currentSession();
      const payload = collectSessionForm(form, true);
      await withBusy("Saving config", async () => {
        await window.hgrader.updateSession({ ...payload, sessionId: session.id });
      });
      ui.modal = null;
      showToast("Session config saved.", "success");
      return;
    }

    if (form.id === "settings-form") {
      const apiKey = form.elements.apiKey.value;
      const canvasToken = form.elements.canvasToken.value;
      await withBusy("Saving tokens", async () => {
        if (apiKey.trim()) {
          await window.hgrader.saveAPIKey(apiKey);
        }
        if (canvasToken.trim()) {
          await window.hgrader.saveCanvasToken(canvasToken);
        }
      });
      showToast(apiKey.trim() || canvasToken.trim() ? "Token settings saved." : "No token changes submitted.", "success");
      return;
    }

    if (form.id === "rubric-review-form") {
      const payload = collectRubricForm(form);
      await withBusy("Saving rubric", async () => {
        await window.hgrader.saveRubric(payload);
      });
      ui.modal = null;
      showToast("Rubric saved.", "success");
      return;
    }

    if (form.id === "batch-upload-form") {
      const payload = {
        sessionId: form.elements.sessionId.value,
        filePaths: ui.modal.filePaths,
        groupingMode: form.elements.groupingMode.value,
        filesPerSubmission: form.elements.filesPerSubmission.value,
      };
      await withBusy("Preparing batch upload", async () => {
        const result = await window.hgrader.batchUpload(payload);
        showToast(
          result.submitted
            ? `Submitted ${result.submitted} submissions to the OpenAI Batch API.`
            : `Queued ${result.queued} scan sets until the rubric is approved.`,
          "success"
        );
      });
      ui.modal = null;
      return;
    }

    if (form.id === "canvas-config-form") {
      const payload = collectCanvasConfigForm(form);
      await withBusy("Saving Canvas config", async () => {
        await window.hgrader.updateCanvasConfig(payload);
      });
      showToast("Canvas config saved.", "success");
      return;
    }

    if (form.id === "review-draft-form" || form.id === "saved-submission-form") {
      const payload = collectSubmissionReviewForm(form, currentSession());
      if (ui.modal?.draft?.sourceFiles) {
        payload.draft.sourceFiles = ui.modal.draft.sourceFiles;
      }
      await withBusy("Saving submission", async () => {
        await window.hgrader.saveReviewedSubmission(payload);
      });
      ui.modal = null;
      showToast(payload.draft.existingSubmissionId ? "Submission updated." : "Submission saved.", "success");
    }
  } catch (error) {
    handleError(error);
  }
}

function handleInput(event) {
  const actionEl = event.target.closest("[data-action]");
  if (actionEl?.dataset.action === "results-search") {
    ui.resultsSearch = event.target.value;
    render();
  }
}

async function handleChange(event) {
  const actionEl = event.target.closest("[data-action]");
  if (!actionEl) {
    return;
  }

  try {
    if (actionEl.dataset.action === "canvas-match-select") {
      const value = event.target.value;
      const selection = value === "skip"
        ? { decision: "skip", userId: null }
        : value.startsWith("user:")
          ? { decision: "match", userId: Number(value.slice(5)) }
          : { decision: "pending", userId: null };
      await window.hgrader.updateCanvasMatch({
        sessionId: actionEl.dataset.sessionId,
        localSubmissionId: actionEl.dataset.localSubmissionId,
        selection,
      });
    }
  } catch (error) {
    handleError(error);
  }
}

function handleDragOver(event) {
  const zone = event.target.closest(".dropzone[data-upload]");
  if (!zone) {
    return;
  }
  event.preventDefault();
}

async function handleDrop(event) {
  const zone = event.target.closest(".dropzone[data-upload]");
  if (!zone) {
    return;
  }

  event.preventDefault();
  const files = Array.from(event.dataTransfer.files || []).map((file) => file.path).filter(Boolean);
  if (!files.length) {
    return;
  }

  try {
    switch (zone.dataset.upload) {
      case "master":
        return uploadMaster(zone.dataset.sessionId, files);
      case "single":
        return gradeSingle(zone.dataset.sessionId, files);
      case "batch":
        return openBatchModal(zone.dataset.sessionId, files);
      default:
        return undefined;
    }
  } catch (error) {
    handleError(error);
  }
}

async function chooseAndUploadMaster(sessionId) {
  const files = await window.hgrader.selectFiles({ title: "Choose Blank Assignment Files" });
  if (files.length) {
    await uploadMaster(sessionId, files);
  }
}

async function chooseAndGradeSingle(sessionId) {
  const files = await window.hgrader.selectFiles({ title: "Choose Submission Files" });
  if (files.length) {
    await gradeSingle(sessionId, files);
  }
}

async function chooseAndOpenBatch(sessionId) {
  const files = await window.hgrader.selectFiles({ title: "Choose Batch Submission Files" });
  if (files.length) {
    openBatchModal(sessionId, files);
  }
}

async function chooseGradebookTemplate(sessionId) {
  const files = await window.hgrader.selectFiles({
    title: "Choose Canvas Gradebook CSV",
    properties: ["openFile"],
    filters: [{ name: "CSV", extensions: ["csv"] }],
  });
  if (!files.length) {
    return;
  }
  await withBusy("Loading Gradebook CSV", async () => {
    const result = await window.hgrader.loadCanvasGradebookTemplate({ sessionId, csvPath: files[0] });
    showToast(`Loaded Gradebook template with ${result.headers.length} columns and ${result.count} roster entries.`, "success");
  });
}

function openBatchModal(sessionId, filePaths) {
  ui.modal = {
    type: "batch-upload",
    sessionId,
    filePaths,
    groupingMode: filePaths.some((file) => file.toLowerCase().endsWith(".pdf")) ? "each-file" : "each-file",
    filesPerSubmission: 1,
  };
  render();
}

async function uploadMaster(sessionId, filePaths) {
  await withBusy("Submitting answer key", async () => {
    await window.hgrader.uploadMaster({ sessionId, filePaths });
  });
  showToast("Answer key submitted. HGrader will keep checking until it is ready.", "success");
}

async function gradeSingle(sessionId, filePaths) {
  await withBusy("Grading submission", async () => {
    const result = await window.hgrader.gradeSingle({ sessionId, filePaths });
    ui.modal = { type: "review-draft", draft: result.draft };
    render();
  });
}

async function syncCanvasConfigFromPage() {
  const form = document.getElementById("canvas-config-form");
  if (!form) {
    return;
  }
  await window.hgrader.updateCanvasConfig(collectCanvasConfigForm(form));
}

function applyDefaultPoints() {
  const form = document.getElementById("rubric-review-form");
  if (!form) return;
  const value = form.elements.defaultPoints.value;
  const inputs = Array.from(form.querySelectorAll('input[name^="maxPoints-"]'));
  for (const input of inputs) {
    input.value = value;
  }
}

function collectSessionForm(form, editing) {
  return {
    title: editing ? currentSession().title : form.elements.title.value,
    answerModelID: form.elements.answerModelID.value,
    gradingModelID: form.elements.gradingModelID.value,
    validationModelID: form.elements.validationModelID.value,
    validationEnabled: form.elements.validationEnabled.checked,
    integerPointsOnly: form.elements.integerPointsOnly.checked,
    relaxedGradingMode: form.elements.relaxedGradingMode.checked,
    isFinished: form.elements.isFinished ? form.elements.isFinished.checked : false,
    answerReasoningEffort: optionValue(form.elements.answerReasoningEffort.value),
    gradingReasoningEffort: optionValue(form.elements.gradingReasoningEffort.value),
    validationReasoningEffort: optionValue(form.elements.validationReasoningEffort.value),
    answerVerbosity: optionValue(form.elements.answerVerbosity.value),
    gradingVerbosity: optionValue(form.elements.gradingVerbosity.value),
    validationVerbosity: optionValue(form.elements.validationVerbosity.value),
    answerServiceTier: optionValue(form.elements.answerServiceTier.value),
    gradingServiceTier: optionValue(form.elements.gradingServiceTier.value),
    validationServiceTier: optionValue(form.elements.validationServiceTier.value),
    validationMaxAttempts: form.elements.validationMaxAttempts.value,
  };
}

function collectRubricForm(form) {
  const sessionId = form.elements.sessionId.value;
  const drafts = [];
  let index = 0;
  while (form.elements[`questionID-${index}`]) {
    drafts.push({
      questionID: form.elements[`questionID-${index}`].value,
      displayLabel: form.elements[`displayLabel-${index}`].value,
      promptText: form.elements[`promptText-${index}`].value,
      idealAnswer: form.elements[`idealAnswer-${index}`].value,
      gradingCriteria: form.elements[`gradingCriteria-${index}`].value,
      maxPointsText: form.elements[`maxPoints-${index}`].value,
    });
    index += 1;
  }
  return {
    sessionId,
    overallRules: form.elements.overallRules.value,
    questionDrafts: drafts,
  };
}

function collectSubmissionReviewForm(form, session) {
  const grades = [];
  let index = 0;
  while (form.elements[`grade-awarded-${index}`]) {
    grades.push({
      questionID: form.elements[`grade-question-id-${index}`].value,
      displayLabel: form.elements[`grade-display-label-${index}`].value,
      awardedPoints: Number(form.elements[`grade-awarded-${index}`].value || 0),
      maxPoints: Number(form.elements[`grade-max-${index}`].value || 0),
      isAnswerCorrect: form.elements[`grade-answer-${index}`].checked,
      isProcessCorrect: form.elements[`grade-process-${index}`].checked,
      needsReview: form.elements[`grade-review-${index}`].checked,
      feedback: form.elements[`grade-feedback-${index}`].value,
    });
    index += 1;
  }

  return {
    sessionId: form.elements.sessionId.value,
    draft: {
      existingSubmissionId: form.elements.existingSubmissionId.value || null,
      studentName: form.elements.studentName.value,
      nameNeedsReview: form.elements.nameNeedsReview.checked,
      needsAttention: form.elements.needsAttention.checked,
      validationNeedsReview: form.elements.validationNeedsReview.checked,
      attentionReasonsText: form.elements.attentionReasonsText.value,
      overallNotes: form.elements.overallNotes.value,
      grades,
    },
  };
}

function collectCanvasConfigForm(form) {
  return {
    sessionId: form.elements.sessionId.value,
    config: {
      canvasBaseUrl: form.elements.canvasBaseUrl.value,
      courseId: form.elements.courseId.value,
      assignmentId: form.elements.assignmentId.value,
      assignmentColumn: form.elements.assignmentColumn.value,
      gradebookTemplatePath: form.elements.gradebookTemplatePath.value,
      matchAutoAcceptScore: form.elements.matchAutoAcceptScore.value,
      matchReviewFloor: form.elements.matchReviewFloor.value,
      matchMargin: form.elements.matchMargin.value,
      enforceManualPostPolicy: form.elements.enforceManualPostPolicy.checked,
      uploadAttachPdfAsComment: form.elements.uploadAttachPdfAsComment.checked,
      uploadPostGrade: form.elements.uploadPostGrade.checked,
      uploadCommentEnabled: form.elements.uploadCommentEnabled.checked,
      uploadCommentIncludeTotalScore: form.elements.uploadCommentIncludeTotalScore.checked,
      uploadCommentIncludeQuestionScores: form.elements.uploadCommentIncludeQuestionScores.checked,
      uploadCommentIncludeIndividualNotes: form.elements.uploadCommentIncludeIndividualNotes.checked,
      uploadCommentIncludeOverallNotes: form.elements.uploadCommentIncludeOverallNotes.checked,
      requestTimeoutSeconds: form.elements.requestTimeoutSeconds.value,
    },
  };
}

function optionValue(value) {
  return value === "__nil__" ? null : value;
}

async function withBusy(title, task) {
  ui.busy = { title, detail: "Working..." };
  render();
  try {
    await task();
  } finally {
    ui.busy = null;
    render();
  }
}

function showToast(message, tone = "info") {
  ui.toast = { message, tone };
  render();
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => {
    ui.toast = null;
    render();
  }, 2400);
}

function handleError(error) {
  console.error(error);
  ui.busy = null;
  showToast(error.message || String(error), "error");
}

function hydrateMath() {
  if (window.MathJax?.typesetPromise) {
    window.MathJax.typesetPromise(Array.from(document.querySelectorAll(".math-block"))).catch(() => {});
  }
}

function currentSession() {
  return (snapshot.state.sessions || []).find((session) => session.id === ui.selectedSessionId);
}

function captureScrollPositions() {
  const nodes = document.querySelectorAll("[data-scroll-key]");
  for (const node of nodes) {
    ui.scrollPositions[node.dataset.scrollKey] = {
      top: node.scrollTop,
      left: node.scrollLeft,
    };
  }
}

function restoreScrollPositions() {
  requestAnimationFrame(() => {
    const nodes = document.querySelectorAll("[data-scroll-key]");
    for (const node of nodes) {
      const saved = ui.scrollPositions[node.dataset.scrollKey];
      if (!saved) {
        continue;
      }
      node.scrollTop = saved.top;
      node.scrollLeft = saved.left;
    }
  });
}

function completedSubmissions(session) {
  return (session.submissions || []).filter((submission) => submission.isProcessingCompleted);
}

function summarizeStatuses(rows) {
  const summary = {};
  for (const row of rows || []) {
    summary[row.status] = (summary[row.status] || 0) + 1;
  }
  return summary;
}

function pendingLabel(submission) {
  if (submission.isQueuedForRubric) return "Queued";
  if (submission.isProcessingPending) return "Pending";
  return "Failed";
}

function canRegradeAll(session) {
  return snapshot.meta.hasAPIKey &&
    session.questions.length &&
    !(session.submissions || []).some((submission) => submission.isAwaitingRemoteProcessing) &&
    session.submissions.length;
}

function canSubmitQueued(session) {
  return snapshot.meta.hasAPIKey &&
    session.questions.length &&
    !(session.submissions || []).some((submission) => submission.isAwaitingRemoteProcessing);
}

function DEFAULTS() {
  return snapshot.meta.defaults;
}

function score(value) {
  const numeric = Number(value || 0);
  return Number.isInteger(numeric) ? String(numeric) : numeric.toFixed(2).replace(/\.?0+$/, "");
}

function currency(value) {
  return new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" }).format(Number(value || 0));
}

function formatDateTime(value) {
  return new Date(value).toLocaleString([], {
    year: "numeric",
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  });
}

function formatFileSize(value) {
  const size = Number(value || 0);
  if (size < 1024) return `${size} B`;
  if (size < 1024 * 1024) return `${(size / 1024).toFixed(1)} KB`;
  return `${(size / (1024 * 1024)).toFixed(1)} MB`;
}

function fileName(filePath) {
  return String(filePath).split(/[\\/]/).pop() || filePath;
}

function capitalize(value) {
  const text = String(value || "");
  return text ? text.charAt(0).toUpperCase() + text.slice(1) : text;
}

function escapeHTML(value) {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}
