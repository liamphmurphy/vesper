import Foundation
import SwiftUI
import UniformTypeIdentifiers
import VesperCore

struct HttpImportSheet: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let workspaceId: String
    let targetFolder: HttpFolder?
    let initialTab: HttpImportFormat
    let onImported: (HttpImportResult) -> Void
    let onDismiss: () -> Void

    @State private var tab: HttpImportFormat = .bru
    @State private var content = ""
    @State private var bruFiles: [HttpImportFile] = []
    @State private var zipBase64 = ""
    @State private var fileSummary = ""
    @State private var fileError: String?
    @State private var bruPickerOpen = false
    @State private var openApiPickerOpen = false
    @State private var importing = false
    @State private var submitError: String?

    private static let bruAllowedTypes: [UTType] = {
        var types: [UTType] = [.folder, .zip, .data]
        if let bru = UTType(filenameExtension: "bru") {
            types.insert(bru, at: 0)
        }
        return types
    }()

    private static let openApiAllowedTypes: [UTType] = {
        var types: [UTType] = [.json, .plainText]
        if let yaml = UTType(filenameExtension: "yaml") { types.append(yaml) }
        if let yml = UTType(filenameExtension: "yml") { types.append(yml) }
        return types
    }()

    init(
        workspaceId: String,
        targetFolder: HttpFolder?,
        initialTab: HttpImportFormat,
        onImported: @escaping (HttpImportResult) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.workspaceId = workspaceId
        self.targetFolder = targetFolder
        self.initialTab = initialTab
        self.onImported = onImported
        self.onDismiss = onDismiss
        _tab = State(initialValue: initialTab)
    }

    private var canSubmit: Bool {
        let hasText = !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch tab {
        case .bru:
            return hasText || !zipBase64.isEmpty || !bruFiles.isEmpty
        case .curl, .openapi:
            return hasText
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Divider().overlay(theme.palette.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    tabBar

                    switch tab {
                    case .bru:
                        brunoTab
                    case .curl:
                        curlTab
                    case .openapi:
                        openApiTab
                    }

                    if let submitError {
                        Text(submitError)
                            .vesperText(.small, theme)
                            .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(18)
            }

            Divider().overlay(theme.palette.border)
            sheetFooter
        }
        .frame(minWidth: 520, idealWidth: 600, minHeight: 440, idealHeight: 520)
        .background(theme.palette.background)
        .fileImporter(
            isPresented: $bruPickerOpen,
            allowedContentTypes: Self.bruAllowedTypes,
            allowsMultipleSelection: true
        ) { result in
            handleBrunoImportResult(result)
        }
        .fileImporter(
            isPresented: $openApiPickerOpen,
            allowedContentTypes: Self.openApiAllowedTypes,
            allowsMultipleSelection: false
        ) { result in
            handleOpenApiFileResult(result)
        }
    }

    // MARK: - Header & Tabs

    private var sheetHeader: some View {
        HStack {
            Text(targetFolder.map { "Import into \u{201C}\($0.name)\u{201D}" } ?? "Import into Workspace")
                .vesperText(.heading, theme)
                .foregroundStyle(theme.palette.text)
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(theme.palette.secondaryText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close import sheet")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(theme.palette.surface)
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(HttpImportFormat.allCases) { format in
                let active = tab == format
                Button {
                    tab = format
                    submitError = nil
                } label: {
                    Text(format.label)
                        .font(.system(size: theme.pointSize(.small), weight: .medium))
                        .foregroundStyle(active ? theme.palette.text : theme.palette.secondaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(active ? theme.palette.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.bottom, 4)
    }

    // MARK: - Tab Bodies

    private var brunoTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HttpField(
                label: "Choose .bru files, a Bruno folder, or a .zip archive",
                hint: "Supports nested folders, requests, auth blocks, and environments/*.bru"
            ) {
                HStack(spacing: 8) {
                    Button {
                        bruPickerOpen = true
                    } label: {
                        Label("Choose .bru / .zip / Folder\u{2026}", systemImage: "folder")
                    }
                    .buttonStyle(.vesper())

                    if !bruFiles.isEmpty || !zipBase64.isEmpty {
                        Button("Clear files") {
                            bruFiles = []
                            zipBase64 = ""
                            fileSummary = ""
                            fileError = nil
                        }
                        .buttonStyle(.vesper())
                    }
                }
            }

            if !fileSummary.isEmpty {
                Text(fileSummary)
                    .vesperText(.small, theme)
                    .foregroundStyle(theme.swiftUIColor("state-done", fallback: .green))
            }
            if let fileError {
                Text(fileError)
                    .vesperText(.small, theme)
                    .foregroundStyle(theme.swiftUIColor("pill-blocked-fg", fallback: .red))
            }

            HttpField(label: "Or paste a single .bru request") {
                monospacedEditor(
                    text: $content,
                    placeholder: "meta {\n  name: Get Users\n}\nget {\n  url: {{base_url}}/v1/users\n}",
                    minHeight: 170
                )
            }
        }
    }

    private var curlTab: some View {
        HttpField(
            label: "Paste a cURL command",
            hint: "Works with a browser\u{2019}s \u{201C}Copy as cURL\u{201D}. Becomes one request."
        ) {
            monospacedEditor(
                text: $content,
                placeholder: "curl -X POST \"https://api.example.com/v1/items\" -H \"Authorization: Bearer tok\" -d '{\"name\":\"test\"}'",
                minHeight: 200
            )
        }
    }

    private var openApiTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button {
                    openApiPickerOpen = true
                } label: {
                    Label("Load OpenAPI JSON / YAML file\u{2026}", systemImage: "doc")
                }
                .buttonStyle(.vesper())
                Spacer()
            }

            HttpField(label: "Paste OpenAPI 3 JSON or YAML") {
                monospacedEditor(
                    text: $content,
                    placeholder: "openapi: 3.0.3\nservers:\n  - url: https://api.example.com\npaths:\n  /v1/health:\n    get:\n      summary: Health",
                    minHeight: 210
                )
            }
        }
    }

    private func monospacedEditor(text: Binding<String>, placeholder: String, minHeight: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            if text.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(theme.font(.mono))
                    .foregroundStyle(theme.palette.tertiaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .allowsHitTesting(false)
            }
            TextEditor(text: text)
                .font(theme.font(.mono))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: minHeight)
        }
        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.palette.border))
    }

    // MARK: - Footer

    private var sheetFooter: some View {
        HStack {
            Spacer()
            Button("Cancel", action: onDismiss)
                .buttonStyle(.vesper())
                .keyboardShortcut(.cancelAction)
                .disabled(importing)

            Button {
                Task { await submit() }
            } label: {
                if importing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Importing\u{2026}")
                    }
                } else {
                    Text("Import")
                }
            }
            .buttonStyle(.vesper(.primary))
            .disabled(importing || !canSubmit)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(theme.palette.surface)
    }

    // MARK: - File Handling

    private func handleBrunoImportResult(_ result: Result<[URL], any Error>) {
        fileError = nil
        switch result {
        case .failure(let error):
            fileError = error.localizedDescription
        case .success(let urls):
            guard !urls.isEmpty else { return }
            do {
                let loaded = try Self.readBrunoURLs(urls)
                bruFiles = loaded.files
                zipBase64 = loaded.zipBase64
                fileSummary = loaded.summary
            } catch {
                bruFiles = []
                zipBase64 = ""
                fileSummary = ""
                fileError = error.localizedDescription
            }
        }
    }

    private func handleOpenApiFileResult(_ result: Result<[URL], any Error>) {
        submitError = nil
        switch result {
        case .failure(let error):
            submitError = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                content = try Self.readTextFile(url)
            } catch {
                submitError = error.localizedDescription
            }
        }
    }

    private static func readTextFile(_ url: URL) throws -> String {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return text
    }

    private static func readBrunoURLs(_ urls: [URL]) throws -> (files: [HttpImportFile], zipBase64: String, summary: String) {
        if urls.count == 1 && urls[0].pathExtension.lowercased() == "zip" {
            let url = urls[0]
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            return ([], data.base64EncodedString(), "Selected archive: \(url.lastPathComponent)")
        }

        var collected: [HttpImportFile] = []
        let fm = FileManager.default

        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }

            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                let rootPrefix = url.path.hasSuffix("/") ? url.path : url.path + "/"
                let rootName = url.lastPathComponent
                if let enumerator = fm.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) {
                    while let item = enumerator.nextObject() as? URL {
                        guard item.pathExtension.lowercased() == "bru" else { continue }
                        let rel = item.path.hasPrefix(rootPrefix)
                            ? String(item.path.dropFirst(rootPrefix.count))
                            : item.lastPathComponent
                        if let text = try? String(contentsOf: item, encoding: .utf8) {
                            collected.append(HttpImportFile(path: "\(rootName)/\(rel)", content: text))
                        }
                    }
                }
            } else if url.pathExtension.lowercased() == "bru" {
                let text = try String(contentsOf: url, encoding: .utf8)
                collected.append(HttpImportFile(path: url.lastPathComponent, content: text))
            }
        }

        guard !collected.isEmpty else {
            throw NSError(
                domain: "HttpImportSheet",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No .bru or .zip files found in the selection."]
            )
        }

        let summary = "Loaded \(collected.count) .bru file\(collected.count == 1 ? "" : "s")"
        return (collected, "", summary)
    }

    // MARK: - Submit

    private func submit() async {
        guard let client = context.store.client else {
            submitError = APIError.unauthorized.userMessage
            return
        }
        importing = true
        submitError = nil
        defer { importing = false }

        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let input: HttpImportInput
        switch tab {
        case .bru:
            input = HttpImportInput(
                format: .bru,
                content: trimmedContent.isEmpty ? nil : trimmedContent,
                zipBase64: zipBase64.isEmpty ? nil : zipBase64,
                files: bruFiles.isEmpty ? nil : bruFiles,
                folderId: targetFolder?.id
            )
        case .curl, .openapi:
            input = HttpImportInput(
                format: tab,
                content: trimmedContent,
                folderId: targetFolder?.id
            )
        }

        do {
            let result = try await client.send(
                HttpClientAPI.importCollection(workspaceId: workspaceId, body: input),
                timeout: 60
            )
            context.store.invalidate(HttpClientAPI.bundleInvalidation(workspaceId: workspaceId))
            let warningSuffix = result.warnings.isEmpty ? "" : " (\(result.warnings.count) warning(s))"
            context.showToast(
                ToastItemModel(
                    id: "http.import",
                    title: "Imported \(result.requestsCreated) request(s), \(result.foldersCreated) folder(s), \(result.environmentsCreated) env(s)\(warningSuffix)",
                    tone: .success
                )
            )
            onImported(result)
            onDismiss()
        } catch {
            let msg = (error as? APIError)?.userMessage ?? error.localizedDescription
            submitError = msg
            context.showToast(ToastItemModel(id: "http.import.error", title: "Import failed", description: msg, tone: .error))
        }
    }
}
