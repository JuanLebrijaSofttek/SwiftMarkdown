# SwiftMarkdown

A Markdown renderer for SwiftUI built for text that is still arriving. Appending
a token re-parses the tail, not the whole document, and re-renders only the
blocks that actually changed — so a long answer streams at 60fps instead of
re-reading itself on every delta.

Standalone: one target, no dependencies beyond Foundation and SwiftUI.

```swift
.package(url: "…/SwiftMarkdown", from: "1.0.0")
```

## Rendering

```swift
import SwiftMarkdown

struct AnswerView: View {
    @State private var text = ""

    var body: some View {
        ScrollView {
            MarkdownView(text: text)
        }
    }
}
```

Assign to `text` as often as you like — deltas are coalesced to one render per
frame, and the view stops its timer after ~1s of quiet.

### Transcripts

`MarkdownView(text:)` parses in `onAppear`. That's right for a message that is
still arriving and wrong for fifty that aren't: in a `LazyVStack` every row pays
it on the way in, and pays it again each time a row that scrolled away is
rebuilt. Render finished messages once, where they're owned:

```swift
// Off the main actor if you like — segments and styles both cross.
let segments = await Task.detached { MarkdownSegment.render(text, style: style) }.value

MarkdownView(segments: segments, style: style)
```

The view then does no parsing at all, and measured heights are cached against the
segments rather than against the view that measured them, so they survive a row
being discarded. Measured, one row appearing (8K characters, macOS):

| | first appearance | every appearance after |
|---|---|---|
| `MarkdownView(text:)` | 15.8ms | 15.8ms |
| `MarkdownView(segments:)` | 4.4ms | 0.02ms |

Pass the same style you rendered with — segments carry their own fonts and
colors, so a mismatch lays the text out in one style and decorates it in
another.

## How the incremental path works

Three layers, each able to resume from its own previous result:

**`MarkdownBlockParser.parse(_:reusing:)`** returns a `MarkdownDocument` that
remembers where each block started, a verbatim prefix of the text it parsed, and
the line a later parse may resume from. Handed that document back, the next parse
confirms the new text really is an append (not an edit) by matching the retained
prefix, then re-reads only from the last stable block onward. `stableBlockCount`
is its promise about the next parse; `reusedBlockCount` reports what this parse
actually carried over — trust the latter when deciding what to keep.

**`MarkdownSegment.split(_:style:reusing:)`** groups blocks into the pieces that
get their own view, coalescing consecutive prose so one text storage covers
headings, prose, lists and quotes — selection drags continuously across all of
them. Code blocks and tables split out because they scroll horizontally, which a
shared text container can't express. Settled prose segments are handed back as
the same object, not an equal one, so SwiftUI skips them.

`MarkdownSegment.render(_:style:)` is the whole of this skipped: one parse, one
split, no reuse machinery, for text that will never change again.

**`MarkdownRenderCoordinator`** owns the frame throttle and holds the previous
document and segment set, feeding each back in. A style change bypasses the
queue and renders immediately — a queued render would leave the document in
stale colors for a frame.

The parser is deliberately tolerant of half-finished input: an unterminated fence
or a table mid-row parses as the block it is on its way to becoming, rather than
flickering between interpretations as the text lands.

## Supported syntax

Headings, paragraphs, bullet/ordered/task lists, tables with alignment, fenced
code, block quotes, thematic breaks, definition lists, footnotes. (Fenced code
only — four-space indented blocks are read as prose, since model output uses
fences and indentation there is usually a list continuation.)
Inline: bold, italic, strikethrough, `==highlight==`, sub/superscript, code
spans, links, images, backslash escapes. Swift code blocks get syntax
highlighting; other languages render flat.

`$...$` and `$$...$$` math goes through `MarkdownMath`, a LaTeX-lite renderer
covering fractions, roots and scripts, falling back to the source text for
anything it doesn't know. A `$5` in prose stays a price — see
`MarkdownMath.looksLikeMath`.

## Styling

`MarkdownView` follows the system appearance with no configuration: `.primary`
and `.secondary` for text, the platform accent for links, neutral greys for code
chrome (`MarkdownColors`). To override:

```swift
var style = MarkdownStyle.standard(appearanceIsDark: true)
style.bodyFontSize = 15
style.accentColor = .systemTeal

MarkdownView(text: text, style: style)
```

### Tables

Both platforms lay tables out with tab stops, and both draw the same frame: a
rounded border, a filled header, and a rule between rows — no column dividers,
since columns are sized to their content and ruling uneven gaps draws the eye to
the gaps. AppKit's `NSTextTable` was dropped for this: it stretches columns to
fill the width and rules them vertically, so the same table looked materially
different on each platform. The trade is that `NSTextTable` can wrap a cell onto
a second line and a tab-stop row — being one paragraph — cannot.

Which is why columns are measured rather than fixed, and why a table that doesn't
fit scrolls instead of wrapping. Columns are measured from the *rendered* cells (a
mono code span counts for what it draws, not for what the body font would have),
the table is laid out at the width those columns add up to, and
`MarkdownTableView` puts that inside a horizontal `ScrollView` — a thirteen-column
table wants around a thousand points, and no amount of shrinking fits that on a
phone. A table narrower than the document stretches to fill it, so it reads as
part of the text rather than a card in the left margin.

That's the same trade code blocks make: a table in its own view has its own
selection scope, so a drag stops at its edge.

`MarkdownStyle.contentWidth` is the other half of this, for callers building
attributed strings themselves: set it and the builder tightens the gutters and
scales the type down — to 0.8× at the most — to fit that width instead. Left
`nil`, which is what `MarkdownView` does, columns take their natural widths.

The text view takes a matching `verticalInset` so the border below the last row
has somewhere to land; sized exactly to its glyphs, the view would clip it.

`MarkdownTableMetrics` holds the padding and radius the builder reserves and the
text view paints into. They have to agree, and a constant in only one of them is
how they stop agreeing.

`MarkdownStyle` holds `PlatformColor`/`PlatformFont` rather than SwiftUI types
because the attributed-string builder runs below SwiftUI and can't resolve a
`Color` itself. That's also why `standard(appearanceIsDark:)` takes the
appearance instead of reading it — pass `colorScheme == .dark`.

Mutating a style by hand clears its recorded identity, so an adjusted style is
never mistaken for the one it came from by the render cache.

## Parsing without the UI

The parser half is Foundation-only and has no SwiftUI entanglement:

```swift
let blocks = MarkdownBlockParser.parse("# Title\n\nSome **prose**.")
let inline = MarkdownInlineParser.parse("a `code` span")
```

`MarkdownBlock` and `MarkdownInline` are plain `Sendable` enums — nothing in them
knows about a platform, font or color.

## Requirements

macOS 14+, iOS 17+, Swift 6.
