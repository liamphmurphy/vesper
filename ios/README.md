# Vesper iPhone Companion

Native SwiftUI companion app for Vesper on macOS, sharing `VesperCore` directly from `../macos`.

## What it does
- **QR Pairing + Pinned TLS:** Scans the QR code generated in Vesper on Mac (**Settings → iPhone Companion**), exchanges the one-time code for a revocable bearer token stored in the iOS Keychain, and pins the Mac's self-signed TLS certificate (SHA-256).
- **Automatic Local Wi-Fi ↔ Tailscale Failover:** Discovers the Mac via Bonjour (`_vesper._tcp`) / saved LAN IPs on home Wi-Fi and falls back automatically to Tailscale MagicDNS / Tailscale IP when away.
- **Companion MVP Tabs:** Chat (live SSE updates, markdown, new chat with persona picker), Inbox (approvals & replies), Live/Recent Runs, Quick Capture to Knowledge Inbox, and Mac Connection status.

## Building & running on your iPhone
1. Open `ios/VesperCompanion.xcodeproj` in Xcode on your Mac.
2. Select the **VesperCompanion** target → **Signing & Capabilities** → choose your Apple Development Team and a unique Bundle Identifier if needed.
3. Connect your iPhone (or select an iOS Simulator) and press **Run** (`⌘R`).
4. On your Mac, open **Vesper → Settings → iPhone Companion**, turn on **Allow iPhone Companion access**, restart the stack, and click **Generate Pairing QR Code**.
5. Scan the QR code (or paste the `vesper-pair://` URI) in the iPhone app.
