import Foundation

private let defaultActiveLimit = 50

/// Persistent vocabulary list for biasing transcription spelling. JSON storage.
final class VocabularyStore {
    private var entries: [VocabEntry] = []
    private let lock = NSLock()
    let path: URL

    init(path: URL? = nil) {
        self.path = path ?? AppIdentity.stateDir.appendingPathComponent("vocabulary.json")
        load()
    }

    // MARK: - Public API

    func listEntries() -> [VocabEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    @discardableResult
    func add(_ canonical: String) throws -> VocabEntry {
        let normalized = canonical.split(separator: " ").joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !normalized.isEmpty else {
            throw VocabError.emptyEntry
        }

        lock.lock()
        defer { lock.unlock() }

        // Check for case-insensitive duplicate
        if let existing = entries.first(where: { $0.canonical.caseInsensitiveCompare(normalized) == .orderedSame }) {
            return existing
        }

        let entry = VocabEntry(
            id: UUID().uuidString.prefix(8).lowercased(),
            canonical: normalized,
            addedAt: ISO8601DateFormatter().string(from: Date())
        )
        entries.append(entry)
        save()
        return entry
    }

    @discardableResult
    func remove(entryID: String) -> Bool {
        lock.lock()
        let before = entries.count
        entries.removeAll { $0.id == entryID }
        let removed = entries.count < before
        lock.unlock()
        guard removed else { return false }
        save()
        return true
    }

    /// Newest first, then the provider client's own term/character budget applies.
    func getActiveVocabulary(limit: Int = defaultActiveLimit) -> [String] {
        lock.lock()
        let snapshot = entries
        lock.unlock()
        return Array(snapshot.sorted { $0.addedAt > $1.addedAt }
            .prefix(limit)
            .map(\.canonical))
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: path.path) else {
            entries = []
            return
        }

        do {
            let data = try Data(contentsOf: path)
            let container = try JSONDecoder().decode(VocabContainer.self, from: data)
            entries = container.entries.compactMap { raw in
                let canonical = raw.canonical.trimmingCharacters(in: .whitespaces)
                guard !canonical.isEmpty else { return nil }
                return VocabEntry(
                    id: raw.id ?? UUID().uuidString.prefix(8).lowercased(),
                    canonical: canonical,
                    addedAt: raw.addedAt ?? ISO8601DateFormatter().string(from: Date())
                )
            }
        } catch {
            print("[vocab] failed to load vocabulary: \(error)")
            entries = []
        }
    }

    private func save() {
        let dir = path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let container = VocabContainer(version: 1, entries: entries.map { entry in
            VocabRawEntry(
                id: entry.id,
                canonical: entry.canonical,
                addedAt: entry.addedAt
            )
        })

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            let data = try encoder.encode(container)
            if FileManager.default.fileExists(atPath: path.path) {
                let tmp = path.appendingPathExtension("tmp")
                try data.write(to: tmp)
                _ = try FileManager.default.replaceItemAt(path, withItemAt: tmp)
            } else {
                try data.write(to: path, options: .atomic)
            }
        } catch {
            print("[vocab] failed to save: \(error)")
        }
    }
}

struct VocabEntry {
    let id: String
    let canonical: String
    let addedAt: String
}

enum VocabError: LocalizedError {
    case emptyEntry

    var errorDescription: String? {
        switch self {
        case .emptyEntry: return "Word or phrase cannot be empty."
        }
    }
}

// MARK: - JSON models

private struct VocabContainer: Codable {
    let version: Int
    let entries: [VocabRawEntry]
}

private struct VocabRawEntry: Codable {
    let id: String?
    let canonical: String
    let addedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, canonical
        case addedAt = "added_at"
        case pinned
        case lastUsedAt = "last_used_at"
    }

    init(id: String?, canonical: String, addedAt: String?) {
        self.id = id
        self.canonical = canonical
        self.addedAt = addedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        canonical = try c.decode(String.self, forKey: .canonical)
        addedAt = try c.decodeIfPresent(String.self, forKey: .addedAt)
        // pinned / last_used_at are polish-era leftovers; decode-ignored on purpose.
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encode(canonical, forKey: .canonical)
        try c.encodeIfPresent(addedAt, forKey: .addedAt)
    }
}
