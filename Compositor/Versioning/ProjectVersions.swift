import AppKit
import SwiftUI
import os

extension Notification.Name {
    /// Posted on the main actor when a project's history gains a version or a preview. `object` is the document ID.
    static let versionHistoryDidChange = Notification.Name("bCompositor.versionHistoryDidChange")
}

nonisolated private let log = Logger(subsystem: "com.b0ase.bcompositor", category: "Versions")

extension ProjectController {
    /// Called after every successful save, while the saved package is still readable.
    /// History is a convenience layered on top of saving, so a failure here is logged and never fails the save.
    func recordVersion(of snapshot: ProjectSnapshot, savedAt url: URL) async {
        let documentID = snapshot.manifest.documentID
        do {
            guard case .created(let hash) = try await VersionStore.shared.record(packageAt: url) else { return }
            NotificationCenter.default.post(name: .versionHistoryDidChange, object: documentID)
            // The preview needs a full render, so it follows the save rather than holding it up.
            Task.detached(priority: .utility) {
                do {
                    try await VersionStore.shared.setPreview(try await VersionPreview.render(snapshot), for: hash)
                    await MainActor.run { NotificationCenter.default.post(name: .versionHistoryDidChange, object: documentID) }
                } catch { log.error("Preview for \(hash.short, privacy: .public) failed: \(error.localizedDescription, privacy: .public)") }
            }
        } catch {
            log.error("Couldn’t record a version: \(error.localizedDescription, privacy: .public)")
        }
    }

    func showVersionHistory() async {
        guard let window, let document = session.document, canStart else { return }
        session.cancelCrop()
        session.commitTransform()
        session.isProjectBusy = true
        defer { session.isProjectBusy = false }

        let choice: ObjectHash? = await withCheckedContinuation { continuation in
            let sheet = NSWindow()
            sheet.styleMask = [.titled, .fullSizeContentView]
            sheet.title = "Version History"
            sheet.contentViewController = NSHostingController(rootView: VersionHistorySheet(
                documentID: document.id, isSaved: session.projectURL != nil
            ) { choice in
                window.endSheet(sheet)
                sheet.orderOut(nil)
                sheet.contentViewController = nil
                continuation.resume(returning: choice)
            })
            window.beginSheet(sheet)
        }
        guard let choice else { return }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("bCompositor-version-\(UUID().uuidString).comp", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            try await VersionStore.shared.materialize(choice, at: staging)
            // The same validation as opening a project, so a damaged version can never replace the canvas.
            let snapshot = try await ProjectStore.shared.load(from: staging)
            session.restoreVersion(snapshot)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn’t restore that version"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            _ = await alert.beginSheetModal(for: window)
        }
    }
}

extension EditorSession {
    /// Replaces the canvas with a saved version as one undoable edit. The project is left modified,
    /// so saving it records the restored state as a new version on top of the history rather than rewriting it.
    func restoreVersion(_ snapshot: ProjectSnapshot) {
        guard let current = document, current.id == snapshot.manifest.documentID else { return }
        collapsedGroupIDs = []
        isMaskSelected = false
        cancelCrop()
        guideDrag = nil
        transformEdit = nil
        renamingLayerID = nil
        let manifest = snapshot.manifest
        beginEdit("Restore Version")
        // Mirrors `installProject`; VersionStoreTests checks the two produce the same project.
        document = CanvasDocument(id: manifest.documentID, width: manifest.width, height: manifest.height,
            layers: manifest.layers.map {
                ImageLayer(id: $0.id, asset: snapshot.images[$0.id], name: $0.name,
                           isVisible: $0.isVisible, transform: $0.transform, parentID: $0.parentID, isGroup: $0.isGroup == true, opacity: $0.opacity ?? 1, blendMode: $0.blendMode ?? .normal, mask: snapshot.mask(for: $0), maskSourceID: $0.maskSourceID, adjustment: $0.adjustment,
                           shape: LayerShape.loaded($0.shape, image: snapshot.images[$0.id]?.image),
                           effects: $0.effects,
                           text: LayerText.loaded($0.text, image: snapshot.images[$0.id]?.image))
            }, resolution: manifest.resolution ?? 72, guides: manifest.guides ?? [])
        activeLayerID = manifest.activeLayerID
        endEdit()
        if current.width != manifest.width || current.height != manifest.height {
            viewport.fit(documentSize: document!.size)
        }
    }
}

nonisolated enum VersionPreview {
    static let maximumSide = 480

    /// A small PNG of the flattened canvas.
    static func render(_ snapshot: ProjectSnapshot) async throws -> Data {
        let raster = try await ImageExporter.shared.render(snapshot)
        let image = raster.image
        let scale = min(1, Double(maximumSide) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ExportError.render
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let small = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: small).representation(using: .png, properties: [:]) else {
            throw ExportError.encode
        }
        return png
    }
}
