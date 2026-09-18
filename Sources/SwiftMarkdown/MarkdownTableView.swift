//
//  MarkdownTableView.swift
//  SwiftMarkdown
//
//  A table in its own horizontally scrolling view.
//
//  A tab-stop row is a single paragraph, so a table that does not fit cannot wrap
//  gracefully: the row breaks mid-way and the cells below the break have no stop
//  holding them in their column. Shrinking the type buys a little room and then runs
//  out — a thirteen-column table wants roughly a thousand points and a phone has
//  under four hundred. So the table leaves the shared text storage, is laid out at
//  the width it actually wants, and scrolls.
//
//  The cost, and it is the same one code blocks pay: a drag selection stops at the
//  table's edge rather than running through it.
//

import SwiftUI

public struct MarkdownTableView: View {

    public let table: MarkdownTable

    /// The document's style. Its `contentWidth` is deliberately ignored — the table
    /// is laid out unconstrained and the scroll view absorbs the overflow.
    public let style: MarkdownStyle

    /// Width the view is offered. A table narrower than this stretches to fill it, so
    /// a two-column table still looks like part of the document rather than a card
    /// floating in the left margin.
    @State private var availableWidth: CGFloat = 0
    @State private var rendered: Rendered?

    public init(table: MarkdownTable, style: MarkdownStyle) {
        self.table = table
        self.style = style
    }

    /// Built once per table and style rather than on every layout pass: measuring the
    /// columns renders every cell, which is the most expensive thing the builder does.
    private struct Rendered {
        let attributed: NSAttributedString
        let naturalWidth: CGFloat
    }

    private var unconstrainedStyle: MarkdownStyle {
        var style = self.style
        style.contentWidth = nil
        return style
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            if let rendered {
                MarkdownTextViewRepresentable(
                    attributed: rendered.attributed,
                    style: unconstrainedStyle,
                    // Enough for the border below the last row, plus the stroke itself.
                    verticalInset: MarkdownTableMetrics.verticalPadding
                        + MarkdownTableMetrics.borderWidth)
                    .frame(width: max(rendered.naturalWidth, availableWidth),
                           alignment: .topLeading)
            }
        }
        // Nothing to scroll when the table already fits, and a table that rubber-bands
        // for no reason reads as a bug.
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: MarkdownTableWidthKey.self,
                                       value: proxy.size.width.rounded())
            }
        )
        .onPreferenceChange(MarkdownTableWidthKey.self) { width in
            guard width > 0 else { return }
            availableWidth = width
        }
        .onAppear { render() }
        .onChange(of: table) { _, _ in render() }
        .onChange(of: MarkdownStyle.key(for: style)) { _, _ in render() }
    }

    private func render() {
        let style = unconstrainedStyle
        let attributed = MarkdownAttributedBuilder.table(table, style: style)
        let trimmed = NSMutableAttributedString(attributedString: attributed)
        // The row terminator on the last row would otherwise lay out an empty line
        // below the table's own border.
        if trimmed.string.hasSuffix("\n") {
            trimmed.deleteCharacters(in: NSRange(location: trimmed.length - 1, length: 1))
        }
        rendered = Rendered(attributed: trimmed,
                            naturalWidth: MarkdownAttributedBuilder.tableWidth(table, style: style))
    }
}

private struct MarkdownTableWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
