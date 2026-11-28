import AppKit
import SwiftUI
import Testing
@testable import Vesper

@MainActor
@Suite("ChatLiveStageSplitLayout")
struct ChatLiveActivityLayoutTests {
    private struct SlotFramesKey: PreferenceKey {
        nonisolated(unsafe) static var defaultValue: [String: CGRect] = [:]
        static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
            value.merge(nextValue(), uniquingKeysWith: { _, new in new })
        }
    }

    private struct LayoutProbeHost: View {
        let width: CGFloat
        let longOpeningLine: String
        let onFrames: ([String: CGRect]) -> Void

        var body: some View {
            ChatLiveStageSplitLayout {
                Color.blue
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .background(frameReporter("stage"))
                Rectangle()
                    .fill(Color.gray)
                    .background(frameReporter("divider"))
                VStack(alignment: .leading, spacing: 6) {
                    Text("Delegating to a helper…")
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text(longOpeningLine)
                        .font(.system(size: 12))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(frameReporter("telemetry"))
            }
            .coordinateSpace(name: "card")
            .frame(width: width)
            .onPreferenceChange(SlotFramesKey.self, perform: onFrames)
        }

        private func frameReporter(_ id: String) -> some View {
            GeometryReader { geo in
                Color.clear.preference(
                    key: SlotFramesKey.self,
                    value: [id: geo.frame(in: .named("card"))]
                )
            }
        }
    }

    private func measureSlots(width: CGFloat, longOpeningLine: String) -> [String: CGRect] {
        var captured: [String: CGRect] = [:]
        let view = LayoutProbeHost(width: width, longOpeningLine: longOpeningLine) { frames in
            captured = frames
        }
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: width, height: 300)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        return captured
    }

    @Test("keeps diorama stage side-by-side at normal chat widths even with a very long opening line")
    func sideBySideWithLongWrappingText() {
        let longLine = "Showtime—let me run a quick live audit of the new card pipeline so you can watch the diorama stage, target ticker, plan checklist, narration callouts, and parallel subagent lanes fire in real time."
        let frames = measureSlots(width: 760, longOpeningLine: longLine)

        let stage = try! #require(frames["stage"])
        let divider = try! #require(frames["divider"])
        let telemetry = try! #require(frames["telemetry"])

        #expect(stage.minX == 0)
        #expect(stage.width == 136)
        #expect(stage.height >= 76)

        #expect(divider.minX == 136)
        #expect(divider.width == 1)
        #expect(abs(divider.height - stage.height) < 0.5)

        #expect(telemetry.minX == 137)
        #expect(abs(telemetry.width - (760 - 137)) < 0.5)
        #expect(telemetry.minY >= 0)
        #expect(telemetry.maxY <= stage.maxY + 0.5)
    }

    @Test("stacks flush edge-to-edge on narrow Docked Chat widths below breakpoint")
    func stackedEdgeToEdgeWhenNarrow() {
        let frames = measureSlots(
            width: 320,
            longOpeningLine: "Inspecting the live card layout in narrow Docked Chat."
        )

        let stage = try! #require(frames["stage"])
        let divider = try! #require(frames["divider"])
        let telemetry = try! #require(frames["telemetry"])

        #expect(stage.minX == 0)
        #expect(stage.minY == 0)
        #expect(stage.width == 320)
        #expect(stage.height == 64)

        #expect(divider.minX == 0)
        #expect(divider.minY == 64)
        #expect(divider.width == 320)
        #expect(divider.height == 1)

        #expect(telemetry.minX == 0)
        #expect(telemetry.minY == 65)
        #expect(telemetry.width == 320)
    }
}
