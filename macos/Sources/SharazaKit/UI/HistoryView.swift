import AppKit
import SwiftUI
import UniformTypeIdentifiers

public struct HistoryView: View {
    @ObservedObject var appState: AppState
    @State private var selectedID: Int64?

    private let typeOptions = ["All", "Image", "Video", "Text", "File"]

    public init(appState: AppState) {
        self.appState = appState
    }

    private var selectedItem: HistoryItem? {
        if let id = selectedID, let match = appState.historyItems.first(where: { $0.id == id }) {
            return match
        }
        return appState.historyItems.first
    }

    public var body: some View {
        HStack(spacing: 0) {
            // Left Master Column: Filter Bar + Full-Height List
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search filename, URL, window title, or app…", text: $appState.historySearch)
                            .textFieldStyle(.plain)
                            .onSubmit {
                                Task { await appState.refreshHistory() }
                            }
                        if !appState.historySearch.isEmpty {
                            Button {
                                appState.historySearch = ""
                                Task { await appState.refreshHistory() }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.1), lineWidth: 1))
                    )

                    Picker("", selection: $appState.historyTypeFilter) {
                        ForEach(typeOptions, id: \.self) { opt in
                            Text(opt).tag(opt)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 96)
                    .onChange(of: appState.historyTypeFilter) { _, _ in
                        Task { await appState.refreshHistory() }
                    }

                    Button {
                        Task { await appState.refreshHistory() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh history")

                    Button("Import JSON…") {
                        importShareXJSON()
                    }
                    .help("Import upstream ShareX History.json")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.bar)

                Divider()

                if appState.historyItems.isEmpty {
                    ContentUnavailableView(
                        "No History Records",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Captures, recordings, and uploads are persisted in SQLite (ShareX History.db schema).")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(appState.historyItems, selection: $selectedID) { item in
                        HistoryRowView(item: item)
                            .tag(item.id)
                            .contextMenu {
                                historyContextMenu(for: item)
                            }
                    }
                    .listStyle(.inset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()

            // Right Inspector Column: Full-Height Preview & Metadata
            VStack(spacing: 0) {
                if let item = selectedItem {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            // Preview Card
                            ZStack {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.black.opacity(0.22))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                                    )

                                if !item.file_path.isEmpty,
                                   FileManager.default.fileExists(atPath: item.file_path),
                                   let img = NSImage(contentsOfFile: item.file_path) {
                                    Image(nsImage: img)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(maxHeight: 240)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .padding(8)
                                } else {
                                    VStack(spacing: 8) {
                                        Image(systemName: iconForType(item.item_type))
                                            .font(.system(size: 36))
                                            .foregroundStyle(.secondary)
                                        Text(item.item_type)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(28)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 160)

                            // Title & Subtitle
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.file_name.isEmpty ? "(unnamed)" : item.file_name)
                                    .font(.headline)
                                    .textSelection(.enabled)
                                Text(formatISODate(item.date_time))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            // Action Grid (never overflows horizontally)
                            LazyVGrid(
                                columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                                spacing: 8
                            ) {
                                if !item.file_path.isEmpty && FileManager.default.fileExists(atPath: item.file_path) {
                                    if let img = NSImage(contentsOfFile: item.file_path) {
                                        Button {
                                            ClipboardService.copyImage(img)
                                            appState.statusBanner = "Copied image to clipboard"
                                        } label: {
                                            Label("Copy Image", systemImage: "doc.on.doc")
                                                .frame(maxWidth: .infinity)
                                        }
                                        Button {
                                            if let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                                                ImageEditorWindowController.shared.openStandaloneEditor(cgImage: cg) { edited in
                                                    ClipboardService.copyPNGData(edited)
                                                    appState.latestPreviewImage = NSImage(data: edited)
                                                }
                                            }
                                        } label: {
                                            Label("Annotate", systemImage: "pencil.and.outline")
                                                .frame(maxWidth: .infinity)
                                        }
                                        Button {
                                            OverlayToolsController.shared.pinImageToScreen(img)
                                        } label: {
                                            Label("Pin", systemImage: "pin")
                                                .frame(maxWidth: .infinity)
                                        }
                                    }
                                    Button {
                                        ClipboardService.revealInFinder(item.file_path)
                                    } label: {
                                        Label("Show in Finder", systemImage: "folder")
                                            .frame(maxWidth: .infinity)
                                    }
                                    Button {
                                        ClipboardService.copyText(item.file_path)
                                        appState.statusBanner = "Copied file path"
                                    } label: {
                                        Label("Copy Path", systemImage: "link.badge.plus")
                                            .frame(maxWidth: .infinity)
                                    }
                                }

                                if !item.primaryURL.isEmpty {
                                    Button {
                                        ClipboardService.copyText(item.primaryURL)
                                        appState.statusBanner = "Copied URL"
                                    } label: {
                                        Label("Copy URL", systemImage: "link")
                                            .frame(maxWidth: .infinity)
                                    }
                                    Button {
                                        ClipboardService.openURL(item.primaryURL)
                                    } label: {
                                        Label("Open URL", systemImage: "safari")
                                            .frame(maxWidth: .infinity)
                                    }
                                }

                                Button(role: .destructive) {
                                    Task {
                                        let deletedID = item.id
                                        try? await appState.core.deleteHistory(ids: [deletedID])
                                        await appState.refreshHistory()
                                        if selectedID == deletedID {
                                            selectedID = appState.historyItems.first?.id
                                        }
                                    }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                        .frame(maxWidth: .infinity)
                                }
                            }

                            // Structured Metadata Box
                            GroupBox("Metadata") {
                                VStack(alignment: .leading, spacing: 8) {
                                    DetailLine(key: "Record ID", value: "#\(item.id)")
                                    DetailLine(key: "Type", value: item.item_type)
                                    if let dims = item.tags["Dimensions"], !dims.isEmpty {
                                        DetailLine(key: "Dimensions", value: "\(dims) px")
                                    }
                                    if let proc = item.tags["ProcessName"], !proc.isEmpty {
                                        DetailLine(key: "Application", value: proc)
                                    }
                                    if let title = item.tags["WindowTitle"], !title.isEmpty {
                                        DetailLine(key: "Window Title", value: title)
                                    }
                                    if !item.host.isEmpty {
                                        DetailLine(key: "Upload Host", value: item.host)
                                    }
                                    if !item.url.isEmpty {
                                        DetailLine(key: "URL", value: item.url)
                                    }
                                    if !item.shortened_url.isEmpty {
                                        DetailLine(key: "Short URL", value: item.shortened_url)
                                    }
                                    if !item.deletion_url.isEmpty {
                                        DetailLine(key: "Deletion URL", value: item.deletion_url)
                                    }
                                    if !item.file_path.isEmpty {
                                        DetailLine(key: "Local Path", value: item.file_path)
                                    }
                                }
                                .padding(6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(16)
                    }
                } else {
                    ContentUnavailableView("No Item Selected", systemImage: "sidebar.right")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 350)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Capture & Upload History")
        .onAppear {
            if selectedID == nil {
                selectedID = appState.historyItems.first?.id
            }
        }
        .onChange(of: appState.historyItems) { _, newItems in
            if selectedID == nil || !newItems.contains(where: { $0.id == selectedID }) {
                selectedID = newItems.first?.id
            }
        }
    }

    @ViewBuilder
    private func historyContextMenu(for item: HistoryItem) -> some View {
        if !item.primaryURL.isEmpty {
            Button("Copy URL") { ClipboardService.copyText(item.primaryURL) }
            Button("Copy Markdown Image") {
                let res = UploadResult(
                    url: item.url, thumbnail_url: item.thumbnail_url,
                    deletion_url: item.deletion_url, shortened_url: item.shortened_url,
                    share_url: "", host: item.host, response_text: "",
                    upload_duration_ms: 0, errors: []
                )
                if let md = try? appState.core.formatUploadLink(result: res, format: .MarkdownImage) {
                    ClipboardService.copyText(md)
                }
            }
            Button("Open URL") { ClipboardService.openURL(item.primaryURL) }
        }
        if !item.file_path.isEmpty && FileManager.default.fileExists(atPath: item.file_path) {
            Button("Copy Image") {
                if let data = try? Data(contentsOf: URL(fileURLWithPath: item.file_path)) {
                    ClipboardService.copyPNGData(data)
                }
            }
            Button("Copy File Path") { ClipboardService.copyText(item.file_path) }
            Button("Reveal in Finder") { ClipboardService.revealInFinder(item.file_path) }
            Button("Annotate in Editor") {
                if let img = NSImage(contentsOfFile: item.file_path),
                   let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    ImageEditorWindowController.shared.openStandaloneEditor(cgImage: cg) { edited in
                        ClipboardService.copyPNGData(edited)
                    }
                }
            }
            Button("Pin to Screen") {
                if let img = NSImage(contentsOfFile: item.file_path) {
                    OverlayToolsController.shared.pinImageToScreen(img)
                }
            }
        }
        Divider()
        Button("Delete", role: .destructive) {
            Task {
                try? await appState.core.deleteHistory(ids: [item.id])
                await appState.refreshHistory()
            }
        }
    }

    private func iconForType(_ t: String) -> String {
        switch t.lowercased() {
        case "image": return "photo"
        case "video": return "video"
        case "text": return "doc.text"
        default: return "doc"
        }
    }

    private func importShareXJSON() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        Task {
            if let count = try? await appState.core.importShareXHistory(jsonText: text) {
                appState.statusBanner = "Imported \(count) ShareX history entries"
                await appState.refreshHistory()
            }
        }
    }
}

private struct HistoryRowView: View {
    let item: HistoryItem

    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail badge
            Group {
                if !item.file_path.isEmpty,
                   FileManager.default.fileExists(atPath: item.file_path),
                   let thumb = NSImage(contentsOfFile: item.file_path) {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Color.secondary.opacity(0.12)
                        Image(systemName: item.item_type.lowercased() == "video" ? "video.fill" : "photo")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 48, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.file_name.isEmpty ? "(unnamed)" : item.file_name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(item.item_type)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.16)))

                    if let proc = item.tags["ProcessName"], !proc.isEmpty {
                        Text(proc)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.12)))
                    }

                    if !item.host.isEmpty {
                        Text(item.host)
                            .font(.caption2.bold())
                            .foregroundStyle(.blue)
                    }

                    Text(formatISODate(item.date_time))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if !item.primaryURL.isEmpty {
                Image(systemName: "link")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct DetailLine: View {
    let key: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key)
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private func formatISODate(_ raw: String) -> String {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let fallbackISO = ISO8601DateFormatter()
    guard let date = iso.date(from: raw) ?? fallbackISO.date(from: raw) else {
        return raw
    }
    let df = DateFormatter()
    df.dateStyle = .medium
    df.timeStyle = .medium
    return df.string(from: date)
}
