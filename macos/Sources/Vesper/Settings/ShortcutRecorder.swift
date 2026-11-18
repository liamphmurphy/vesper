import AppKit
import SwiftUI
import VesperCore

/// A button that records a key combination: click, press the keys, done (Esc cancels). It reports
/// an accelerator such as "Alt+Shift+Space"; the caller validates it.
struct ShortcutRecorder: View {
    let accelerator: String
    let onRecord: (String) -> Void

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? "Type the shortcut…" : Capture.formatAccelerator(accelerator))
                .frame(minWidth: 140)
                .monospacedDigit()
        }
        .help("Click, then press the keys. Use ⌘, ⌥ or ⌃ (Shift alone isn't enough).")
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            // Swallow the key: it's being recorded, not typed.
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 53, flags.isEmpty {
                MainActor.assumeIsolated { stop() }
                return nil
            }
            guard let acc = GlobalShortcut.accelerator(
                keyCode: UInt32(event.keyCode), command: flags.contains(.command), shift: flags.contains(.shift),
                option: flags.contains(.option), control: flags.contains(.control)
            ) else { return nil }
            MainActor.assumeIsolated {
                stop()
                onRecord(acc)
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
