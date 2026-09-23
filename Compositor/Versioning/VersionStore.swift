import Foundation
import CryptoKit

/// A git-style, content-addressed history of saved projects.
///
/// Every file of a saved `.comp` package (its manifest and each layer and mask PNG) is stored once, under the
/// SHA-256 of its bytes. A version is a small tree that names those files by hash, and a commit that points at the
/// tree and at the version before it. Layers that didn't change between saves hash the same, so they are never
/// stored twice, and one store serves every project on the Mac.
///
/// History lives beside the project rather than inside it: every save rewrites the package atomically, which would
/// otherwise wipe it. Projects are keyed by the manifest's `documentID`, which survives renames, moves and Save As.
///
/// Layout under `root`:
///
///     objects/ab/cdef…   blobs, trees and commits, named by the SHA-256 of their bytes
///     refs/<documentID>  the hash of the project's latest commit
///     previews/<commit>  a small rendered preview of each commit — a cache, not part of the history
actor VersionStore {
    static let shared = VersionStore(root: VersionStore.defaultRoot)

    static var defaultRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("bCompositor/History", isDirectory: true)
    }

    nonisolated let root: URL
    init(root: URL) { self.root = root }

    // MARK: Recording

    enum RecordResult: Equatable, Sendable {
        /// The save differed from the latest version, so it became a new one.
        case created(ObjectHash)
        /// The save matched the latest version exactly; history is unchanged.
        case unchanged(ObjectHash)

        var commit: ObjectHash {
            switch self { case .created(let hash), .unchanged(let hash): hash }
        }
    }

    /// Records the saved package at `package` as the project's next version, unless nothing changed since the last.
    func record(packageAt package: URL, message: String? = nil, date: Date = Date()) throws -> RecordResult {
        var coordinationError: NSError?
        var result: Result<RecordResult, Error>?
        NSFileCoordinator().coordinate(readingItemAt: package, options: .withoutChanges, error: &coordinationError) { source in
            result = Result { try recordPackage(at: source, message: message, date: date) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw VersionStoreError.corrupt }
        return try result.get()
    }

    private func recordPackage(at package: URL, message: String?, date: Date) throws -> RecordResult {
        let manifestURL = package.appendingPathComponent("manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let header = try JSONDecoder().decode(ManifestHeader.self, from: manifestData)

        var files: [String: ObjectHash] = [:]
        let images = package.appendingPathComponent("images", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: images.path)) ?? []
        for name in names where name.hasSuffix(".png") {
            files[name] = try putFile(images.appendingPathComponent(name))
        }
        let tree = VersionTree(manifest: try put(manifestData), files: files)
        let treeHash = try put(try Self.encode(tree))

        let parent = try head(of: header.documentID)
        if let parent, try commit(parent).tree == treeHash { return .unchanged(parent) }

        let commit = VersionCommit(documentID: header.documentID, tree: treeHash,
                                   parents: parent.map { [$0] } ?? [], date: date, message: message,
                                   width: header.width, height: header.height, layerCount: header.layers.count)
        let hash = try put(try Self.encode(commit))
        try setHead(hash, of: header.documentID)
        return .created(hash)
    }

    // MARK: Reading

    /// The project's versions, newest first, following each commit's first parent.
    func log(of documentID: UUID, limit: Int = 1_000) throws -> [VersionEntry] {
        var entries: [VersionEntry] = []
        var next = try head(of: documentID)
        while let hash = next, entries.count < limit {
            let commit = try commit(hash)
            entries.append(VersionEntry(hash: hash, commit: commit))
            next = commit.parents.first
        }
        return entries
    }

    func head(of documentID: UUID) throws -> ObjectHash? {
        let url = refURL(documentID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let text = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let hash = ObjectHash(text) else { throw VersionStoreError.corrupt }
        return hash
    }

    func commit(_ hash: ObjectHash) throws -> VersionCommit {
        let commit = try JSONDecoder.versions.decode(VersionCommit.self, from: try verifiedObject(hash))
        guard commit.format == VersionCommit.format else { throw VersionStoreError.corrupt }
        return commit
    }

    func tree(_ hash: ObjectHash) throws -> VersionTree {
        try JSONDecoder.versions.decode(VersionTree.self, from: try verifiedObject(hash))
    }

    /// Writes the version as an ordinary `.comp` package at `destination`, which must not exist yet.
    /// On APFS the layer files are cloned rather than copied, so this is quick and takes no extra space.
    func materialize(_ commitHash: ObjectHash, at destination: URL) throws {
        let tree = try tree(try commit(commitHash).tree)
        let images = destination.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: objectURL(tree.manifest), to: destination.appendingPathComponent("manifest.json"))
        for (name, hash) in tree.files {
            // Names come from our own trees, but a tree is only as trustworthy as the store it came from.
            guard !name.contains("/"), !name.hasPrefix(".") else { throw VersionStoreError.corrupt }
            try FileManager.default.copyItem(at: objectURL(hash), to: images.appendingPathComponent(name))
        }
    }

    // MARK: Previews

    func setPreview(_ png: Data, for commit: ObjectHash) throws {
        let url = previewURL(commit)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url, options: .atomic)
    }

    func preview(for commit: ObjectHash) -> Data? {
        try? Data(contentsOf: previewURL(commit))
    }

    // MARK: Objects

    /// Stores `data` under its hash. Storing something already present is a no-op.
    @discardableResult
    func put(_ data: Data) throws -> ObjectHash {
        let hash = ObjectHash(of: data)
        let url = objectURL(hash)
        guard !FileManager.default.fileExists(atPath: url.path) else { return hash }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return hash
    }

    /// Stores a file under its hash without holding it all in memory, cloning it into the store on APFS.
    func putFile(_ file: URL) throws -> ObjectHash {
        let hash = try ObjectHash(ofFileAt: file)
        let url = objectURL(hash)
        guard !FileManager.default.fileExists(atPath: url.path) else { return hash }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Clone beside the destination, then move into place, so a crash never leaves a partial object behind.
        let staging = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString)")
        try FileManager.default.copyItem(at: file, to: staging)
        do { try FileManager.default.moveItem(at: staging, to: url) }
        catch {
            try? FileManager.default.removeItem(at: staging)
            // Another save stored the same object first.
            guard FileManager.default.fileExists(atPath: url.path) else { throw error }
        }
        return hash
    }

    func contains(_ hash: ObjectHash) -> Bool {
        FileManager.default.fileExists(atPath: objectURL(hash).path)
    }

    /// Commits and trees are small, so they are checked against their hash every time they're read.
    private func verifiedObject(_ hash: ObjectHash) throws -> Data {
        let url = objectURL(hash)
        guard FileManager.default.fileExists(atPath: url.path) else { throw VersionStoreError.missingObject(hash) }
        let data = try Data(contentsOf: url)
        guard ObjectHash(of: data) == hash else { throw VersionStoreError.corrupt }
        return data
    }

    private func setHead(_ hash: ObjectHash, of documentID: UUID) throws {
        let url = refURL(documentID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(hash.hex.utf8).write(to: url, options: .atomic)
    }

    private func objectURL(_ hash: ObjectHash) -> URL {
        root.appendingPathComponent("objects", isDirectory: true)
            .appendingPathComponent(String(hash.hex.prefix(2)), isDirectory: true)
            .appendingPathComponent(String(hash.hex.dropFirst(2)))
    }

    private func refURL(_ documentID: UUID) -> URL {
        root.appendingPathComponent("refs", isDirectory: true).appendingPathComponent(documentID.uuidString)
    }

    private func previewURL(_ commit: ObjectHash) -> URL {
        root.appendingPathComponent("previews", isDirectory: true).appendingPathComponent(commit.hex + ".png")
    }

    /// Canonical JSON: sorted keys and fixed date formatting, so the same value always hashes the same.
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    /// Just the parts of a manifest the history needs; the full manifest is stored verbatim as a blob.
    private struct ManifestHeader: Decodable {
        struct Layer: Decodable {}
        let documentID: UUID
        let width: Int
        let height: Int
        let layers: [Layer]
    }
}

// MARK: - Model

/// A SHA-256 digest, written as 64 lowercase hex characters.
nonisolated struct ObjectHash: Hashable, Codable, Sendable, CustomStringConvertible {
    let hex: String

    init?(_ hex: String) {
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        self.hex = hex
    }

    init(of data: Data) {
        hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    init(ofFileAt url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty { hasher.update(data: chunk) }
        hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let hash = ObjectHash(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a SHA-256 hash"))
        }
        self = hash
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    var short: String { String(hex.prefix(8)) }
    var description: String { hex }
}

/// The saved package: its manifest and every image file, each named by hash.
nonisolated struct VersionTree: Codable, Equatable, Sendable {
    var type = "tree"
    let manifest: ObjectHash
    /// File name inside `images/` → hash of its bytes.
    let files: [String: ObjectHash]
}

nonisolated struct VersionCommit: Codable, Equatable, Sendable {
    static let format = "com.b0ase.bcompositor.commit"
    var format = VersionCommit.format
    var version = 1
    let documentID: UUID
    let tree: ObjectHash
    /// Empty for a project's first version; two for a merge.
    let parents: [ObjectHash]
    let date: Date
    let message: String?
    let width: Int
    let height: Int
    let layerCount: Int
}

nonisolated struct VersionEntry: Identifiable, Equatable, Sendable {
    let hash: ObjectHash
    let commit: VersionCommit
    var id: ObjectHash { hash }
}

nonisolated enum VersionStoreError: LocalizedError, Equatable {
    case missingObject(ObjectHash), corrupt
    var errorDescription: String? {
        switch self {
        case .missingObject(let hash): "Part of this project’s history (\(hash.short)) is missing."
        case .corrupt: "This project’s version history is damaged."
        }
    }
}

extension JSONDecoder {
    nonisolated static var versions: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
