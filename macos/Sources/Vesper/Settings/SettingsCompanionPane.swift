import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import VesperCore

struct SettingsCompanionPane: View {
    let aux: AuxWindows

    @State private var status: CompanionStatusResponse?
    @State private var pairingCode: CompanionPairingCodeResponse?
    @State private var loading = false
    @State private var generating = false
    @State private var restarting = false
    @State private var errorMessage: String?
    @State private var copiedURI = false

    private var s: NativeSettings { aux.app?.settings.settings ?? NativeSettings() }

    private func bind<T>(_ keyPath: WritableKeyPath<NativeSettings, T>) -> Binding<T> {
        Binding(get: { s[keyPath: keyPath] }, set: { v in aux.update { $0[keyPath: keyPath] = v } })
    }

    var body: some View {
        Form {
            Section("Companion Access") {
                Toggle(isOn: bind(\.stack.companionEnabled)) {
                    Text("Allow iPhone Companion access")
                    Text("Starts an encrypted TLS listener so your paired iPhone can reach Vesper over local Wi-Fi and Tailscale.")
                }
                Stepper(
                    value: bind(\.stack.companionPort),
                    in: 1024...65535
                ) {
                    HStack {
                        Text("TLS Port")
                        Spacer()
                        Text("\(s.stack.companionPort)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!s.stack.companionEnabled)

                if needsStackRestart {
                    HStack {
                        Text("Restart the Vesper stack to apply Companion listener changes.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(restarting ? "Restarting…" : "Restart Stack") {
                            Task { await restartStack() }
                        }
                        .disabled(restarting)
                    }
                }
            }

            if let status {
                Section("Reachable Endpoints") {
                    LabeledContent("Listener") {
                        Text(status.enabled ? "Listening on TLS port \(status.port)" : "Off")
                            .foregroundStyle(status.enabled ? .green : .secondary)
                    }
                    if !status.lanAddresses.isEmpty {
                        LabeledContent("Local Wi-Fi") {
                            Text(status.lanAddresses.joined(separator: ", "))
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    if let dns = status.tailscaleDNS, !dns.isEmpty {
                        LabeledContent("Tailscale MagicDNS") {
                            Text(dns)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    if !status.tailscaleAddresses.isEmpty {
                        LabeledContent("Tailscale IP") {
                            Text(status.tailscaleAddresses.joined(separator: ", "))
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    if !status.certFingerprint.isEmpty {
                        LabeledContent("TLS Cert Pin (SHA-256)") {
                            Text(String(status.certFingerprint.prefix(24)) + "…")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .help(status.certFingerprint)
                                .textSelection(.enabled)
                        }
                    }
                }

                Section("Pair iPhone") {
                    if status.enabled {
                        HStack {
                            Button(generating ? "Generating…" : "Generate Pairing QR Code") {
                                Task { await generatePairingCode() }
                            }
                            .disabled(generating)

                            if let pairingCode {
                                Button(copiedURI ? "Copied URI" : "Copy Pairing URI") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(pairingCode.payloadURI, forType: .string)
                                    copiedURI = true
                                }
                            }
                        }

                        if let pairingCode, let qrImage = makeQRCode(from: pairingCode.payloadURI) {
                            VStack(alignment: .center, spacing: 10) {
                                Image(nsImage: qrImage)
                                    .interpolation(.none)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 200, height: 200)
                                    .padding(10)
                                    .background(Color.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                Text("Scan this QR code in the Vesper iPhone app. Expires in 5 minutes.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        }
                    } else {
                        Text("Enable Companion Access and restart the stack to generate a pairing QR code.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Paired Devices") {
                    if status.devices.isEmpty {
                        Text("No paired devices yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(status.devices) { device in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.name)
                                        .fontWeight(.medium)
                                    Text("\(device.platform.uppercased()) · Last active \(device.lastUsedAt)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Revoke", role: .destructive) {
                                    Task { await revokeDevice(id: device.id) }
                                }
                            }
                        }
                    }
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
        }
        .formStyle(.grouped)
        .task { await refresh() }
    }

    private var needsStackRestart: Bool {
        guard let status else { return false }
        if s.stack.companionEnabled != status.enabled { return true }
        if s.stack.companionEnabled && s.stack.companionPort != status.port { return true }
        return false
    }

    private func refresh() async {
        guard let client = aux.app?.stack?.makeAPIClient() else { return }
        loading = true
        defer { loading = false }
        do {
            status = try await client.get("/api/v1/companion/status", as: CompanionStatusResponse.self)
            errorMessage = nil
        } catch {
            errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    private func generatePairingCode() async {
        guard let client = aux.app?.stack?.makeAPIClient() else { return }
        generating = true
        copiedURI = false
        defer { generating = false }
        do {
            let data = try await client.request("POST", "/api/v1/companion/pairing-code")
            pairingCode = try JSONDecoder().decode(CompanionPairingCodeResponse.self, from: data)
            errorMessage = nil
        } catch {
            errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    private func revokeDevice(id: String) async {
        guard let client = aux.app?.stack?.makeAPIClient() else { return }
        do {
            _ = try await client.request("DELETE", "/api/v1/companion/devices/\(id)")
            await refresh()
        } catch {
            errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
    }

    private func restartStack() async {
        guard let stack = aux.app?.stack else { return }
        restarting = true
        defer { restarting = false }
        stack.apply(s.stack)
        await stack.restart()
        await refresh()
    }

    private func makeQRCode(from text: String) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}
