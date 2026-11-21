import SwiftUI
import VesperCore

/// /native-debug/markdown, behind `NativeDebug`: one sample of every markdown feature through
/// `MarkdownView`, as a ticket description, a document and a chat reply, to click through the
/// renderer before the screens that use it move over. Not a product screen.
struct MarkdownDebugScreen: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    private static let modes: [(title: String, style: ThemeTokens.TextStyle, color: String, anchors: Bool, chat: Bool)] = [
        ("Ticket description (type-reading text-fg-2)", .reading, "text-2", false, false),
        ("Document (anchors)", .reading, "text-2", true, false),
        ("Chat reply (code blocks, ticket keys, citations [1] [2])", .chat, "text", false, true),
    ]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(Self.modes.indices, id: \.self) { i in
                        let mode = Self.modes[i]
                        VStack(alignment: .leading, spacing: 8) {
                            Text(mode.title).vesperText(.heading, theme)
                            MarkdownView(
                                markdown: Self.sample, textStyle: mode.style, textColor: mode.color, anchors: mode.anchors,
                                chat: mode.chat, citations: mode.chat ? [1, 2] : [], findRow: i,
                                onLink: { target in
                                    guard case .citation(let n) = target else { return false }
                                    context.showToast(ToastItemModel(id: "markdown-debug.cite", title: "Citation \(n)"))
                                    return true
                                }
                            )
                        }
                        .id(i)
                        .padding(16)
                        .background(theme.palette.surface, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(24)
                .frame(maxWidth: 760, alignment: .leading)
            }
            .onChange(of: context.find.current) { _, row in
                if let row { withAnimation { proxy.scrollTo(row, anchor: .top) } }
            }
        }
        .task {
            context.find.texts = Self.modes.map { _ in Self.sample }
            context.chrome = NativeChrome(title: "Markdown", subtitle: context.match.path)
        }
    }

    static let sample = """
    # Release plan

    A paragraph with **bold**, *italic*, ~~struck~~, `inline code`, a [web link](https://example.com), an \
    [in-app link](/inbox), a footnote[^1] and math $$e^{i\\pi} + 1 = 0$$. Soft
    break, and a hard\\
    break.

    ## Links

    Wiki links: [[Roadmap]], [[Design notes#Colors|the colours]], a ghost [[No such page yet]]. Ticket keys in \
    chat: PAY-214 and LAZYAGENTS-270. Citations in chat [1] and [2], not [3].

    ### Lists

    1. First
    2. Second
       - nested bullet
       - another
    3. Third

    - [x] done task
    - [ ] open task

    > A quote with a list:
    >
    > - one
    > - two
    >
    > > and a nested quote

    | Feature | Status | Count |
    | :--- | :---: | ---: |
    | Tables | **done** | 3 |
    | Alignment | centred | 12 |

    ---

    ```go
    package main

    import "fmt"

    // main prints a greeting.
    func main() {
    \tfmt.Println("hello")
    }
    ```

    ```ts
    export const total = (xs: number[]): number => xs.reduce((n, x) => n + x, 0);
    ```

    ```python
    def fib(n: int) -> int:
        return n if n < 2 else fib(n - 1) + fib(n - 2)
    ```

    ```
    \((1...24).map { "plain line \($0)" }.joined(separator: "\n"))
    ```

    $$
    \\int_0^1 x^2\\,dx = \\tfrac{1}{3}
    $$

    <span>Raw HTML shows as text.</span>

    [^1]: The footnote, with a [link](#links) back up.
    """
}
