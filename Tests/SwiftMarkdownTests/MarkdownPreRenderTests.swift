//
//  MarkdownPreRenderTests.swift
//  SwiftMarkdownTests
//
//  The path a transcript takes: render a finished message once, off the main actor,
//  and hand the segments to a view that does no parsing of its own.
//

import Foundation
import Testing
@testable import SwiftMarkdown

@Suite("Pre-rendered segments")
struct MarkdownPreRenderTests {

    private static let message = """
    # A finished answer

    A paragraph with **bold**, `code` and a [link](https://example.com).

    ```swift
    let x = 1
    ```

    | Block | Reused |
    |:------|-------:|
    | Prose | yes |

    Closing prose.
    """

    private var style: MarkdownStyle { MarkdownStyle.standard(appearanceIsDark: false) }

    @Test("Rendering in one pass agrees with the streaming path")
    func matchesStreamingResult() {
        let oneShot = MarkdownSegment.render(Self.message, style: style)

        // What the coordinator would arrive at, delta by delta, for the same text.
        var document: MarkdownDocument?
        var set: MarkdownSegmentSet?
        var text = ""
        for line in Self.message.components(separatedBy: "\n") {
            text += text.isEmpty ? line : "\n" + line
            let parsed = MarkdownBlockParser.parse(text, reusing: document)
            set = MarkdownSegment.split(parsed, style: style, reusing: set)
            document = parsed
        }

        let streamed = set!.segments
        #expect(streamed.count == oneShot.count)
        for (a, b) in zip(streamed, oneShot) {
            switch (a, b) {
            case (.prose(let ia, let aa), .prose(let ib, let ab)):
                #expect(ia == ib)
                #expect(aa.string == ab.string)
            case (.code(let ia, _, let ca), .code(let ib, _, let cb)):
                #expect(ia == ib)
                #expect(ca == cb)
            case (.table(let ia, let ta), .table(let ib, let tb)):
                #expect(ia == ib)
                #expect(ta == tb)
            default:
                Issue.record("segment kinds diverged")
            }
        }
    }

    @Test("A message renders off the main actor and crosses back")
    func rendersOffTheMainActor() async {
        let style = self.style
        let segments = await Task.detached { MarkdownSegment.render(Self.message, style: style) }.value

        #expect(segments.contains { if case .code = $0 { return true } else { return false } })
        #expect(segments.contains { if case .table = $0 { return true } else { return false } })
    }

    @MainActor
    @Test("Heights are cached against the segment, not the view that measured it")
    func heightsSurviveTheirView() {
        guard case .prose(_, let attributed)? =
                MarkdownSegment.render(Self.message, style: style).first else {
            Issue.record("expected the message to open with prose")
            return
        }

        let first = MarkdownHeightCache.height(of: attributed, width: 320)
        let again = MarkdownHeightCache.height(of: attributed, width: 320)
        #expect(first > 0)
        #expect(first == again)

        // A different width is a different measurement, not a stale hit.
        #expect(MarkdownHeightCache.height(of: attributed, width: 200) != first)
    }
}
