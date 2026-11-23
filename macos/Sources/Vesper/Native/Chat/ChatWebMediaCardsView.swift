import SwiftUI
import VesperCore

// MARK: - Proxied Web & Article Image Gallery

struct ChatGalleryCardView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let messageId: String
    let spec: ChatGallerySpec

    @State private var savedURLs: Set<String> = []
    @State private var savingURL: String?

    private var previewRequest: APIRequest<API.LinkPreviews> {
        API.listLinkPreviews(messageId: messageId)
    }

    var body: some View {
        let p = theme.palette
        let previews = context.store.entry(previewRequest).data?.previews ?? []
        let byURL = Dictionary(uniqueKeysWithValues: previews.map { ($0.url, $0) })

        VStack(alignment: .leading, spacing: 10) {
            if let title = spec.title, !title.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .foregroundStyle(p.accent)
                    Text(title)
                        .font(.system(size: theme.pointSize(.body), weight: .semibold))
                        .foregroundStyle(p.text)
                    Spacer(minLength: 4)
                    Text("\(spec.items.count) \(spec.items.count == 1 ? "image" : "images")")
                        .font(.system(size: theme.pointSize(.micro)))
                        .foregroundStyle(p.tertiaryText)
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 10)], spacing: 10) {
                ForEach(Array(spec.items.enumerated()), id: \.offset) { idx, item in
                    galleryTile(item: item, index: idx, previews: byURL)
                }
            }
        }
        .padding(12)
        .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
        .task(id: messageId) {
            context.store.load(previewRequest)
        }
    }

    private func galleryTile(
        item: ChatGalleryItem,
        index: Int,
        previews: [String: API.LinkPreview]
    ) -> some View {
        let p = theme.palette
        let imgPreview = item.image.flatMap { previews[$0] }
        let pagePreview = item.url.flatMap { previews[$0] }
        let proxyImageURL = imgPreview?.imageUrl ?? pagePreview?.imageUrl
        let host = item.source ?? pagePreview?.site ?? ChatMediaURL.hostLabel(item.url ?? item.image)
        let saveURL = item.url ?? item.image
        let isSaved = (pagePreview?.saved == true || imgPreview?.saved == true) || (saveURL.map { savedURLs.contains($0) } ?? false)

        return VStack(alignment: .leading, spacing: 6) {
            Button {
                if let proxyImageURL {
                    let resolved = context.resolvedURL(proxyImageURL)?.absoluteString ?? proxyImageURL
                    context.showQuickLook([
                        QuickLookItem(
                            url: resolved,
                            title: item.caption ?? spec.title ?? "Image \(index + 1)",
                            filename: "image-\(index + 1).png",
                            contentType: "image/png"
                        )
                    ])
                } else if let url = item.url {
                    context.openExternal(url)
                }
            } label: {
                ZStack(alignment: .bottomLeading) {
                    if let proxyImageURL {
                        AuthenticatedImageView(source: proxyImageURL, maxPixel: 640) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(height: 132)
                                .frame(maxWidth: .infinity)
                                .clipped()
                        } placeholder: {
                            Rectangle()
                                .fill(p.surface)
                                .frame(height: 132)
                                .overlay(ProgressView().controlSize(.small))
                        } failure: {
                            Rectangle()
                                .fill(p.surface)
                                .frame(height: 132)
                                .overlay(Image(systemName: "photo").foregroundStyle(p.tertiaryText))
                        }
                    } else {
                        Rectangle()
                            .fill(p.surface)
                            .frame(height: 132)
                            .overlay(Image(systemName: "photo").foregroundStyle(p.tertiaryText))
                    }

                    if !host.isEmpty {
                        Text(host)
                            .font(.system(size: theme.pointSize(.micro), weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.62), in: Capsule())
                            .padding(6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            if let caption = item.caption, !caption.isEmpty {
                Text(caption)
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(p.text)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                if let url = item.url {
                    Button {
                        context.openExternal(url)
                    } label: {
                        Label("Source", systemImage: "arrow.up.right.square")
                            .font(.system(size: theme.pointSize(.micro), weight: .medium))
                            .foregroundStyle(p.accent)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 4)
                if let saveURL {
                    saveButton(url: saveURL, isSaved: isSaved)
                }
            }
        }
        .padding(8)
        .background(p.surface, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(p.border))
    }

    @ViewBuilder
    private func saveButton(url: String, isSaved: Bool) -> some View {
        let p = theme.palette
        if isSaved {
            Label("Saved", systemImage: "checkmark")
                .font(.system(size: theme.pointSize(.micro), weight: .semibold))
                .foregroundStyle(p.accent)
        } else {
            Button {
                saveLink(url)
            } label: {
                Label(savingURL == url ? "Saving…" : "Save", systemImage: "bookmark")
                    .font(.system(size: theme.pointSize(.micro), weight: .medium))
                    .foregroundStyle(p.secondaryText)
            }
            .buttonStyle(.plain)
            .disabled(savingURL == url)
        }
    }

    private func saveLink(_ url: String) {
        savingURL = url
        Task {
            defer { savingURL = nil }
            do {
                _ = try await context.store.mutate(
                    API.saveLibraryLink(body: API.LibraryLinkSave(messageId: messageId, url: url)),
                    invalidating: QueryInvalidation(resources: ["library"])
                )
                savedURLs.insert(url)
            } catch {
                context.showToast(ToastItemModel(id: "gallery.save.err", title: "Couldn’t save link", tone: .error))
            }
        }
    }
}

// MARK: - Product Cards

struct ChatProductCardView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let messageId: String
    let spec: ChatProductSpec

    @State private var savedURLs: Set<String> = []
    @State private var savingURL: String?

    private var previewRequest: APIRequest<API.LinkPreviews> {
        API.listLinkPreviews(messageId: messageId)
    }

    var body: some View {
        let p = theme.palette
        let previews = context.store.entry(previewRequest).data?.previews ?? []
        let byURL = Dictionary(uniqueKeysWithValues: previews.map { ($0.url, $0) })

        VStack(alignment: .leading, spacing: 8) {
            if let title = spec.title, !title.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "tag")
                        .foregroundStyle(p.accent)
                    Text(title)
                        .font(.system(size: theme.pointSize(.body), weight: .semibold))
                        .foregroundStyle(p.text)
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 10)], spacing: 10) {
                ForEach(Array(spec.items.enumerated()), id: \.offset) { _, item in
                    productTile(item: item, previews: byURL)
                }
            }
        }
        .task(id: messageId) {
            context.store.load(previewRequest)
        }
    }

    private func productTile(item: ChatProductItem, previews: [String: API.LinkPreview]) -> some View {
        let p = theme.palette
        let imgPreview = item.image.flatMap { previews[$0] }
        let pagePreview = item.url.flatMap { previews[$0] }
        let proxyImageURL = imgPreview?.imageUrl ?? pagePreview?.imageUrl
        let host = pagePreview?.site.isEmpty == false ? pagePreview!.site : ChatMediaURL.hostLabel(item.url ?? item.image)
        let saveURL = item.url ?? item.image
        let isSaved = (pagePreview?.saved == true || imgPreview?.saved == true) || (saveURL.map { savedURLs.contains($0) } ?? false)

        return VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if let proxyImageURL {
                    AuthenticatedImageView(source: proxyImageURL, maxPixel: 640) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(height: 136)
                            .frame(maxWidth: .infinity)
                            .clipped()
                    } placeholder: {
                        Rectangle()
                            .fill(theme.swiftUIColor("surface-sunken", fallback: p.surface))
                            .frame(height: 136)
                            .overlay(ProgressView().controlSize(.small))
                    } failure: {
                        Rectangle()
                            .fill(theme.swiftUIColor("surface-sunken", fallback: p.surface))
                            .frame(height: 136)
                            .overlay(Image(systemName: "bag").foregroundStyle(p.tertiaryText))
                    }
                } else {
                    Rectangle()
                        .fill(theme.swiftUIColor("surface-sunken", fallback: p.surface))
                        .frame(height: 112)
                        .overlay(Image(systemName: "bag").foregroundStyle(p.tertiaryText))
                }

                if let badge = item.badge, !badge.isEmpty {
                    Text(badge)
                        .font(.system(size: theme.pointSize(.micro), weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(p.accent, in: Capsule())
                        .padding(8)
                }

                if let price = item.price, !price.isEmpty {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Text(price)
                                .font(.system(size: theme.pointSize(.small), weight: .semibold, design: .monospaced))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 6))
                                .padding(8)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack(alignment: .top, spacing: 6) {
                Text(item.name)
                    .font(.system(size: theme.pointSize(.body), weight: .semibold))
                    .foregroundStyle(p.text)
                    .lineLimit(2)
                Spacer(minLength: 4)
                if let rating = item.rating, !rating.isEmpty {
                    TonePill(label: "★ \(rating)", tone: "review")
                }
            }

            if !host.isEmpty {
                Text(host)
                    .font(.system(size: theme.pointSize(.micro)))
                    .foregroundStyle(p.tertiaryText)
            }

            if let desc = item.description ?? (pagePreview?.description.isEmpty == false ? pagePreview?.description : nil) {
                Text(desc)
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(p.secondaryText)
                    .lineLimit(2)
            }

            if !item.specs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(item.specs, id: \.self) { specText in
                            Text(specText)
                                .font(.system(size: theme.pointSize(.micro)))
                                .foregroundStyle(p.secondaryText)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(theme.swiftUIColor("surface-sunken", fallback: p.surface), in: RoundedRectangle(cornerRadius: 5))
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(p.rowBorder))
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                if let url = item.url {
                    Button {
                        context.openExternal(url)
                    } label: {
                        Label("View product", systemImage: "arrow.up.right.square")
                            .font(.system(size: theme.pointSize(.small), weight: .medium))
                            .foregroundStyle(p.accent)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 4)
                if let saveURL {
                    if isSaved {
                        Label("Saved", systemImage: "checkmark")
                            .font(.system(size: theme.pointSize(.micro), weight: .semibold))
                            .foregroundStyle(p.accent)
                    } else {
                        Button {
                            savingURL = saveURL
                            Task {
                                defer { savingURL = nil }
                                if (try? await context.store.mutate(
                                    API.saveLibraryLink(body: API.LibraryLinkSave(messageId: messageId, url: saveURL)),
                                    invalidating: QueryInvalidation(resources: ["library"])
                                )) != nil {
                                    savedURLs.insert(saveURL)
                                }
                            }
                        } label: {
                            Label(savingURL == saveURL ? "Saving…" : "Save", systemImage: "bookmark")
                                .font(.system(size: theme.pointSize(.micro), weight: .medium))
                                .foregroundStyle(p.secondaryText)
                        }
                        .buttonStyle(.plain)
                        .disabled(savingURL == saveURL)
                    }
                }
            }
        }
        .padding(10)
        .background(p.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
    }
}

// MARK: - Citation Preview Popover Card

struct ChatCitationPopoverCardView: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    let source: ChatListedSource
    let preview: API.LinkPreview?
    let onDismiss: () -> Void

    var body: some View {
        let p = theme.palette
        let title = (preview?.title.isEmpty == false ? preview?.title : nil)
            ?? (!source.title.isEmpty ? source.title : (source.ref ?? ChatMediaURL.hostLabel(source.url)))
        let host = (preview?.site.isEmpty == false ? preview?.site : nil)
            ?? (!source.url.isEmpty ? ChatMediaURL.hostLabel(source.url) : (source.ref ?? "Knowledge"))

        VStack(alignment: .leading, spacing: 8) {
            if let imageUrl = preview?.imageUrl, !imageUrl.isEmpty {
                AuthenticatedImageView(source: imageUrl, maxPixel: 560) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 120)
                        .frame(maxWidth: .infinity)
                        .clipped()
                } placeholder: {
                    Rectangle()
                        .fill(theme.swiftUIColor("surface-sunken", fallback: p.surface))
                        .frame(height: 120)
                        .overlay(ProgressView().controlSize(.small))
                } failure: {
                    EmptyView()
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            HStack(spacing: 6) {
                if let n = source.number {
                    Text("\(n)")
                        .font(.system(size: theme.pointSize(.micro), weight: .bold, design: .monospaced))
                        .foregroundStyle(p.accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(p.selected, in: RoundedRectangle(cornerRadius: 4))
                }
                Text(source.url.isEmpty ? "KNOWLEDGE" : "WEB")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(p.tertiaryText)
                Text("·")
                    .foregroundStyle(p.tertiaryText)
                Text(host)
                    .font(.system(size: theme.pointSize(.micro)))
                    .foregroundStyle(p.tertiaryText)
                    .lineLimit(1)
            }

            Text(title)
                .font(.system(size: theme.pointSize(.body), weight: .semibold))
                .foregroundStyle(p.text)
                .lineLimit(3)

            if let desc = preview?.description, !desc.isEmpty {
                Text(desc)
                    .font(.system(size: theme.pointSize(.small)))
                    .foregroundStyle(p.secondaryText)
                    .lineLimit(3)
            }

            Divider()

            HStack {
                Spacer()
                Button {
                    onDismiss()
                    if !source.url.isEmpty {
                        context.openExternal(source.url)
                    } else if let ref = source.ref {
                        context.navigate("/wiki/\(ref)")
                    }
                } label: {
                    Label(source.url.isEmpty ? "Open page" : "Open link", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.vesper(.primary))
            }
        }
        .padding(12)
        .frame(width: 290)
    }
}
