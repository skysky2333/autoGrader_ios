"use strict";

const fs = require("node:fs/promises");
const os = require("node:os");
const path = require("node:path");

const {
  escapeCSV,
  questionGradeLookup,
  safeName,
  scoreString,
} = require("./shared");

function createSessionCSV(session) {
  const questions = [...(session.questions || [])].sort((a, b) => a.orderIndex - b.orderIndex);
  const headers = ["Student Name", "Status", "Processing Detail", "Total Score", "Max Score", "Reviewed", "Saved At"].concat(
    questions.map((question) => question.displayLabel)
  );
  const rows = (session.submissions || [])
    .slice()
    .sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)))
    .map((submission) => {
      const grades = submission.grades || [];
      const values = [
        submission.studentName?.trim() || "Unnamed Student",
        capitalize(submission.processingState || "completed"),
        submission.processingDetail || "",
        scoreString(submission.totalScore || 0),
        scoreString(submission.maxScore || 0),
        submission.teacherReviewed ? "Yes" : "No",
        submission.createdAt || "",
      ].concat(
        questions.map((question) => {
          const grade = questionGradeLookup(question.questionID, question.displayLabel, grades);
          return grade ? `${scoreString(grade.awardedPoints)}/${scoreString(grade.maxPoints)}` : "";
        })
      );
      return values.map(escapeCSV).join(",");
    });

  return [headers.map(escapeCSV).join(","), ...rows].join("\n");
}

async function writeCSVTempFile(session) {
  const timestamp = new Date().toISOString().replace(/:/g, "-");
  const fileName = `${safeName(session.title, "session")}-${timestamp}.csv`;
  const filePath = path.join(os.tmpdir(), fileName);
  await fs.writeFile(filePath, createSessionCSV(session), "utf8");
  return filePath;
}

async function writeSessionPackageZip(session, assetRootDir) {
  const timestamp = new Date().toISOString().replace(/:/g, "-");
  const rootName = `${safeName(session.title, "session")}-${timestamp}`;
  const zipPath = path.join(os.tmpdir(), `${rootName}.zip`);
  const entries = [];

  entries.push({
    name: `${rootName}/session.csv`,
    data: Buffer.from(createSessionCSV(session), "utf8"),
  });

  entries.push({
    name: `${rootName}/rubric.json`,
    data: Buffer.from(JSON.stringify(sortedQuestions(session), null, 2), "utf8"),
  });

  entries.push({
    name: `${rootName}/session-summary.json`,
    data: Buffer.from(
      JSON.stringify(
        {
          title: session.title,
          createdAt: session.createdAt,
          answerModelID: session.answerModelID,
          gradingModelID: session.gradingModelID,
          overallGradingRules: session.overallGradingRules || null,
          questionCount: (session.questions || []).length,
          submissionCount: (session.submissions || []).length,
          totalPoints: sortedQuestions(session).reduce((sum, question) => sum + Number(question.maxPoints || 0), 0),
          estimatedCostUSD: session.estimatedCostUSD ?? null,
          integerPointsOnly: Boolean(session.integerPointsOnly),
        },
        null,
        2
      ),
      "utf8"
    ),
  });

  await addAssets(entries, `${rootName}/master_scans`, session.masterAssets || [], assetRootDir);

  for (const submission of sortedSubmissions(session)) {
    const childName = `${safeName(submission.studentName?.trim() || "submission", "submission")}-${String(submission.id).slice(0, 8)}`;
    const childRoot = `${rootName}/submissions/${childName}`;
    entries.push({
      name: `${childRoot}/summary.json`,
      data: Buffer.from(
        JSON.stringify(
          {
            id: submission.id,
            studentName: submission.studentName,
            processingState: submission.processingState,
            processingDetail: submission.processingDetail || null,
            nameNeedsReview: Boolean(submission.nameNeedsReview),
            createdAt: submission.createdAt,
            teacherReviewed: Boolean(submission.teacherReviewed),
            totalScore: submission.totalScore,
            maxScore: submission.maxScore,
            overallNotes: submission.overallNotes || "",
            grades: submission.grades || [],
          },
          null,
          2
        ),
        "utf8"
      ),
    });
    await addAssets(entries, `${childRoot}/scans`, submission.assets || [], assetRootDir);
  }

  await fs.writeFile(zipPath, buildZip(entries));
  return zipPath;
}

async function addAssets(entries, baseName, assets, assetRootDir) {
  const list = Array.isArray(assets) ? assets : [];
  for (let index = 0; index < list.length; index += 1) {
    const asset = list[index];
    const ext = extensionForAsset(asset);
    const fileName = `page-${index + 1}.${ext}`;
    const absolutePath = path.join(assetRootDir, asset.storedPath);
    const data = await fs.readFile(absolutePath);
    entries.push({
      name: `${baseName}/${fileName}`,
      data,
      mtime: asset.createdAt ? new Date(asset.createdAt) : new Date(),
    });
  }
}

function extensionForAsset(asset) {
  if (asset.kind === "pdf") {
    return "pdf";
  }
  const ext = path.extname(asset.originalName || "").replace(/^\./, "").toLowerCase();
  return ext || "jpg";
}

function sortedQuestions(session) {
  return [...(session.questions || [])].sort((a, b) => a.orderIndex - b.orderIndex);
}

function sortedSubmissions(session) {
  return [...(session.submissions || [])].sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)));
}

function capitalize(value) {
  const text = String(value || "");
  return text ? text.charAt(0).toUpperCase() + text.slice(1) : text;
}

function buildZip(entries) {
  const normalizedEntries = entries
    .map((entry) => ({
      name: entry.name.replace(/\\/g, "/"),
      data: Buffer.isBuffer(entry.data) ? entry.data : Buffer.from(entry.data),
      mtime: entry.mtime || new Date(),
    }))
    .sort((a, b) => a.name.localeCompare(b.name));

  const localFileHeaderSignature = 0x04034b50;
  const centralDirectoryHeaderSignature = 0x02014b50;
  const endOfCentralDirectorySignature = 0x06054b50;
  const centralDirectoryParts = [];
  const fileParts = [];
  let offset = 0;

  for (const entry of normalizedEntries) {
    const fileNameBuffer = Buffer.from(entry.name, "utf8");
    const dos = dosDateTime(entry.mtime);
    const crc = crc32(entry.data);

    const localHeader = Buffer.alloc(30);
    localHeader.writeUInt32LE(localFileHeaderSignature, 0);
    localHeader.writeUInt16LE(20, 4);
    localHeader.writeUInt16LE(0, 6);
    localHeader.writeUInt16LE(0, 8);
    localHeader.writeUInt16LE(dos.time, 10);
    localHeader.writeUInt16LE(dos.date, 12);
    localHeader.writeUInt32LE(crc, 14);
    localHeader.writeUInt32LE(entry.data.length, 18);
    localHeader.writeUInt32LE(entry.data.length, 22);
    localHeader.writeUInt16LE(fileNameBuffer.length, 26);
    localHeader.writeUInt16LE(0, 28);

    fileParts.push(localHeader, fileNameBuffer, entry.data);

    const centralHeader = Buffer.alloc(46);
    centralHeader.writeUInt32LE(centralDirectoryHeaderSignature, 0);
    centralHeader.writeUInt16LE(20, 4);
    centralHeader.writeUInt16LE(20, 6);
    centralHeader.writeUInt16LE(0, 8);
    centralHeader.writeUInt16LE(0, 10);
    centralHeader.writeUInt16LE(dos.time, 12);
    centralHeader.writeUInt16LE(dos.date, 14);
    centralHeader.writeUInt32LE(crc, 16);
    centralHeader.writeUInt32LE(entry.data.length, 20);
    centralHeader.writeUInt32LE(entry.data.length, 24);
    centralHeader.writeUInt16LE(fileNameBuffer.length, 28);
    centralHeader.writeUInt16LE(0, 30);
    centralHeader.writeUInt16LE(0, 32);
    centralHeader.writeUInt16LE(0, 34);
    centralHeader.writeUInt16LE(0, 36);
    centralHeader.writeUInt32LE(0, 38);
    centralHeader.writeUInt32LE(offset, 42);
    centralDirectoryParts.push(centralHeader, fileNameBuffer);

    offset += localHeader.length + fileNameBuffer.length + entry.data.length;
  }

  const centralDirectory = Buffer.concat(centralDirectoryParts);
  const endRecord = Buffer.alloc(22);
  endRecord.writeUInt32LE(endOfCentralDirectorySignature, 0);
  endRecord.writeUInt16LE(0, 4);
  endRecord.writeUInt16LE(0, 6);
  endRecord.writeUInt16LE(normalizedEntries.length, 8);
  endRecord.writeUInt16LE(normalizedEntries.length, 10);
  endRecord.writeUInt32LE(centralDirectory.length, 12);
  endRecord.writeUInt32LE(offset, 16);
  endRecord.writeUInt16LE(0, 20);

  return Buffer.concat([...fileParts, centralDirectory, endRecord]);
}

function dosDateTime(date) {
  const value = date instanceof Date ? date : new Date(date);
  const year = Math.max(value.getFullYear() - 1980, 0);
  const month = value.getMonth() + 1;
  const day = value.getDate();
  const hour = value.getHours();
  const minute = value.getMinutes();
  const second = Math.floor(value.getSeconds() / 2);
  return {
    time: (hour << 11) | (minute << 5) | second,
    date: (year << 9) | (month << 5) | day,
  };
}

const CRC32_TABLE = (() => {
  const table = [];
  for (let index = 0; index < 256; index += 1) {
    let value = index;
    for (let bit = 0; bit < 8; bit += 1) {
      if (value & 1) {
        value = 0xedb88320 ^ (value >>> 1);
      } else {
        value >>>= 1;
      }
    }
    table.push(value >>> 0);
  }
  return table;
})();

function crc32(buffer) {
  let crc = 0xffffffff;
  for (const byte of buffer) {
    const index = (crc ^ byte) & 0xff;
    crc = CRC32_TABLE[index] ^ (crc >>> 8);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

module.exports = {
  createSessionCSV,
  writeCSVTempFile,
  writeSessionPackageZip,
};
