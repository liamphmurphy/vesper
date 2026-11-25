# Vesper iPhone Companion

Native SwiftUI companion app for Vesper on macOS, sharing `VesperCore` directly from `../macos`.

## What it does
- **QR Pairing + Pinned TLS:** Scans the QR code generated in Vesper on Mac (**Settings → iPhone Companion**), exchanges the one-time code for a revocable bearer token stored in the iOS Keychain, and pins the Mac's self-signed TLS certificate (SHA-256).
- **Automatic Local Wi-Fi ↔ Tailscale Failover:** Discovers the Mac via Bonjour (`_vesper._tcp`) / saved LAN IPs on home Wi-Fi and falls back automatically to Tailscale MagicDNS / Tailscale IP when away.
- **Companion Tabs:**
  - **Chat:** Live SSE updates, full desktop chat visualizations (charts, stats, diffs, comparisons, timelines, trees, graphs, math plots, data tables, code groups, JSON/HTTP inspectors, callouts, interactive checklists, choices, Mermaid/SVG/interactive HTML apps), live Persona working & step cards, code change diffs, inline Push Request & Tool Approval cards, plus Camera and Photo Library photo attachments.
  - **Spaces:** Browse Spaces, their persona chats, context repositories/links, and start new chats in a Space.
  - **Inbox:** Pending approvals and items waiting on you.
  - **Capture:** Quick notes to your Knowledge Inbox, plus Camera / Photo Library photo capture directly to your Vesper Library.
  - **Mac:** Connection status, active LAN/Tailscale route, and pairing management.

## Building & running on your iPhone
1. Open `ios/VesperCompanion.xcodeproj` in Xcode on your Mac.
2. Select the **VesperCompanion** target → **Signing & Capabilities** → choose your Apple Development Team and a unique Bundle Identifier if needed.
3. Connect your iPhone (or select an iOS Simulator) and press **Run** (`⌘R`).
4. On your Mac, open **Vesper → Settings → iPhone Companion**, turn on **Allow iPhone Companion access**, restart the stack, and click **Generate Pairing QR Code**.
5. Scan the QR code (or paste the `vesper-pair://` URI) in the iPhone app.
