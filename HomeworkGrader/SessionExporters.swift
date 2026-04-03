import Foundation

enum SessionExporter {
    static func temporaryPackageURL(for session: GradingSession) throws -> URL {
        let timestamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let rootName = "\(safeName(session.title))-\(timestamp)"
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(rootName, isDirectory: true)
        let zipURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(rootName).zip")

        if FileManager.default.fileExists(atPath: rootURL.path) {
            try FileManager.default.removeItem(at: rootURL)
        }
        if FileManager.default.fileExists(atPath: zipURL.path) {
            try FileManager.default.removeItem(at: zipURL)
        }

        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let csvURL = rootURL.appendingPathComponent("session.csv")
        try CSVExporter.csvString(for: session).write(to: csvURL, atomically: true, encoding: .utf8)

        let rubricURL = rootURL.appendingPathComponent("rubric.json")
        let rubricData = try JSONEncoder.prettyPrinted.encode(session.sortedQuestions.map(\.snapshot))
        try rubricData.write(to: rubricURL)

        let summaryURL = rootURL.appendingPathComponent("session-summary.json")
        let summary = SessionPackageSummary(
            title: session.title,
            createdAt: session.createdAt,
            answerModelID: session.answerModelID,
            gradingModelID: session.gradingModelID,
            overallGradingRules: session.overallGradingRules,
            questionCount: session.sortedQuestions.count,
            submissionCount: session.sortedSubmissions.count,
            totalPoints: session.totalPossiblePoints,
            estimatedCostUSD: session.estimatedCostUSD,
            integerPointsOnly: session.integerPointsOnlyEnabled
        )
        try JSONEncoder.prettyPrinted.encode(summary).write(to: summaryURL)

        let masterDir = rootURL.appendingPathComponent("master_scans", isDirectory: true)
        try FileManager.default.createDirectory(at: masterDir, withIntermediateDirectories: true)
        if let masterScanFileURLs = session.masterScanFileURLs() {
            try copyPages(from: masterScanFileURLs, to: masterDir)
        } else {
            for (index, data) in session.masterScans().enumerated() {
                try data.write(to: masterDir.appendingPathComponent("page-\(index + 1).jpg"))
            }
        }

        let submissionsDir = rootURL.appendingPathComponent("submissions", isDirectory: true)
        try FileManager.default.createDirectory(at: submissionsDir, withIntermediateDirectories: true)

        for submission in session.sortedSubmissions {
            let childName = "\(safeName(submission.listDisplayName))-\(submission.id.uuidString.prefix(8))"
            let childDir = submissionsDir.appendingPathComponent(childName, isDirectory: true)
            try FileManager.default.createDirectory(at: childDir, withIntermediateDirectories: true)

            let stored = StoredSubmissionSummary(
                id: submission.id,
                studentName: submission.studentName,
                processingState: submission.processingState.rawValue,
                processingDetail: submission.processingDetail,
                nameNeedsReview: submission.nameNeedsReviewEnabled,
                createdAt: submission.createdAt,
                teacherReviewed: submission.teacherReviewed,
                totalScore: submission.totalScore,
                maxScore: submission.maxScore,
                overallNotes: submission.overallNotes,
                grades: submission.questionGrades()
            )
            try JSONEncoder.prettyPrinted.encode(stored).write(to: childDir.appendingPathComponent("summary.json"))

            let scansDir = childDir.appendingPathComponent("scans", isDirectory: true)
            try FileManager.default.createDirectory(at: scansDir, withIntermediateDirectories: true)
            if let scanFileURLs = submission.scanFileURLs() {
                try copyPages(from: scanFileURLs, to: scansDir)
            } else {
                for (index, data) in submission.scans().enumerated() {
                    try data.write(to: scansDir.appendingPathComponent("page-\(index + 1).jpg"))
                }
            }
        }

        try SimpleZipWriter.createZip(fromDirectory: rootURL, to: zipURL)
        return zipURL
    }

    private static func safeName(_ value: String) -> String {
        let invalid = CharacterSet.alphanumerics.union(.whitespaces).inverted
        let cleaned = value.components(separatedBy: invalid).joined(separator: "")
            .replacingOccurrences(of: " ", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return cleaned.isEmpty ? "session" : cleaned
    }

    private static func copyPages(from sourceFileURLs: [URL], to directoryURL: URL) throws {
        for (index, sourceFileURL) in sourceFileURLs.enumerated() {
            let pathExtension = sourceFileURL.pathExtension.isEmpty ? "jpg" : sourceFileURL.pathExtension
            let destinationURL = directoryURL.appendingPathComponent(
                String(format: "page-%d.%@", index + 1, pathExtension)
            )
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: sourceFileURL, to: destinationURL)
        }
    }
}

private enum SimpleZipWriter {
    private static let localFileHeaderSignature: UInt32 = 0x04034b50
    private static let centralDirectoryHeaderSignature: UInt32 = 0x02014b50
    private static let endOfCentralDirectorySignature: UInt32 = 0x06054b50

    static func createZip(fromDirectory directoryURL: URL, to zipURL: URL) throws {
        let fileManager = FileManager.default
        let fileURLs = try fileManager
            .subpathsOfDirectory(atPath: directoryURL.path)
            .map { directoryURL.appendingPathComponent($0) }
            .filter { url in
                var isDirectory: ObjCBool = false
                fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
                return !isDirectory.boolValue
            }
            .sorted { $0.path < $1.path }

        var centralDirectory = Data()
        var entryCount: UInt16 = 0
        var currentOffset: UInt32 = 0
        FileManager.default.createFile(atPath: zipURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: zipURL)
        defer { try? handle.close() }

        for fileURL in fileURLs {
            let relativePath = directoryURL.lastPathComponent + "/" + fileURL.path.replacingOccurrences(of: directoryURL.path + "/", with: "")
            let fileNameData = Data(relativePath.utf8)
            let fileData = try Data(contentsOf: fileURL)
            let crc = CRC32.checksum(fileData)
            let modDate = try fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .now
            let dos = DOSDateTime(date: modDate)
            let localHeaderOffset = currentOffset

            var localHeader = Data()
            localHeader.appendLE(localFileHeaderSignature)
            localHeader.appendLE(UInt16(20))
            localHeader.appendLE(UInt16(0))
            localHeader.appendLE(UInt16(0))
            localHeader.appendLE(dos.time)
            localHeader.appendLE(dos.date)
            localHeader.appendLE(crc)
            localHeader.appendLE(UInt32(fileData.count))
            localHeader.appendLE(UInt32(fileData.count))
            localHeader.appendLE(UInt16(fileNameData.count))
            localHeader.appendLE(UInt16(0))
            localHeader.append(fileNameData)
            try handle.write(contentsOf: localHeader)
            try handle.write(contentsOf: fileData)

            currentOffset += UInt32(localHeader.count + fileData.count)

            var centralEntry = Data()
            centralEntry.appendLE(centralDirectoryHeaderSignature)
            centralEntry.appendLE(UInt16(20))
            centralEntry.appendLE(UInt16(20))
            centralEntry.appendLE(UInt16(0))
            centralEntry.appendLE(UInt16(0))
            centralEntry.appendLE(dos.time)
            centralEntry.appendLE(dos.date)
            centralEntry.appendLE(crc)
            centralEntry.appendLE(UInt32(fileData.count))
            centralEntry.appendLE(UInt32(fileData.count))
            centralEntry.appendLE(UInt16(fileNameData.count))
            centralEntry.appendLE(UInt16(0))
            centralEntry.appendLE(UInt16(0))
            centralEntry.appendLE(UInt16(0))
            centralEntry.appendLE(UInt16(0))
            centralEntry.appendLE(UInt32(0))
            centralEntry.appendLE(localHeaderOffset)
            centralEntry.append(fileNameData)
            centralDirectory.append(centralEntry)

            entryCount += 1
        }

        let centralDirectoryOffset = currentOffset
        try handle.write(contentsOf: centralDirectory)

        var endOfCentralDirectory = Data()
        endOfCentralDirectory.appendLE(endOfCentralDirectorySignature)
        endOfCentralDirectory.appendLE(UInt16(0))
        endOfCentralDirectory.appendLE(UInt16(0))
        endOfCentralDirectory.appendLE(entryCount)
        endOfCentralDirectory.appendLE(entryCount)
        endOfCentralDirectory.appendLE(UInt32(centralDirectory.count))
        endOfCentralDirectory.appendLE(centralDirectoryOffset)
        endOfCentralDirectory.appendLE(UInt16(0))
        try handle.write(contentsOf: endOfCentralDirectory)
    }
}

private struct DOSDateTime {
    let time: UInt16
    let date: UInt16

    init(date: Date) {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max((components.year ?? 1980) - 1980, 0)
        let month = components.month ?? 1
        let day = components.day ?? 1
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        let second = (components.second ?? 0) / 2

        self.time = UInt16((hour << 11) | (minute << 5) | second)
        self.date = UInt16((year << 9) | (month << 5) | day)
    }
}

private enum CRC32 {
    private static let table: [UInt32] = {
        (0..<256).map { index in
            var value = UInt32(index)
            for _ in 0..<8 {
                if value & 1 == 1 {
                    value = 0xEDB88320 ^ (value >> 1)
                } else {
                    value >>= 1
                }
            }
            return value
        }
    }()

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = table[index] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { rawBuffer in
            append(rawBuffer.bindMemory(to: UInt8.self))
        }
    }

    mutating func appendLE(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { rawBuffer in
            append(rawBuffer.bindMemory(to: UInt8.self))
        }
    }
}

enum CSVExporter {
    static func csvString(for session: GradingSession) -> String {
        let questions = session.sortedQuestions
        let headers = ["Student Name", "Status", "Processing Detail", "Total Score", "Max Score", "Reviewed", "Saved At"] + questions.map(\.displayLabel)
        let headerLine = headers.map(escapeCSV).joined(separator: ",")

        let rows = session.sortedSubmissions.map { submission in
            let gradeByQuestion = Dictionary(uniqueKeysWithValues: submission.questionGrades().map { ($0.questionID, $0) })
            let values = [
                submission.listDisplayName,
                submission.processingState.rawValue.capitalized,
                submission.processingDetail ?? "",
                formatCSVScore(submission.totalScore),
                formatCSVScore(submission.maxScore),
                submission.teacherReviewed ? "Yes" : "No",
                ISO8601DateFormatter().string(from: submission.createdAt),
            ] + questions.map { question in
                if let grade = gradeByQuestion[question.questionID] {
                    return "\(formatCSVScore(grade.awardedPoints))/\(formatCSVScore(grade.maxPoints))"
                }
                return ""
            }

            return values.map(escapeCSV).joined(separator: ",")
        }

        return ([headerLine] + rows).joined(separator: "\n")
    }

    static func temporaryFileURL(for session: GradingSession) throws -> URL {
        let timestamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let sanitizedTitle = session.title.replacingOccurrences(of: "/", with: "-")
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(sanitizedTitle)-\(timestamp).csv")
        try csvString(for: session).write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    private static func escapeCSV(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private static func formatCSVScore(_ value: Double) -> String {
        ScoreFormatting.scoreString(value)
    }
}

private struct SessionPackageSummary: Codable {
    let title: String
    let createdAt: Date
    let answerModelID: String
    let gradingModelID: String
    let overallGradingRules: String?
    let questionCount: Int
    let submissionCount: Int
    let totalPoints: Double
    let estimatedCostUSD: Double?
    let integerPointsOnly: Bool
}

private struct StoredSubmissionSummary: Codable {
    let id: UUID
    let studentName: String
    let processingState: String
    let processingDetail: String?
    let nameNeedsReview: Bool
    let createdAt: Date
    let teacherReviewed: Bool
    let totalScore: Double
    let maxScore: Double
    let overallNotes: String
    let grades: [QuestionGradeRecord]
}

enum ScoreFormatting {
    static func scoreString(_ value: Double) -> String {
        if value.rounded(.towardZero) == value {
            return String(Int(value))
        }

        return value.formatted(.number.precision(.fractionLength(0...2)))
    }
}

extension JSONEncoder {
    static var prettyPrinted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
