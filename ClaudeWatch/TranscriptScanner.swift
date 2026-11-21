import Foundation

/// Everything the scanner learned from the transcripts.
struct ScanResult: Sendable {
    /// Deduplicated by message id across all files (forked and resumed sessions copy earlier messages).
    var entries: [UsageEntry]
    /// Session id → title set with `-n`/`/rename` (the transcript's `custom-title` records).
    var titles: [String: String]
    /// Claude Code's own running cost totals, which include side requests the transcript doesn't list.
    var snapshots: [CostSnapshot] = []
}

/// A `cost-state` record: Claude Code's cumulative cost for one process run of a session.
struct CostSnapshot: Codable, Sendable, Equatable {
    var sessionID: String
    /// When the Claude Code process started; identifies the run.
    var runStart: Date
    /// API list-price cost of everything the run sent, side requests included.
    var cost: Double
    /// Timestamp of the last assistant message written before this record.
    var asOf: Date
}

/// Reads Claude Code transcripts (`~/.claude/projects/**/*.jsonl`) incrementally.
///
/// Transcripts are append-only, so each file is read from where the last scan stopped. The parsed
/// state is cached on disk, which keeps relaunches fast even with hundreds of MB of transcripts.
actor TranscriptScanner {
    struct FileState: Codable {
        var inode: UInt64
        var offset: UInt64
        var entries: [UsageEntry]
        var titles: [String: String]
        var snapshots: [CostSnapshot] = []
        var lastEntryTime: Date?
    }

    private struct Cache: Codable {
        static let currentVersion = 2
        var version: Int
        var files: [String: FileState]
    }

    let root: URL
    private let cacheURL: URL?
    private var files: [String: FileState] = [:]
    private var loadedCache = false
    private let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let iso = ISO8601DateFormatter()

    init(root: URL = TranscriptScanner.defaultRoot, cacheURL: URL? = TranscriptScanner.defaultCacheURL) {
        self.root = root
        self.cacheURL = cacheURL
    }

    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    static var defaultCacheURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("de.lorenz-unna.claudewatch", isDirectory: true)
            .appendingPathComponent("transcripts-v\(Cache.currentVersion).json")
    }

    func scan() -> ScanResult {
        loadCacheIfNeeded()
        var changed = false
        var seen = Set<String>()

        for url in transcriptFiles() {
            let path = url.path
            seen.insert(path)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = (attributes[.size] as? NSNumber)?.uint64Value,
                  let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
            else { continue }

            var state = files[path] ?? FileState(inode: inode, offset: 0, entries: [], titles: [:])
            if state.inode != inode || size < state.offset {
                // Replaced or truncated: start over.
                state = FileState(inode: inode, offset: 0, entries: [], titles: [:])
                changed = true
            }
            guard size > state.offset else {
                files[path] = state
                continue
            }
            read(url, into: &state)
            files[path] = state
            changed = true
        }

        let removed = files.keys.filter { !seen.contains($0) }
        if !removed.isEmpty {
            for path in removed { files.removeValue(forKey: path) }
            changed = true
        }
        if changed { saveCache() }
        return merged()
    }

    // MARK: - Reading

    private func transcriptFiles() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            result.append(url)
        }
        return result
    }

    // Tool results inside `user` lines can be megabytes and mention anything, but text nested in
    // JSON strings is escaped (`\"type\"`), so only real assistant records match this needle.
    private static let assistantNeedle = Array(#""type":"assistant""#.utf8)
    private static let usageNeedle = Array(#""usage":"#.utf8)
    private static let titleNeedle = Array(#""custom-title""#.utf8)
    private static let costNeedle = Array(#""type":"cost-state""#.utf8)

    private static let chunkSize = 4 << 20

    private func read(_ url: URL, into state: inout FileState) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: state.offset)) != nil else { return }

        // Read in chunks so a first scan of large transcripts doesn't hold them in memory at once.
        // FileHandle hands out autoreleased buffers, so drain a pool per chunk.
        var pending = Data()
        var reachedEnd = false
        while !reachedEnd {
            autoreleasepool {
                guard let chunk = try? handle.read(upToCount: Self.chunkSize), !chunk.isEmpty else {
                    reachedEnd = true
                    return
                }
                pending.append(chunk)
                let consumed = consumeLines(pending, into: &state)
                state.offset += UInt64(consumed)
                pending = consumed == pending.count ? Data() : Data(pending[pending.startIndex + consumed ..< pending.endIndex])
            }
        }
        // A trailing partial line (still being written) stays unread and is picked up next time.
    }

    /// Parses every complete line in `data` and returns how many bytes that covered.
    private func consumeLines(_ data: Data, into state: inout FileState) -> Int {
        var consumed = 0
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var start = 0
            while start < buffer.count {
                guard let newline = memchr(base + start, 0x0A, buffer.count - start) else { break }
                let end = base.distance(to: UnsafeRawPointer(newline))
                let line = UnsafeRawBufferPointer(rebasing: buffer[start..<end])
                let isUsage = Self.contains(Self.assistantNeedle, in: line) && Self.contains(Self.usageNeedle, in: line)
                if isUsage || Self.contains(Self.titleNeedle, in: line) || Self.contains(Self.costNeedle, in: line) {
                    autoreleasepool { parse(Data(line), into: &state) }
                }
                start = end + 1
                consumed = start
            }
        }
        return consumed
    }

    private static func contains(_ needle: [UInt8], in haystack: UnsafeRawBufferPointer) -> Bool {
        guard let base = haystack.baseAddress, haystack.count >= needle.count else { return false }
        return needle.withUnsafeBytes { n in
            memmem(base, haystack.count, n.baseAddress, needle.count) != nil
        }
    }

    private func parse(_ line: Data, into state: inout FileState) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String
        else { return }

        switch type {
        case "custom-title":
            if let session = object["sessionId"] as? String, let title = object["customTitle"] as? String, !title.isEmpty {
                state.titles[session] = title
            }
        case "cost-state":
            guard let session = object["sessionId"] as? String,
                  let start = (object["startTime"] as? NSNumber)?.doubleValue,
                  let cost = (object["totalCostUSD"] as? NSNumber)?.doubleValue
            else { return }
            let runStart = Date(timeIntervalSince1970: start / 1000)
            state.snapshots.append(CostSnapshot(
                sessionID: session, runStart: runStart, cost: cost, asOf: max(state.lastEntryTime ?? runStart, runStart)
            ))
        default:
            if let entry = entry(from: object, type: type) {
                state.entries.append(entry)
                state.lastEntryTime = entry.timestamp
            }
        }
    }

    /// Exposed for tests.
    nonisolated func entry(fromLine line: Data) -> UsageEntry? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String
        else { return nil }
        return Self.makeEntry(from: object, type: type, parseDate: Self.parseDate)
    }

    private func entry(from object: [String: Any], type: String) -> UsageEntry? {
        Self.makeEntry(from: object, type: type) { [isoFractional, iso] string in
            isoFractional.date(from: string) ?? iso.date(from: string)
        }
    }

    private nonisolated static func parseDate(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    private nonisolated static func makeEntry(
        from object: [String: Any], type: String, parseDate: (String) -> Date?
    ) -> UsageEntry? {
        guard type == "assistant",
              let message = object["message"] as? [String: Any],
              let id = message["id"] as? String,
              let model = message["model"] as? String, model != "<synthetic>",
              let usage = message["usage"] as? [String: Any],
              let timestampString = object["timestamp"] as? String,
              let timestamp = parseDate(timestampString),
              let session = object["sessionId"] as? String
        else { return nil }

        func int(_ dict: [String: Any]?, _ key: String) -> Int { (dict?[key] as? NSNumber)?.intValue ?? 0 }

        let cacheCreation = usage["cache_creation"] as? [String: Any]
        let totalWrite = int(usage, "cache_creation_input_tokens")
        var write1h = int(cacheCreation, "ephemeral_1h_input_tokens")
        var write5m = int(cacheCreation, "ephemeral_5m_input_tokens")
        if cacheCreation == nil {
            write5m = totalWrite
            write1h = 0
        } else if write5m + write1h < totalWrite {
            write5m = totalWrite - write1h
        }

        return UsageEntry(
            messageID: id,
            timestamp: timestamp,
            sessionID: session,
            project: object["cwd"] as? String ?? "",
            entrypoint: object["entrypoint"] as? String ?? "cli",
            model: model,
            backend: Backend(messageID: id),
            input: int(usage, "input_tokens"),
            output: int(usage, "output_tokens"),
            cacheRead: int(usage, "cache_read_input_tokens"),
            cacheWrite5m: write5m,
            cacheWrite1h: write1h,
            fast: (usage["speed"] as? String) == "fast"
        )
    }

    // MARK: - Merging

    private func merged() -> ScanResult {
        // Claude Code writes one transcript line per content block, all carrying the same message id
        // and usage, and forks copy earlier messages into a new file. Keep the earliest copy of each.
        var byID: [String: UsageEntry] = [:]
        var titles: [String: String] = [:]
        var snapshots: [CostSnapshot] = []
        for state in files.values {
            for entry in state.entries {
                if let existing = byID[entry.messageID], existing.timestamp <= entry.timestamp { continue }
                byID[entry.messageID] = entry
            }
            titles.merge(state.titles) { _, new in new }
            snapshots += state.snapshots
        }
        return ScanResult(entries: Array(byID.values), titles: titles, snapshots: snapshots)
    }

    // MARK: - Cache

    private func loadCacheIfNeeded() {
        guard !loadedCache else { return }
        loadedCache = true
        guard let cacheURL, let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(Cache.self, from: data),
              cache.version == Cache.currentVersion
        else { return }
        files = cache.files
    }

    private func saveCache() {
        guard let cacheURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(Cache(version: Cache.currentVersion, files: files))
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            NSLog("ClaudeWatch: couldn't write the transcript cache: \(error)")
        }
    }
}
