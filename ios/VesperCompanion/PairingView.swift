@preconcurrency import AVFoundation
import SwiftUI
import UIKit
import VesperCore

struct PairingView: View {
    let connection: CompanionConnectionManager

    @State private var showScanner = false
    @State private var manualURI = ""
    @State private var pairing = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 10) {
                        Image(systemName: "iphone.and.arrow.forward.outward")
                            .font(.system(size: 52))
                            .foregroundStyle(.tint)
                        Text("Pair with Vesper on your Mac")
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)
                        Text("On your Mac, open Vesper → Settings → iPhone Companion, enable Companion Access, and generate a pairing QR code.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 24)

                    Button {
                        showScanner = true
                    } label: {
                        Label("Scan Pairing QR Code", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(pairing)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Or paste pairing URI")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField("vesper-pair://v1?data=…", text: $manualURI, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.caption, design: .monospaced))
                            .padding(10)
                            .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                        Button {
                            Task { await performPair(uri: manualURI) }
                        } label: {
                            if pairing {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                            } else {
                                Text("Connect")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(pairing || manualURI.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    if let errorMessage = errorMessage ?? connection.lastError {
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
                .padding()
            }
            .navigationTitle("Vesper")
            .sheet(isPresented: $showScanner) {
                QRScannerSheet { scanned in
                    showScanner = false
                    manualURI = scanned
                    Task { await performPair(uri: scanned) }
                }
            }
        }
    }

    private func performPair(uri: String) async {
        pairing = true
        errorMessage = nil
        defer { pairing = false }
        let deviceName = UIDevice.current.name
        do {
            try await connection.pair(uri: uri, deviceName: deviceName)
        } catch let err as CompanionPairingError {
            errorMessage = err.userMessage
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct QRScannerSheet: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                QRScannerRepresentable(onCode: onCode)
                    .ignoresSafeArea()
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(.white.opacity(0.85), lineWidth: 3)
                    .frame(width: 240, height: 240)
            }
            .navigationTitle("Scan Pairing QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

private struct QRScannerRepresentable: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let vc = QRScannerViewController()
        vc.onCode = onCode
        return vc
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}
}

private final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didEmit = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else {
            showUnavailableLabel()
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            showUnavailableLabel()
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.layer.bounds
        view.layer.addSublayer(preview)
        self.previewLayer = preview

        let captureSession = session
        DispatchQueue.global(qos: .userInitiated).async {
            captureSession.startRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.layer.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let captureSession = session
        DispatchQueue.global(qos: .userInitiated).async {
            if captureSession.isRunning { captureSession.stopRunning() }
        }
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = obj.stringValue,
              value.lowercased().hasPrefix("vesper-pair://")
        else { return }
        Task { @MainActor [weak self] in
            guard let self, !self.didEmit else { return }
            self.didEmit = true
            self.session.stopRunning()
            self.onCode?(value)
        }
    }

    private func showUnavailableLabel() {
        let label = UILabel()
        label.text = "Camera unavailable.\nPaste the pairing URI manually instead."
        label.textColor = .white
        label.numberOfLines = 0
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])
    }
}
