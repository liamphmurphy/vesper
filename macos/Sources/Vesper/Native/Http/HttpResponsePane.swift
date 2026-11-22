import SwiftUI
import VesperCore

enum HttpResponseTab: String, CaseIterable, Identifiable {
    case body
    case headers
    case request
    case history

    var id: String { rawValue }
}

struct HttpResponsePane: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let activeExecution: HttpExecution?
    let history: [HttpExecution]
    let isRunning: Bool
    let isLoadingHistory: Bool
    let historyError: APIError?
    let onRetryHistory: () -> Void
    let onSelectExecution: (HttpExecution) -> Void
    @Binding var selectedTab: HttpResponseTab

    @State private var prettyMode = true
    @State private var highlightedBody: AttributedString?
    @State private var highlightedKey = ""
    @State private var copiedBody = false

    var body: some View {
        let contentType = activeExecution.flatMap { HttpClientLogic.contentType(from: $0.responseHeaders) }
        let preview = activeExecution.map { HttpClientLogic.formatBodyPreview($0.responseBody, contentType: contentType) }
        let displayText = activeExecution.map { prettyMode ? (preview?.formatted ?? $0.responseBody) : $0.responseBody } ?? ""
        let highlightTaskId = "\(activeExecution?.id ?? "none")|\(prettyMode)|\(theme.mode.rawValue)|\(theme.colors["viz-1"] ?? "")|\(displayText.utf8.count)"

        VStack(spacing: 0) {
            headerBar
            Divider().overlay(theme.palette.border)
            ScrollView {
                tabContent(preview: preview, displayText: displayText, highlightTaskId: highlightTaskId)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(theme.palette.background)
        .task(id: highlightTaskId) {
            guard prettyMode,
                  let preview,
                  let language = preview.shikiLanguage,
                  !displayText.isEmpty,
                  displayText.utf8.count <= HttpClientLogic.maxHighlightBytes
            else {
                highlightedBody = nil
                highlightedKey = highlightTaskId
                return
            }

            let palette = CodePalette(theme: theme)
            let isDark = theme.mode == .dark
            let fallbackInk = theme.palette.text
            let tokens = await CodeHighlighter.shared.highlight(displayText, language: language)
            guard !Task.isCancelled else { return }
            if let tokens, !tokens.isEmpty {
                highlightedBody = Self.buildHighlightedText(
                    tokens: tokens,
                    palette: palette,
                    isDark: isDark,
                    fallbackInk: fallbackInk
                )
            } else {
                highlightedBody = nil
            }
            highlightedKey = highlightTaskId
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                statusSummary
                Spacer(minLength: 8)
                tabStrip
            }
            VStack(alignment: .leading, spacing: 6) {
                statusSummary
                tabStrip
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var statusSummary: some View {
        if isRunning {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Sending\u{2026}")
                    .vesperText(.small, theme)
                    .foregroundStyle(theme.palette.secondaryText)
            }
        } else if let exec = activeExecution {
            let colors = HttpStyle.statusColors(statusCode: exec.statusCode, error: exec.error, theme: theme)
            HStack(spacing: 8) {
                Text(HttpClientLogic.statusBadgeText(statusCode: exec.statusCode, statusText: exec.statusText, error: exec.error))
                    .font(.system(size: theme.pointSize(.small), weight: .bold, design: .monospaced))
                    .foregroundStyle(colors.fg)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(colors.bg, in: RoundedRectangle(cornerRadius: 5))

                Text("\(exec.durationMs) ms")
                    .font(theme.font(.mono))
                    .foregroundStyle(theme.palette.secondaryText)

                Text(HttpClientLogic.formatBytes(exec.sizeBytes))
                    .font(theme.font(.mono))
                    .foregroundStyle(theme.palette.tertiaryText)

                if !exec.environmentName.isEmpty {
                    Text(exec.environmentName)
                        .vesperText(.small, theme)
                        .foregroundStyle(theme.palette.secondaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 4))
                }
            }
        } else {
            Text("No response yet \u{2014} press Send (\u{2318}\u{21B5})")
                .vesperText(.small, theme)
                .foregroundStyle(theme.palette.tertiaryText)
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 4) {
            ForEach(HttpResponseTab.allCases) { tab in
                let active = selectedTab == tab
                Button {
                    selectedTab = tab
                } label: {
                    Text(tabLabel(tab))
                        .font(.system(size: theme.pointSize(.small), weight: .medium))
                        .foregroundStyle(active ? theme.palette.text : theme.palette.secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(active ? theme.palette.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func tabLabel(_ tab: HttpResponseTab) -> String {
        switch tab {
        case .body:
            return "Body"
        case .headers:
            let count = activeExecution?.responseHeaders.count ?? 0
            return count > 0 ? "Headers (\(count))" : "Headers"
        case .request:
            return "Request"
        case .history:
            return "History (\(history.count))"
        }
    }

    // MARK: - Tab Content

    @ViewBuilder
    private func tabContent(
        preview: HttpClientLogic.HttpBodyPreview?,
        displayText: String,
        highlightTaskId: String
    ) -> some View {
        switch selectedTab {
        case .history:
            historyView

        case .body:
            if let exec = activeExecution {
                if let error = exec.error {
                    errorBanner(error)
                } else {
                    bodyView(
                        exec: exec,
                        preview: preview,
                        displayText: displayText,
                        highlightTaskId: highlightTaskId
                    )
                }
            } else {
                Text("Run the request to see headers, timing, and formatted body output.")
                    .vesperText(.small, theme)
                    .foregroundStyle(theme.palette.tertiaryText)
            }

        case .headers:
            if let exec = activeExecution {
                if let error = exec.error {
                    errorBanner(error)
                } else {
                    headersView(exec.responseHeaders)
                }
            } else {
                Text("Run the request to inspect response headers.")
                    .vesperText(.small, theme)
                    .foregroundStyle(theme.palette.tertiaryText)
            }

        case .request:
            if let exec = activeExecution {
                sentRequestView(exec)
            } else {
                Text("Run the request to inspect the resolved URL, redacted headers, and sent body.")
                    .vesperText(.small, theme)
                    .foregroundStyle(theme.palette.tertiaryText)
            }
        }
    }

    private func errorBanner(_ error: String) -> some View {
        let colors = HttpStyle.statusColors(statusCode: 0, error: error, theme: theme)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Request Error")
                    .font(.system(size: theme.pointSize(.small), weight: .semibold))
                    .foregroundStyle(colors.fg)
                Spacer()
                Button("Copy") {
                    copyText(error, toastTitle: "Copied error")
                }
                .buttonStyle(.vesper())
            }
            Text(error)
                .font(theme.font(.mono))
                .foregroundStyle(colors.fg)
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.bg, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(colors.fg.opacity(0.35)))
    }

    private func bodyView(
        exec: HttpExecution,
        preview: HttpClientLogic.HttpBodyPreview?,
        displayText: String,
        highlightTaskId: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if exec.responseTruncated {
                    TonePill(label: "Response truncated at 2 MiB", tone: "human")
                }
                if let preview {
                    TonePill(label: preview.detectedKind.uppercased(), tone: "neutral")
                }

                Spacer(minLength: 8)

                HStack(spacing: 2) {
                    modeToggleButton(title: "Pretty", active: prettyMode) { prettyMode = true }
                    modeToggleButton(title: "Raw", active: !prettyMode) { prettyMode = false }
                }
                .padding(2)
                .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.palette.border))

                Button {
                    copyText(displayText, toastTitle: "Copied response body")
                    copiedBody = true
                    Task {
                        try? await Task.sleep(for: .milliseconds(1500))
                        copiedBody = false
                    }
                } label: {
                    Label(copiedBody ? "Copied" : "Copy body", systemImage: copiedBody ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.vesper())
            }

            if prettyMode,
               preview?.shikiLanguage != nil,
               displayText.utf8.count > HttpClientLogic.maxHighlightBytes
            {
                Text("Syntax highlighting skipped above 200 KB.")
                    .vesperText(.small, theme)
                    .foregroundStyle(theme.palette.tertiaryText)
            }

            ScrollView(.horizontal, showsIndicators: true) {
                Group {
                    if prettyMode,
                       highlightedKey == highlightTaskId,
                       let highlightedBody
                    {
                        Text(highlightedBody)
                    } else {
                        Text(displayText.isEmpty ? "(empty body)" : displayText)
                            .foregroundStyle(displayText.isEmpty ? theme.palette.tertiaryText : theme.palette.text)
                    }
                }
                .font(theme.font(.mono))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.palette.border))
        }
    }

    private func modeToggleButton(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: theme.pointSize(.small), weight: .medium))
            .foregroundStyle(active ? theme.palette.text : theme.palette.secondaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(active ? theme.palette.selected : .clear, in: RoundedRectangle(cornerRadius: 5))
            .buttonStyle(.plain)
    }

    private func headersView(_ headers: [String: [String]]) -> some View {
        let sortedKeys = headers.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return VStack(alignment: .leading, spacing: 0) {
            if sortedKeys.isEmpty {
                Text("No response headers.")
                    .vesperText(.small, theme)
                    .foregroundStyle(theme.palette.tertiaryText)
            } else {
                ForEach(Array(sortedKeys.enumerated()), id: \.element) { index, key in
                    let valueText = (headers[key] ?? []).joined(separator: ", ")
                    if index > 0 {
                        Divider().overlay(theme.palette.rowBorder)
                    }
                    HStack(alignment: .top, spacing: 12) {
                        Text(key)
                            .font(.system(size: theme.pointSize(.mono), weight: .semibold, design: .monospaced))
                            .foregroundStyle(theme.palette.secondaryText)
                            .frame(width: 180, alignment: .leading)
                            .textSelection(.enabled)

                        Text(valueText)
                            .font(theme.font(.mono))
                            .foregroundStyle(theme.palette.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 7)
                    .contextMenu {
                        Button("Copy value") { copyText(valueText, toastTitle: "Copied \(key)") }
                        Button("Copy header line") { copyText("\(key): \(valueText)", toastTitle: "Copied header") }
                    }
                }
            }
        }
    }

    private func sentRequestView(_ exec: HttpExecution) -> some View {
        let sortedHeaders = exec.requestHeaders.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let headersJSON = Self.prettyJSONDictionary(exec.requestHeaders)

        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("RESOLVED URL")
                        .font(.system(size: theme.pointSize(.micro), weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(theme.palette.tertiaryText)
                    Spacer()
                    Button("Copy URL") {
                        copyText(exec.resolvedUrl, toastTitle: "Copied resolved URL")
                    }
                    .buttonStyle(.vesper())
                }
                Text("\(exec.method) \(exec.resolvedUrl)")
                    .font(theme.font(.mono))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.palette.border))
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("SENT HEADERS (SECRETS REDACTED)")
                        .font(.system(size: theme.pointSize(.micro), weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(theme.palette.tertiaryText)
                    Spacer()
                    if !sortedHeaders.isEmpty {
                        Button("Copy JSON") {
                            copyText(headersJSON, toastTitle: "Copied sent headers")
                        }
                        .buttonStyle(.vesper())
                    }
                }
                if sortedHeaders.isEmpty {
                    Text("(none)")
                        .font(theme.font(.mono))
                        .foregroundStyle(theme.palette.tertiaryText)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.palette.border))
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(sortedHeaders, id: \.self) { key in
                            HStack(alignment: .top, spacing: 12) {
                                Text(key)
                                    .font(.system(size: theme.pointSize(.mono), weight: .semibold, design: .monospaced))
                                    .foregroundStyle(theme.palette.secondaryText)
                                    .frame(width: 170, alignment: .leading)
                                Text(exec.requestHeaders[key] ?? "")
                                    .font(theme.font(.mono))
                                    .foregroundStyle(theme.palette.text)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.palette.border))
                }
            }

            if !exec.requestBody.isEmpty {
                let prettySentBody = HttpClientLogic.formatJSON(exec.requestBody) ?? exec.requestBody
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("SENT BODY")
                            .font(.system(size: theme.pointSize(.micro), weight: .semibold))
                            .tracking(0.5)
                            .foregroundStyle(theme.palette.tertiaryText)
                        Spacer()
                        Button("Copy body") {
                            copyText(prettySentBody, toastTitle: "Copied sent body")
                        }
                        .buttonStyle(.vesper())
                    }
                    ScrollView(.horizontal, showsIndicators: true) {
                        Text(prettySentBody)
                            .font(theme.font(.mono))
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.palette.border))
                }
            }
        }
    }

    @ViewBuilder
    private var historyView: some View {
        if isLoadingHistory && history.isEmpty {
            VStack(spacing: 8) {
                ForEach(0..<4, id: \.self) { _ in
                    SkeletonBar(height: 36)
                }
            }
        } else if let historyError, history.isEmpty {
            QueryErrorView(message: "Couldn\u{2019}t load execution history: \(historyError.userMessage)", retry: onRetryHistory)
        } else if history.isEmpty {
            Text("No recorded runs for this request yet.")
                .vesperText(.small, theme)
                .foregroundStyle(theme.palette.tertiaryText)
        } else {
            VStack(spacing: 6) {
                ForEach(history) { exec in
                    let colors = HttpStyle.statusColors(statusCode: exec.statusCode, error: exec.error, theme: theme)
                    let selected = exec.id == activeExecution?.id
                    Button {
                        onSelectExecution(exec)
                    } label: {
                        HStack(spacing: 10) {
                            Text(exec.error != nil ? "ERR" : "\(exec.statusCode)")
                                .font(.system(size: theme.pointSize(.small), weight: .bold, design: .monospaced))
                                .foregroundStyle(colors.fg)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(colors.bg, in: RoundedRectangle(cornerRadius: 4))

                            Text(exec.method)
                                .font(.system(size: theme.pointSize(.small), weight: .semibold, design: .monospaced))
                                .foregroundStyle(HttpStyle.methodColor(exec.method, theme: theme))

                            Text(exec.resolvedUrl)
                                .font(theme.font(.mono))
                                .foregroundStyle(theme.palette.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer(minLength: 8)

                            if !exec.environmentName.isEmpty {
                                Text(exec.environmentName)
                                    .vesperText(.small, theme)
                                    .foregroundStyle(theme.palette.tertiaryText)
                            }
                            Text("\(exec.durationMs) ms")
                                .font(theme.font(.mono))
                                .foregroundStyle(theme.palette.tertiaryText)
                            let ago = APIDate.shortAgo(exec.createdAt)
                            if !ago.isEmpty {
                                Text(ago)
                                    .vesperText(.small, theme)
                                    .foregroundStyle(theme.palette.tertiaryText)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(selected ? theme.palette.selected : theme.palette.surface, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? theme.palette.accent : theme.palette.border))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Helpers

    private func copyText(_ text: String, toastTitle: String) {
        context.copyToClipboard(text)
        context.showToast(ToastItemModel(id: "http.copy", title: toastTitle, tone: .success))
    }

    private static func prettyJSONDictionary(_ dict: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ),
            let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    private static func buildHighlightedText(
        tokens: [[CodeToken]],
        palette: CodePalette,
        isDark: Bool,
        fallbackInk: Color
    ) -> AttributedString {
        var result = AttributedString()
        var containers: [String: AttributeContainer] = [:]
        for (lineIndex, lineTokens) in tokens.enumerated() {
            if lineIndex > 0 {
                result.append(AttributedString("\n"))
            }
            for token in lineTokens where !token.content.isEmpty {
                let rawHex = isDark ? (token.dark ?? token.light) : (token.light ?? token.dark)
                let mappedHex = palette.color(for: rawHex)
                let container: AttributeContainer
                if let cached = containers[mappedHex] {
                    container = cached
                } else {
                    var next = AttributeContainer()
                    next[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] =
                        HttpStyle.color(fromRGBAHex: mappedHex) ?? fallbackInk
                    containers[mappedHex] = next
                    container = next
                }
                result.append(AttributedString(token.content, attributes: container))
            }
        }
        return result
    }
}
