//
//  MarkdownPreviews.swift
//  SwiftMarkdown
//
//  Previews for the renderer. The streaming one is the point: the static preview
//  shows what the syntax turns into, but only a document that is still arriving
//  exercises the resume-and-reuse path this package exists for.
//
//  DEBUG-only, so none of this sample text ships in a host's release binary.
//

#if DEBUG
import SwiftUI

/// Every construct the parser handles, in one document — a change that breaks
/// one of them shows up here without hunting for a case that covers it.
enum MarkdownPreviewSample {

    static let kitchenSink = """
    # Streaming Markdown

    Text that is **still arriving**, rendered *without* re-reading itself on \
    every delta. Inline `code`, a [link](https://example.com), ~~a retraction~~, \
    ==a highlight==, H~2~O and e^iπ^.

    ## Lists

    - A bullet
    - Another, with nesting
      - One level down
    1. Ordered
    2. And the next

    - [x] A finished task
    - [ ] An unfinished one

    ## Code

    ```swift
    // Swift blocks get highlighted; other languages render flat.
    func render(_ text: String, reusing previous: MarkdownDocument?) -> MarkdownDocument {
        let parsed = MarkdownBlockParser.parse(text, reusing: previous)
        return parsed  // resumed near the tail, not re-read from the top
    }
    ```

    ```python
    # No highlighter for this one — flat, by design.
    def render(text): return parse(text)
    ```

    ## Tables

    | Layer | Resumes from | Reports | Rows | Hits | Misses | Depth | Peak | Idle | Frames | Bytes | Cost | Notes |
    |:------|:------------:|--------:|-----:|-----:|-------:|------:|-----:|-----:|-------:|------:|-----:|:------|
    | Parser | `retainedPrefix` | `reusedBlockCount` | 12 | 111 | 13 | 3 | 48 | 0 | 60 | 4096 | O(n) | tail |
    | Split | `MarkdownSegmentSet` | identity | 8 | 96 | 4 | 2 | 32 | 1 | 60 | 2048 | O(1) | reuse |
    | Coordinator | both | — | 20 | 207 | 17 | 1 | 80 | 60 | 60 | 8192 | O(1) | throttle |

    ## Quotes and math

    > A block quote, which the builder draws a bar beside.
    >> And one nested inside it.

    Inline math like $E = mc^2$ renders, while a price like $5 stays a price.

    $$
    \\sum_{i=1}^{n} \\frac{x_i}{n}
    $$

    ---

    Term
    : A definition list entry.

    A footnote reference[^1].

    [^1]: And the note it points at.
    """

    /// Shorter, so the streaming preview loops often enough to watch.
    static let streamed = """
    ## Rendering as it arrives

    Each delta re-parses only the tail. Settled blocks above keep their rendered \
    text, so this paragraph stops costing anything once the next block starts.

    ```swift
    let parsed = MarkdownBlockParser.parse(text, reusing: document)
    let split = MarkdownSegment.split(parsed, style: style, reusing: segmentSet)
    ```

    | Block | Reused |
    |:------|-------:|
    | Heading | yes |
    | Prose | yes |

    An unterminated fence still renders as the code block it is becoming:

    ```swift
    func thisFenceNeverCloses() {
    """
}

/// Drives `text` one chunk at a time, the way a model turn would.
private struct StreamingPreviewHarness: View {

    let source: String
    /// Characters per tick. Larger than one because a real delta is a token,
    /// and per-character appends make the throttle look busier than it is.
    var chunk = 3

    @State private var text = ""
    @State private var isRunning = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(isRunning ? "Pause" : "Resume") { isRunning.toggle() }
                Button("Restart") { text = ""; isRunning = true }
                Spacer()
                Text("\(text.count) / \(source.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(8)

            Divider()

            ScrollView {
                MarkdownView(text: text)
                    .padding()
            }
        }
        .task { await stream() }
    }

    private func stream() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(30))
            guard isRunning, text.count < source.count else { continue }
            let end = source.index(source.startIndex,
                                   offsetBy: min(text.count + chunk, source.count))
            text = String(source[source.startIndex..<end])
        }
    }
}

// MARK: - Previews

#Preview("Kitchen sink") {
    ScrollView {
        MarkdownView(text: MarkdownPreviewSample.kitchenSink)
            .padding()
    }
}

#Preview("Streaming") {
    StreamingPreviewHarness(source: MarkdownPreviewSample.streamed)
}

#Preview("Dark") {
    ScrollView {
        MarkdownView(text: MarkdownPreviewSample.kitchenSink)
            .padding()
    }
    .preferredColorScheme(.dark)
}

#Preview("Custom style") {
    ScrollView {
        MarkdownView(text: MarkdownPreviewSample.kitchenSink, style: {
            var style = MarkdownStyle.standard(appearanceIsDark: false)
            style.bodyFontSize = 17
            style.accentColor = .systemTeal
            style.headingScales = [2.0, 1.5, 1.25, 1.1, 1.0, 0.95]
            return style
        }())
        .padding()
    }
}
#endif
