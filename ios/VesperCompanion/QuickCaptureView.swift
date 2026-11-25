import PhotosUI
import SwiftUI
import UIKit
import VesperCore

struct QuickCaptureView: View {
    let connection: CompanionConnectionManager

    // Note capture state
    @State private var text = ""
    @State private var savingNote = false
    @State private var noteConfirmation: String?
    @State private var noteError: String?

    // Photo capture to Library state
    @State private var showCamera = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var capturedPhoto: ImageUploadHelper.PreparedPhoto?
    @State private var photoTitle = ""
    @State private var uploadingPhoto = false
    @State private var photoConfirmation: String?
    @State private var photoError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Quick Note to Knowledge Inbox") {
                    TextEditor(text: $text)
                        .frame(minHeight: 130)

                    Button {
                        Task { await captureNote() }
                    } label: {
                        if savingNote {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Label("Save Note to Inbox", systemImage: "tray.and.arrow.down.fill")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(savingNote || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || connection.apiClient == nil)

                    if let noteConfirmation {
                        Label(noteConfirmation, systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.green)
                    }
                    if let noteError {
                        Text(noteError)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }

                Section("Capture Photo to Library") {
                    HStack(spacing: 12) {
                        Button {
                            photoError = nil
                            photoConfirmation = nil
                            showCamera = true
                        } label: {
                            Label("Take Photo", systemImage: "camera.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!CameraCaptureSheet.isCameraAvailable)

                        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                            Label("Photo Library", systemImage: "photo.on.rectangle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }

                    if !CameraCaptureSheet.isCameraAvailable {
                        Text("Camera is unavailable on this device; use Photo Library instead.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let capturedPhoto {
                        VStack(alignment: .leading, spacing: 10) {
                            Image(uiImage: capturedPhoto.thumbnail)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: 220)
                                .clipShape(RoundedRectangle(cornerRadius: 10))

                            TextField("Optional name (e.g. whiteboard-notes)", text: $photoTitle)
                                .textInputAutocapitalization(.never)

                            HStack {
                                Button(role: .destructive) {
                                    self.capturedPhoto = nil
                                    photoTitle = ""
                                } label: {
                                    Label("Clear", systemImage: "trash")
                                }
                                .buttonStyle(.bordered)

                                Spacer()

                                Button {
                                    Task { await uploadPhotoToLibrary() }
                                } label: {
                                    if uploadingPhoto {
                                        ProgressView()
                                    } else {
                                        Label("Send to Library", systemImage: "arrow.up.circle.fill")
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(uploadingPhoto || connection.apiClient == nil)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    if let photoConfirmation {
                        Label(photoConfirmation, systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.green)
                    }
                    if let photoError {
                        Text(photoError)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Capture")
            .fullScreenCover(isPresented: $showCamera) {
                CameraCaptureSheet { image in
                    if let prepared = ImageUploadHelper.prepare(image) {
                        capturedPhoto = prepared
                        photoError = nil
                        photoConfirmation = nil
                    } else {
                        photoError = "Could not encode captured photo."
                    }
                }
                .ignoresSafeArea()
            }
            .onChange(of: selectedPhotoItem) { _, newItem in
                guard let newItem else { return }
                Task { await loadPickedPhoto(newItem) }
            }
        }
    }

    private func captureNote() async {
        guard let client = connection.apiClient else { return }
        switch Capture.buildCaptureRequest(CaptureInput(kind: .note, text: text)) {
        case .failure(let err):
            noteError = err.message
        case .success(let call):
            savingNote = true
            noteError = nil
            noteConfirmation = nil
            defer { savingNote = false }
            do {
                try await client.send(call)
                text = ""
                noteConfirmation = "Saved to your Knowledge Inbox."
            } catch {
                noteError = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    private func loadPickedPhoto(_ item: PhotosPickerItem) async {
        defer { selectedPhotoItem = nil }
        photoError = nil
        photoConfirmation = nil
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let prepared = ImageUploadHelper.prepare(image) else {
                photoError = "Could not load selected photo."
                return
            }
            capturedPhoto = prepared
        } catch {
            photoError = error.localizedDescription
        }
    }

    private func uploadPhotoToLibrary() async {
        guard let client = connection.apiClient, let capturedPhoto else { return }
        uploadingPhoto = true
        photoError = nil
        photoConfirmation = nil
        defer { uploadingPhoto = false }

        let finalPrepared: ImageUploadHelper.PreparedPhoto
        if !photoTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let renamed = ImageUploadHelper.prepare(capturedPhoto.thumbnail, preferredName: photoTitle) {
            finalPrepared = renamed
        } else {
            finalPrepared = capturedPhoto
        }

        do {
            let created = try await client.uploadLibraryItem(
                fileName: finalPrepared.fileName,
                mime: finalPrepared.mime,
                data: finalPrepared.data
            )
            self.capturedPhoto = nil
            photoTitle = ""
            photoConfirmation = "Sent “\(created.title.isEmpty ? finalPrepared.fileName : created.title)” to Library."
        } catch {
            photoError = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }
}

struct CompanionSettingsView: View {
    let connection: CompanionConnectionManager
    @State private var confirmUnpair = false

    var body: some View {
        NavigationStack {
            List {
                if let host = connection.pairedHost {
                    Section("Paired Mac") {
                        LabeledContent("Host", value: host.hostName)
                        LabeledContent("Device Name", value: host.deviceName)
                        LabeledContent("Port", value: "\(host.port)")
                        if case .connected(let transport, let url) = connection.state {
                            LabeledContent("Active Route", value: transport.displayName)
                            LabeledContent("Endpoint", value: url.absoluteString)
                        }
                        LabeledContent("TLS Cert Pin") {
                            Text(String(host.certSHA256.prefix(20)) + "…")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !host.lanHosts.isEmpty {
                        Section("Local Wi-Fi Addresses") {
                            ForEach(host.lanHosts, id: \.self) { h in
                                Text(h).font(.system(.body, design: .monospaced))
                            }
                        }
                    }

                    if !host.tailscaleHosts.isEmpty {
                        Section("Tailscale Addresses") {
                            ForEach(host.tailscaleHosts, id: \.self) { h in
                                Text(h).font(.system(.body, design: .monospaced))
                            }
                        }
                    }
                }

                Section {
                    Button("Reconnect Now") {
                        Task { await connection.reconnect() }
                    }
                    Button("Unpair This iPhone", role: .destructive) {
                        confirmUnpair = true
                    }
                }
            }
            .navigationTitle("Mac Connection")
            .confirmationDialog("Unpair this iPhone?", isPresented: $confirmUnpair, titleVisibility: .visible) {
                Button("Unpair", role: .destructive) {
                    connection.unpair()
                }
            } message: {
                Text("This clears the stored device token from your iPhone. You can also revoke the device in Vesper Settings on your Mac.")
            }
        }
    }
}
