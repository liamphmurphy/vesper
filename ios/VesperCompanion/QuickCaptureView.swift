import SwiftUI
import VesperCore

struct QuickCaptureView: View {
    let connection: CompanionConnectionManager

    @State private var text = ""
    @State private var saving = false
    @State private var confirmation: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Quick Note to Knowledge Inbox") {
                    TextEditor(text: $text)
                        .frame(minHeight: 180)
                }
                Section {
                    Button {
                        Task { await captureNote() }
                    } label: {
                        if saving {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Label("Save to Inbox", systemImage: "tray.and.arrow.down.fill")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || connection.apiClient == nil)
                }
                if let confirmation {
                    Section {
                        Label(confirmation, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Quick Capture")
        }
    }

    private func captureNote() async {
        guard let client = connection.apiClient else { return }
        switch Capture.buildCaptureRequest(CaptureInput(kind: .note, text: text)) {
        case .failure(let err):
            errorMessage = err.message
        case .success(let call):
            saving = true
            errorMessage = nil
            confirmation = nil
            defer { saving = false }
            do {
                try await client.send(call)
                text = ""
                confirmation = "Saved to your Knowledge Inbox."
            } catch {
                errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            }
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
