import Foundation

enum ArchiveDecodeCache {
    private static let lock = NSLock()
    private static var pageEntries: [String: PageCacheEntry] = [:]
    private static var gradeEntries: [String: GradeCacheEntry] = [:]

    private struct PageCacheEntry {
        var pages: [Data]?
        let fileURLs: [URL]?
    }

    private struct GradeCacheEntry {
        var grades: [QuestionGradeRecord]?
        let fileURL: URL?
        var hasQuestionNeedingReview: Bool?
    }

    static func pages(ownerID: UUID, archive: Data?) -> [Data] {
        let key = cacheKey(ownerID: ownerID, archive: archive)
        let entry = cachedPageEntry(for: key, archive: archive)
        if let pages = entry.pages {
            return pages
        }
        guard let fileURLs = entry.fileURLs else { return [] }

        let loadedPages = fileURLs.compactMap { fileURL in
            try? Data(contentsOf: fileURL, options: .mappedIfSafe)
        }
        lock.lock()
        if var cachedEntry = pageEntries[key] {
            cachedEntry.pages = loadedPages
            pageEntries[key] = cachedEntry
        }
        lock.unlock()
        return loadedPages
    }

    static func pageFileURLs(ownerID: UUID, archive: Data?) -> [URL]? {
        let key = cacheKey(ownerID: ownerID, archive: archive)
        return cachedPageEntry(for: key, archive: archive).fileURLs
    }

    static func grades(ownerID: UUID, archive: Data?) -> [QuestionGradeRecord] {
        let key = cacheKey(ownerID: ownerID, archive: archive)
        let entry = cachedGradeEntry(for: key, archive: archive)
        if let grades = entry.grades {
            return grades
        }
        guard let fileURL = entry.fileURL else { return [] }

        let loadedGrades = ((try? Data(contentsOf: fileURL, options: .mappedIfSafe))
            .flatMap { try? JSONDecoder().decode([QuestionGradeRecord].self, from: $0) }) ?? []
        let needsReview = loadedGrades.contains(where: \.needsReview)
        lock.lock()
        if var cachedEntry = gradeEntries[key] {
            cachedEntry.grades = loadedGrades
            cachedEntry.hasQuestionNeedingReview = needsReview
            gradeEntries[key] = cachedEntry
        }
        lock.unlock()
        return loadedGrades
    }

    static func gradeNeedsReview(ownerID: UUID, archive: Data?) -> Bool {
        let key = cacheKey(ownerID: ownerID, archive: archive)
        let entry = cachedGradeEntry(for: key, archive: archive)
        if let hasQuestionNeedingReview = entry.hasQuestionNeedingReview {
            return hasQuestionNeedingReview
        }
        let grades = grades(ownerID: ownerID, archive: archive)
        return grades.contains(where: \.needsReview)
    }

    static func storePages(_ pages: [Data], ownerID: UUID, archive: Data?) {
        let key = cacheKey(ownerID: ownerID, archive: archive)
        lock.lock()
        defer { lock.unlock() }
        removeEntriesLocked(for: ownerID, from: &pageEntries)
        pageEntries[key] = PageCacheEntry(pages: pages, fileURLs: nil)
    }

    static func storePageFiles(_ fileURLs: [URL], ownerID: UUID, archive: Data?) {
        let key = cacheKey(ownerID: ownerID, archive: archive)
        lock.lock()
        defer { lock.unlock() }
        removeEntriesLocked(for: ownerID, from: &pageEntries)
        pageEntries[key] = PageCacheEntry(pages: nil, fileURLs: fileURLs)
    }

    static func storeGrades(_ grades: [QuestionGradeRecord], ownerID: UUID, archive: Data?) {
        let key = cacheKey(ownerID: ownerID, archive: archive)
        lock.lock()
        defer { lock.unlock() }
        removeEntriesLocked(for: ownerID, from: &gradeEntries)
        gradeEntries[key] = GradeCacheEntry(
            grades: grades,
            fileURL: nil,
            hasQuestionNeedingReview: grades.contains(where: \.needsReview)
        )
    }

    static func storeGradeFile(_ fileURL: URL, ownerID: UUID, archive: Data?, hasQuestionNeedingReview: Bool) {
        let key = cacheKey(ownerID: ownerID, archive: archive)
        lock.lock()
        defer { lock.unlock() }
        removeEntriesLocked(for: ownerID, from: &gradeEntries)
        gradeEntries[key] = GradeCacheEntry(
            grades: nil,
            fileURL: fileURL,
            hasQuestionNeedingReview: hasQuestionNeedingReview
        )
    }

    private static func cachedValue<Value>(
        for key: String,
        store: inout [String: Value],
        decode: () -> Value
    ) -> Value {
        lock.lock()
        defer { lock.unlock() }

        if let existing = store[key] {
            return existing
        }

        let decoded = decode()
        store[key] = decoded
        return decoded
    }

    private static func removeEntriesLocked<Value>(for ownerID: UUID, from store: inout [String: Value]) {
        let prefix = ownerID.uuidString + "|"
        store.keys
            .filter { $0.hasPrefix(prefix) }
            .forEach { store.removeValue(forKey: $0) }
    }

    private static func cachedPageEntry(for key: String, archive: Data?) -> PageCacheEntry {
        cachedValue(for: key, store: &pageEntries) {
            guard let archive else {
                return PageCacheEntry(pages: [], fileURLs: nil)
            }
            if let stored = try? JSONDecoder().decode(StoredPageArchive.self, from: archive) {
                let fileURLs = stored.filePaths.map(URL.init(fileURLWithPath:))
                return PageCacheEntry(pages: nil, fileURLs: fileURLs)
            }
            let decodedPages = (try? JSONDecoder().decode([Data].self, from: archive)) ?? []
            return PageCacheEntry(pages: decodedPages, fileURLs: nil)
        }
    }

    private static func cachedGradeEntry(for key: String, archive: Data?) -> GradeCacheEntry {
        cachedValue(for: key, store: &gradeEntries) {
            guard let archive else {
                return GradeCacheEntry(grades: [], fileURL: nil, hasQuestionNeedingReview: false)
            }
            if let stored = try? JSONDecoder().decode(StoredGradeArchive.self, from: archive) {
                return GradeCacheEntry(
                    grades: nil,
                    fileURL: URL(fileURLWithPath: stored.filePath),
                    hasQuestionNeedingReview: stored.hasQuestionNeedingReview
                )
            }
            let decoded = (try? JSONDecoder().decode([QuestionGradeRecord].self, from: archive)) ?? []
            return GradeCacheEntry(
                grades: decoded,
                fileURL: nil,
                hasQuestionNeedingReview: decoded.contains(where: \.needsReview)
            )
        }
    }

    private static func cacheKey(ownerID: UUID, archive: Data?) -> String {
        let archiveHash = archive.map { ($0 as NSData).hash } ?? 0
        let archiveCount = archive?.count ?? 0
        return "\(ownerID.uuidString)|\(archiveCount)|\(archiveHash)"
    }
}

struct StoredPageArchive: Codable {
    let filePaths: [String]
}

struct StoredGradeArchive: Codable {
    let filePath: String
    let hasQuestionNeedingReview: Bool
}

struct SubmissionDebugInfo: Codable, Sendable {
    var batchStatusJSON: String?
    var latestBatchOutputLineJSON: String?
    var latestBatchErrorLineJSON: String?
    var latestLookupSummary: String?
}

enum PersistedPageStorage {
    static func persistPages(_ pages: [Data], ownerID: UUID, namespace: String) throws -> [URL] {
        let directory = try prepareDirectory(ownerID: ownerID, namespace: namespace)
        return try pages.enumerated().map { index, pageData in
            let fileURL = directory.appendingPathComponent(String(format: "page-%04d.jpg", index + 1))
            try pageData.write(to: fileURL, options: .atomic)
            return fileURL
        }
    }

    static func copyPages(from sourceFileURLs: [URL], ownerID: UUID, namespace: String) throws -> [URL] {
        let directory = try prepareDirectory(ownerID: ownerID, namespace: namespace)
        return try sourceFileURLs.enumerated().map { index, sourceFileURL in
            let pathExtension = sourceFileURL.pathExtension.isEmpty ? "jpg" : sourceFileURL.pathExtension
            let destinationURL = directory.appendingPathComponent(
                String(format: "page-%04d.%@", index + 1, pathExtension)
            )
            try FileManager.default.copyItem(at: sourceFileURL, to: destinationURL)
            return destinationURL
        }
    }

    private static func prepareDirectory(ownerID: UUID, namespace: String) throws -> URL {
        let root = try rootDirectory()
        let directory = root
            .appendingPathComponent(namespace, isDirectory: true)
            .appendingPathComponent(ownerID.uuidString, isDirectory: true)

        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func rootDirectory() throws -> URL {
        guard let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let rootURL = baseURL.appendingPathComponent("HomeworkGraderPersistedPages", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        return rootURL
    }
}

enum PersistedGradeStorage {
    static func persistGrades(_ grades: [QuestionGradeRecord], ownerID: UUID, namespace: String) throws -> URL {
        guard let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let directory = baseURL
            .appendingPathComponent("HomeworkGraderPersistedGrades", isDirectory: true)
            .appendingPathComponent(namespace, isDirectory: true)
            .appendingPathComponent(ownerID.uuidString, isDirectory: true)

        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileURL = directory.appendingPathComponent("grades.json")
        let data = try JSONEncoder().encode(grades)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }
}
