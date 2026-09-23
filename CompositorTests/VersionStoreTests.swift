import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Compositor

@MainActor
struct VersionStoreTests {
    private struct Workspace {
        let root: URL
        let store: VersionStore
        var project: URL { root.appendingPathComponent("Project.comp") }
    }

    private func workspace() throws -> Workspace {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bCompositorVersionTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return Workspace(root: root, store: VersionStore(root: root.appendingPathComponent("History")))
    }

    private func sessionWithImage() async throws -> EditorSession {
        let source = try ImageImportTests().fixture(.png)
        defer { try? FileManager.default.removeItem(at: source) }
        let session = EditorSession()
        await session.importImages([source])
        #expect(session.document?.layers.isEmpty == false)
        return session
    }

    private func save(_ session: EditorSession, to url: URL) async throws -> ProjectSnapshot {
        let snapshot = try #require(session.projectSnapshot())
        try await ProjectStore.shared.save(snapshot, to: url)
        return snapshot
    }

    private func objectCount(_ workspace: Workspace) -> Int {
        let objects = workspace.store.root.appendingPathComponent("objects")
        let enumerator = FileManager.default.enumerator(at: objects, includingPropertiesForKeys: [.isRegularFileKey])
        return (enumerator?.allObjects as? [URL] ?? []).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }.count
    }

    /// Deduplication depends on an unchanged layer encoding to the same bytes on every save.
    @Test func savingTheSameProjectTwiceWritesIdenticalImageBytes() async throws {
        let w = try workspace()
        defer { try? FileManager.default.removeItem(at: w.root) }
        let session = try await sessionWithImage()
        let second = w.root.appendingPathComponent("Second.comp")
        _ = try await save(session, to: w.project)
        _ = try await save(session, to: second)
        let layer = try #require(session.activeLayerID).uuidString + ".png"
        let a = try Data(contentsOf: w.project.appendingPathComponent("images/\(layer)"))
        let b = try Data(contentsOf: second.appendingPathComponent("images/\(layer)"))
        #expect(a == b)
    }

    @Test func eachChangedSaveBecomesAVersionAndUnchangedSavesDoNot() async throws {
        let w = try workspace()
        defer { try? FileManager.default.removeItem(at: w.root) }
        let session = try await sessionWithImage()
        let documentID = try #require(session.document?.id)

        _ = try await save(session, to: w.project)
        guard case .created(let first) = try await w.store.record(packageAt: w.project) else {
            Issue.record("The first save should create a version"); return
        }
        // Manifest, one layer image, tree and commit.
        #expect(objectCount(w) == 4)

        _ = try await save(session, to: w.project)
        #expect(try await w.store.record(packageAt: w.project) == .unchanged(first))
        #expect(objectCount(w) == 4)

        session.renameLayer(try #require(session.activeLayerID), to: "Renamed")
        _ = try await save(session, to: w.project)
        guard case .created(let second) = try await w.store.record(packageAt: w.project) else {
            Issue.record("A changed save should create a version"); return
        }
        // Only a new manifest, tree and commit: the layer's pixels are shared with the first version.
        #expect(objectCount(w) == 7)

        let log = try await w.store.log(of: documentID)
        #expect(log.map(\.hash) == [second, first])
        #expect(log[0].commit.parents == [first])
        #expect(log[1].commit.parents.isEmpty)
        #expect(try await w.store.head(of: documentID) == second)
    }

    @Test func aMaterializedVersionOpensAsTheProjectItWasSavedFrom() async throws {
        let w = try workspace()
        defer { try? FileManager.default.removeItem(at: w.root) }
        let session = try await sessionWithImage()
        let original = try await save(session, to: w.project)
        let commit = try await w.store.record(packageAt: w.project).commit

        let copy = w.root.appendingPathComponent("Restored.comp")
        try await w.store.materialize(commit, at: copy)
        let restored = try await ProjectStore.shared.load(from: copy)
        #expect(try VersionStore.encode(restored.manifest) == VersionStore.encode(original.manifest))
        #expect(Set(restored.images.keys) == Set(original.images.keys))
    }

    @Test func tamperedHistoryIsRejected() async throws {
        let w = try workspace()
        defer { try? FileManager.default.removeItem(at: w.root) }
        let session = try await sessionWithImage()
        _ = try await save(session, to: w.project)
        let commit = try await w.store.record(packageAt: w.project).commit
        let object = w.store.root.appendingPathComponent("objects/\(commit.hex.prefix(2))/\(commit.hex.dropFirst(2))")
        try Data("{}".utf8).write(to: object)
        await #expect(throws: VersionStoreError.corrupt) { try await w.store.commit(commit) }
    }

    /// `restoreVersion` rebuilds the document the same way `installProject` does; this keeps the two from drifting.
    @Test func restoringAVersionMatchesOpeningItAndCanBeUndone() async throws {
        let w = try workspace()
        defer { try? FileManager.default.removeItem(at: w.root) }
        let session = try await sessionWithImage()
        let layer = try #require(session.activeLayerID)
        let saved = try await save(session, to: w.project)

        session.renameLayer(layer, to: "Changed after saving")
        session.toggleLayerVisibility(layer)
        let changed = try #require(session.projectSnapshot())

        session.restoreVersion(saved)
        let viaRestore = try #require(session.projectSnapshot())
        let opened = EditorSession()
        opened.installProject(saved, from: w.project)
        let viaOpen = try #require(opened.projectSnapshot())
        #expect(try VersionStore.encode(viaRestore.manifest) == VersionStore.encode(viaOpen.manifest))
        #expect(session.isModified)

        session.undo()
        #expect(try VersionStore.encode(try #require(session.projectSnapshot()).manifest) == VersionStore.encode(changed.manifest))
    }

    @Test func hashesAreLowercaseSHA256() {
        #expect(ObjectHash(of: Data()).hex == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(ObjectHash(String(repeating: "A", count: 64)) == nil)
        #expect(ObjectHash("abc") == nil)
    }
}
