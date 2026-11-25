import SwiftUI
import UIKit
import VesperCore

// MARK: - Camera Sheet (UIImagePickerController)

struct CameraCaptureSheet: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isCameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onImage: onImage, dismiss: dismiss)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = Self.isCameraAvailable ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onImage: (UIImage) -> Void
        let dismiss: DismissAction

        init(onImage: @escaping (UIImage) -> Void, dismiss: DismissAction) {
            self.onImage = onImage
            self.dismiss = dismiss
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let img = (info[.editedImage] ?? info[.originalImage]) as? UIImage {
                onImage(img)
            }
            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }
    }
}

// MARK: - Image Preparation Helper

enum ImageUploadHelper {
    struct PreparedPhoto: Identifiable {
        let id = UUID()
        let fileName: String
        let mime: String
        let data: Data
        let thumbnail: UIImage
    }

    static func prepare(_ image: UIImage, preferredName: String? = nil, maxDimension: CGFloat = 2048) -> PreparedPhoto? {
        let normalized = resizedIfNeeded(image, maxDimension: maxDimension)
        guard let jpeg = normalized.jpegData(compressionQuality: 0.84) else { return nil }
        let name: String
        if let raw = preferredName?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let safe = raw.replacingOccurrences(of: "/", with: "-")
            name = safe.lowercased().hasSuffix(".jpg") || safe.lowercased().hasSuffix(".jpeg") ? safe : "\(safe).jpg"
        } else {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMdd-HHmmss"
            name = "photo-\(fmt.string(from: Date())).jpg"
        }
        return PreparedPhoto(fileName: name, mime: "image/jpeg", data: jpeg, thumbnail: normalized)
    }

    private static func resizedIfNeeded(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0 else { return image }
        let scale = maxDimension / longest
        let target = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
        let renderer = UIGraphicsImageRenderer(size: target)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

// MARK: - Authenticated Remote Image Loader (uses pinned TLS + Bearer token)

@MainActor
final class CompanionImageCache {
    static let shared = CompanionImageCache()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 80
    }

    func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func store(_ image: UIImage, for key: String) {
        cache.setObject(image, forKey: key as NSString)
    }
}

struct AuthenticatedRemoteImage: View {
    let client: APIClient?
    let path: String
    var fallbackPath: String? = nil
    var contentMode: ContentMode = .fit
    var maxHeight: CGFloat? = 260
    var allowFullscreen: Bool = true

    @State private var image: UIImage?
    @State private var failed = false
    @State private var showFullscreen = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .frame(maxWidth: .infinity, maxHeight: maxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .onTapGesture {
                        if allowFullscreen { showFullscreen = true }
                    }
                    .sheet(isPresented: $showFullscreen) {
                        FullscreenImageSheet(image: image)
                    }
            } else if failed {
                HStack(spacing: 6) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .foregroundStyle(.secondary)
                    Text("Could not load image")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 72)
                    .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .task(id: path) {
            await load()
        }
    }

    private func load() async {
        if let cached = CompanionImageCache.shared.image(for: path) {
            image = cached
            return
        }
        guard let client else {
            failed = true
            return
        }
        if let loaded = await fetchImage(client: client, path: path) {
            CompanionImageCache.shared.store(loaded, for: path)
            image = loaded
            return
        }
        if let fallbackPath, let loaded = await fetchImage(client: client, path: fallbackPath) {
            CompanionImageCache.shared.store(loaded, for: path)
            image = loaded
            return
        }
        failed = true
    }

    private func fetchImage(client: APIClient, path: String) async -> UIImage? {
        guard let data = try? await client.fetchRaw(path, accept: "image/*,*/*") else { return nil }
        return UIImage(data: data)
    }
}

private struct FullscreenImageSheet: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1.0

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                scale = max(1.0, min(value, 4.0))
                            }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color.black)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
