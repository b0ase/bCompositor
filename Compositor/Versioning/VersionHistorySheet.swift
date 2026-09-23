import SwiftUI

/// Lists a project's saved versions, newest first, and hands back the one to restore (or nil to cancel).
struct VersionHistorySheet: View {
    let documentID: UUID
    let isSaved: Bool
    let finish: (ObjectHash?) -> Void

    @State private var entries: [VersionEntry] = []
    @State private var previews: [ObjectHash: NSImage] = [:]
    @State private var selection: ObjectHash?
    @State private var failure: String?
    @State private var loaded = false

    var body: some View { sheet.roundedControls() }

    @ViewBuilder private var sheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Version History").font(.title2.bold())

            Group {
                if let failure {
                    placeholder(failure)
                } else if loaded && entries.isEmpty {
                    placeholder(isSaved
                        ? "No versions yet. Each time you save, bCompositor keeps a version you can come back to."
                        : "Save this project to start its history. Each save keeps a version you can come back to.")
                } else {
                    List(selection: $selection) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            row(entry, number: entries.count - index, isLatest: index == 0).tag(entry.hash)
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .frame(minHeight: 320)

            Text("Restoring replaces the canvas with that version. It can be undone, and saving it adds a new version — nothing in the history is ever lost.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Cancel") { finish(nil) }
                    .configuredNativeShortcut(.escape)
                Spacer()
                Button("Restore") { finish(selection) }
                    .configuredNativeShortcut(.return)
                    .buttonStyle(.borderedProminent)
                    .disabled(selection == nil)
            }
        }
        .padding(24)
        .frame(width: 520, height: 560)
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .versionHistoryDidChange)) { note in
            if note.object as? UUID == documentID { Task { await reload() } }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
    }

    private func row(_ entry: VersionEntry, number: Int, isLatest: Bool) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                if let image = previews[entry.hash] {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .padding(3)
                }
            }
            .frame(width: 72, height: 54)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Version \(number)").font(.headline)
                    if isLatest {
                        Text("Latest").font(.caption.bold())
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(.tint.opacity(0.2)))
                    }
                }
                Text(entry.commit.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.callout).foregroundStyle(.secondary)
                Text("\(entry.commit.width) × \(entry.commit.height) · \(entry.commit.layerCount) \(entry.commit.layerCount == 1 ? "layer" : "layers")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(entry.hash.short)
                .font(.caption.monospaced()).foregroundStyle(.tertiary)
                .help(entry.hash.hex)
        }
        .padding(.vertical, 4)
    }

    private func reload() async {
        do {
            entries = try await VersionStore.shared.log(of: documentID)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        loaded = true
        for entry in entries where previews[entry.hash] == nil {
            if let data = await VersionStore.shared.preview(for: entry.hash), let image = NSImage(data: data) {
                previews[entry.hash] = image
            }
        }
    }
}
