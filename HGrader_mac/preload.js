"use strict";

const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("hgrader", {
  getSnapshot: () => ipcRenderer.invoke("app:snapshot"),
  onStateUpdated: (callback) => {
    const listener = (_event, snapshot) => callback(snapshot);
    ipcRenderer.on("state:updated", listener);
    return () => ipcRenderer.removeListener("state:updated", listener);
  },
  selectFiles: (options) => ipcRenderer.invoke("app:select-files", options),
  revealFile: (filePath) => ipcRenderer.invoke("app:reveal-file", filePath),
  createSession: (payload) => ipcRenderer.invoke("session:create", payload),
  updateSession: (payload) => ipcRenderer.invoke("session:update", payload),
  deleteSession: (sessionId) => ipcRenderer.invoke("session:delete", sessionId),
  saveAPIKey: (apiKey) => ipcRenderer.invoke("settings:save-api-key", apiKey),
  saveCanvasToken: (token) => ipcRenderer.invoke("settings:save-canvas-token", token),
  testAPIKey: () => ipcRenderer.invoke("settings:test-api-key"),
  fetchOrganizationCost: () => ipcRenderer.invoke("settings:fetch-org-cost"),
  uploadMaster: (payload) => ipcRenderer.invoke("session:upload-master", payload),
  saveRubric: (payload) => ipcRenderer.invoke("session:save-rubric", payload),
  batchUpload: (payload) => ipcRenderer.invoke("session:batch-upload", payload),
  gradeSingle: (payload) => ipcRenderer.invoke("session:grade-single", payload),
  regradeSubmission: (payload) => ipcRenderer.invoke("submission:regrade", payload),
  saveReviewedSubmission: (payload) => ipcRenderer.invoke("submission:save-review", payload),
  deleteSubmission: (payload) => ipcRenderer.invoke("submission:delete", payload),
  regradeAll: (sessionId) => ipcRenderer.invoke("session:regrade-all", sessionId),
  submitQueued: (sessionId) => ipcRenderer.invoke("session:submit-queued", sessionId),
  refreshSession: (sessionId) => ipcRenderer.invoke("session:refresh", sessionId),
  exportCSV: (sessionId) => ipcRenderer.invoke("session:export-csv", sessionId),
  exportPackage: (sessionId) => ipcRenderer.invoke("session:export-package", sessionId),
  updateCanvasConfig: (payload) => ipcRenderer.invoke("canvas:update-config", payload),
  loadCanvasRosterFromAPI: (sessionId) => ipcRenderer.invoke("canvas:load-roster-api", sessionId),
  loadCanvasGradebookTemplate: (payload) => ipcRenderer.invoke("canvas:load-gradebook-template", payload),
  runCanvasMatching: (sessionId) => ipcRenderer.invoke("canvas:run-matching", sessionId),
  updateCanvasMatch: (payload) => ipcRenderer.invoke("canvas:update-match", payload),
  exportCanvasGradebook: (sessionId) => ipcRenderer.invoke("canvas:export-gradebook", sessionId),
  postCanvasGrades: (sessionId) => ipcRenderer.invoke("canvas:post-grades", sessionId),
  uploadCanvasSubmissions: (sessionId) => ipcRenderer.invoke("canvas:upload-submissions", sessionId),
});
