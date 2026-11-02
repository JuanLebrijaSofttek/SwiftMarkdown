//
//  MarkdownTableView.swift
//  SwiftMarkdown
//
//  A table in its own horizontally scrolling view.
//
//  Long cells wrap onto extra lines within their row, and columns are sized to the
//  width the view is offered, so most tables fit without scrolling. Some still do not:
//  a thirteen-column table of unbreakable values wants far more room than a phone has.
//  So the table leaves the shared text storage, and whatever cannot wrap scrolls.
//
//  The cost, and it is the same one code blocks pay: a drag selection stops at the
//  table's edge rather than running through it.
//

import SwiftUI

public struct MarkdownTableView: View {

    public let table: MarkdownTable

    /// The document's style. Its `contentWidth` is replaced by the width this view is
    /// actually offered, which long columns wrap to; the scroll view only absorbs what
    /// still overflows once they have.
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

    private var fittedStyle: MarkdownStyle {
        var style = self.style
        style.contentWidth = availableWidth > 0 ? availableWidth : nil
        return style
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            if let rendered {
                MarkdownTextViewRepresentable(
                    attributed: rendered.attributed,
                    style: fittedStyle,
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
        .onChange(of: availableWidth) { _, _ in render() }
        .onChange(of: MarkdownStyle.key(for: style)) { _, _ in render() }
    }

    private func render() {
        let style = fittedStyle
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
