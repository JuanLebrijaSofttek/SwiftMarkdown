//
//  MarkdownAttributedBuilder.swift
//  SwiftMarkdown
//
//  Turns parsed blocks into one NSAttributedString. Everything a message contains
//  ends up in a single text storage, which is what lets a drag select across
//  headings, prose, lists, tables and code in one gesture.
//

import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Where a fenced code block landed in the built string, so the view can draw its
/// backing panel and float a Copy button over it.
public struct MarkdownCodeRegion: Equatable, Identifiable {
    public let id: Int
    public let range: NSRange
    public let language: String?
    public let code: String

    public init(id: Int, range: NSRange, language: String?, code: String) {
        self.id = id
        self.range = range
        self.language = language
        self.code = code
    }
}

public struct MarkdownRenderResult {
    public let attributed: NSAttributedString
    public let codeRegions: [MarkdownCodeRegion]
}

public enum MarkdownAttributedBuilder {

    /// Attribute key marking a run as belonging to a fenced code block. The text view
    /// reads it back to lay out backgrounds without re-deriving ranges.
    public static let codeBlockAttribute = NSAttributedString.Key("SwiftMarkdownCodeBlock")

    /// Marks a table's whole range so the text view can draw its frame: a rounded
    /// outer border, the header fill, and the rules between rows. The tab-stop
    /// layout reserves the space for all of it but paints none of it.
    public static let tableAttribute = NSAttributedString.Key("SwiftMarkdownTable")

    /// Marks a table's header row so the text view can fill it with a shape that
    /// respects the outer border's corner radius at the top.
    public static let tableHeaderAttribute = NSAttributedString.Key("SwiftMarkdownTableHeader")

    /// Marks each table row with its index, so the text view can find the boundary
    /// between one row and the next and rule a line there.
    public static let tableRowAttribute = NSAttributedString.Key("SwiftMarkdownTableRow")

    /// Draws a blue box around every block the builder emits — one per heading,
    /// paragraph, list, quote, table, rule and code block — so the gaps between them
    /// can be seen rather than inferred. Debugging aid, off by default; the ranges are
    /// only recorded while it is on, so leaving it off costs nothing.
    nonisolated(unsafe) public static var debugBlockBorders = false

    /// Marks one block's range for ``debugBlockBorders``. The value is the block's start
    /// offset, which makes it unique per block.
    public static let blockBoundaryAttribute = NSAttributedString.Key("SwiftMarkdownBlockBoundary")

    /// The gap between any two blocks — headings, prose, lists, quotes, rules, code.
    /// One number on purpose: individual blocks no longer choose their own spacing,
    /// so widening one is a deliberate exception rather than the default.
    public static let blockSpacing: CGFloat = 2

    public static func build(_ blocks: [MarkdownBlock], style: MarkdownStyle) -> MarkdownRenderResult {
        let result = NSMutableAttributedString()
        let regions = append(blocks, to: result, style: style)
        return MarkdownRenderResult(attributed: result, codeRegions: regions)
    }

    /// Renders `blocks` onto the end of `target`, returning any code regions found.
    ///
    /// Separate from ``build(_:style:)`` so a streaming message can extend text it has
    /// already rendered instead of rebuilding it. Blocks carry no state across each
    /// other — only the separator between them — so appending a suffix produces exactly
    /// what building the whole sequence at once would have.
    @discardableResult
    public static func append(_ blocks: [MarkdownBlock],
                              to result: NSMutableAttributedString,
                              style: MarkdownStyle) -> [MarkdownCodeRegion] {
        var regions: [MarkdownCodeRegion] = []

        for block in blocks {
            // No separator between blocks: each one is already terminated by the newline
            // `append(_:to:)` adds, which is all a paragraph break needs. A second
            // newline here made an empty paragraph between every pair of blocks, laid
            // out as a full blank line — the large gaps under headings and rules.
            let blockStart = result.length
            switch block {
            case .heading(let level, let content, _):
                append(heading(level: level, content: content, style: style), to: result)

            case .paragraph(let content):
                append(paragraph(content, style: style), to: result)

            case .blockQuote(let depth, let content):
                append(blockQuote(depth: depth, content: content, style: style), to: result)

            case .codeBlock(let language, let code):
                // Reached only if a code block is fed to the builder directly; the chat
                // renderer splits them out into MarkdownCodeBlockView so they can scroll.
                let start = result.length
                append(codeBlock(code, style: style), to: result)
                let range = NSRange(location: start, length: result.length - start)
                result.addAttribute(codeBlockAttribute, value: regions.count, range: range)
                regions.append(MarkdownCodeRegion(id: regions.count, range: range,
                                                  language: language, code: code))

            case .list(let items):
                append(list(items, style: style), to: result)

            case .table(let table):
                append(self.table(table, style: style), to: result)

            case .mathBlock(let content):
                append(mathBlock(content, style: style), to: result)

            case .thematicBreak:
                append(thematicBreak(style: style), to: result)

            case .definitionList(let definitions):
                append(definitionList(definitions, style: style), to: result)

            case .footnoteDefinition(let label, let content):
                append(footnote(label: label, content: content, style: style), to: result)
            }

            if debugBlockBorders, result.length > blockStart {
                // The start offset doubles as the value: `enumerateAttribute` coalesces
                // adjacent equal values, and two blocks sharing one box would defeat the
                // point of drawing them.
                result.addAttribute(blockBoundaryAttribute, value: blockStart,
                                    range: NSRange(location: blockStart,
                                                   length: result.length - blockStart))
            }
        }

        return regions
    }

    /// Closes the blank strip a finished run reserves below its last line, which reads
    /// as a gap between messages rather than as part of the text. Two separate causes:
    ///
    /// - Every block is terminated with a newline so the next one starts its own
    ///   paragraph, and TextKit lays out an empty final line fragment for a trailing
    ///   newline. `usedRect` counts that fragment, so the last block of a run costs a
    ///   full extra line of height — by far the larger of the two.
    /// - `paragraphSpacing` on the last paragraph, which `usedRect` also counts.
    ///
    /// Applied to a finished segment rather than inside ``append(_:to:style:)``, so a
    /// streaming message can still extend text it has already rendered: both the
    /// newline and the gap after a block are only wrong while that block is the last one.
    public static func trimTrailingGap(in text: NSMutableAttributedString) {
        guard text.length > 0 else { return }

        // One newline only — the terminator `append(_:to:)` adds. Anything beyond it is
        // blank space the message itself asked for.
        if (text.string as NSString).character(at: text.length - 1) == 0x0A {
            text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1))
        }
        guard text.length > 0 else { return }

        let lastRange = (text.string as NSString).lineRange(for: NSRange(location: text.length - 1, length: 0))
        var effective = NSRange()
        guard let current = text.attribute(.paragraphStyle, at: lastRange.location,
                                           effectiveRange: &effective) as? NSParagraphStyle,
              let trimmed = current.mutableCopy() as? NSMutableParagraphStyle
        else { return }
        trimmed.paragraphSpacing = 0
        text.addAttribute(.paragraphStyle, value: trimmed, range: lastRange)
    }

    /// Appends a block and the newline that ends its last paragraph, so the next block
    /// starts its own. That newline is the *only* character between two blocks: an extra
    /// separator on top of it would be an empty paragraph, laid out as a full blank line.
    private static func append(_ piece: NSAttributedString, to target: NSMutableAttributedString) {
        target.append(piece)
        guard !piece.string.hasSuffix("\n"), piece.length > 0 else { return }
        // The terminator belongs to the paragraph it closes, so it carries that
        // paragraph's attributes; left plain it would be laid out at the default 12pt.
        var attributes = piece.attributes(at: piece.length - 1, effectiveRange: nil)
        // The decorations are drawn from their attribute's range; carrying them onto the
        // terminator would grow the panel, quote bar or rule by an empty trailing line.
        attributes[codeBlockAttribute] = nil
        attributes[quoteDepthAttribute] = nil
        attributes[thematicBreakAttribute] = nil
        attributes[tableAttribute] = nil
        attributes[tableHeaderAttribute] = nil
        attributes[tableRowAttribute] = nil
        target.append(NSAttributedString(string: "\n", attributes: attributes))
    }

    // MARK: - Blocks

    private static func heading(level: Int, content: [MarkdownInline], style: MarkdownStyle) -> NSAttributedString {
        let scale = style.headingScales[min(max(level, 1), 6) - 1]
        let size = style.bodyFontSize * scale
        let base = PlatformFont.markdownSystem(size: size, weight: .bold)

        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacingBefore = blockSpacing
        paragraph.paragraphSpacing = blockSpacing
        paragraph.lineHeightMultiple = 1.05

        let out = inlines(content, style: style, font: base, color: style.textColor)
        out.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: out.length))
        return out
    }

    private static func paragraph(_ content: [MarkdownInline], style: MarkdownStyle) -> NSAttributedString {
        let font = PlatformFont.markdownSystem(size: style.bodyFontSize)
        let out = inlines(content, style: style, font: font, color: style.textColor)
        out.addAttribute(.paragraphStyle, value: bodyParagraphStyle(style),
                         range: NSRange(location: 0, length: out.length))
        return out
    }

    private static func bodyParagraphStyle(_ style: MarkdownStyle) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = blockSpacing
        return paragraph
    }

    private static func blockQuote(depth: Int, content: [MarkdownInline], style: MarkdownStyle) -> NSAttributedString {
        let font = PlatformFont.markdownSystem(size: style.bodyFontSize)
        let out = inlines(content, style: style, font: font, color: style.secondaryColor)

        let indent = CGFloat(depth) * 18
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = blockSpacing
        paragraph.firstLineHeadIndent = indent
        paragraph.headIndent = indent
        // The bar itself is drawn by the text view; the indent reserves room for it.
        out.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: out.length))
        out.addAttribute(quoteDepthAttribute, value: depth, range: NSRange(location: 0, length: out.length))
        return out
    }

    /// Marks quoted runs so the text view can stroke the vertical bar beside them.
    public static let quoteDepthAttribute = NSAttributedString.Key("SwiftMarkdownQuoteDepth")

    /// A code block taller than this collapses to a preview until expanded.
    public static let collapsedCodeLines = 6

    private static func codeBlock(_ code: String, style: MarkdownStyle) -> NSAttributedString {
        let font = PlatformFont.markdownMono(size: style.bodyFontSize * 0.95)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.firstLineHeadIndent = 12
        paragraph.headIndent = 12
        paragraph.tailIndent = -12
        // Long lines wrap rather than scroll: a nested scroll view would break the
        // single selection scope this whole renderer exists to provide.
        paragraph.lineBreakMode = .byWordWrapping

        let out = NSMutableAttributedString(string: code, attributes: [
            .font: font,
            .foregroundColor: style.textColor,
            .paragraphStyle: paragraph,
        ])

        // Every newline inside the code is a paragraph break, so block spacing has to be
        // applied to the first and last lines only — putting it on `paragraph` would
        // insert the gap between every single line of code.
        applyOuterSpacing(before: blockSpacing, after: blockSpacing, to: out, base: paragraph)
        return out
    }

    /// Adds leading/trailing block spacing to a multi-paragraph run without spacing out
    /// its interior lines.
    private static func applyOuterSpacing(before: CGFloat, after: CGFloat,
                                          to text: NSMutableAttributedString,
                                          base: NSParagraphStyle) {
        guard text.length > 0 else { return }
        let ns = text.string as NSString

        let first = base.mutableCopy() as! NSMutableParagraphStyle
        first.paragraphSpacingBefore = before
        text.addAttribute(.paragraphStyle, value: first, range: ns.lineRange(for: NSRange(location: 0, length: 0)))

        let last = base.mutableCopy() as! NSMutableParagraphStyle
        last.paragraphSpacing = after
        let lastRange = ns.lineRange(for: NSRange(location: text.length - 1, length: 0))
        // A single-line block needs both, so merge rather than overwrite.
        if lastRange.location == 0 { last.paragraphSpacingBefore = before }
        text.addAttribute(.paragraphStyle, value: last, range: lastRange)
    }

    private static func list(_ items: [MarkdownListItem], style: MarkdownStyle) -> NSAttributedString {
        let font = PlatformFont.markdownSystem(size: style.bodyFontSize)
        let out = NSMutableAttributedString()

        for (index, item) in items.enumerated() {
            if index > 0 { out.append(NSAttributedString(string: "\n")) }

            let indent = CGFloat(item.depth) * 18
            let markerText: String
            var markerColor = style.secondaryColor
            switch item.marker {
            case .bullet:
                markerText = item.depth % 2 == 0 ? "•\t" : "◦\t"
            case .ordered(let number):
                markerText = "\(number).\t"
            case .task(let checked):
                markerText = checked ? "☑\t" : "☐\t"
                if checked { markerColor = style.accentColor }
            }

            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3
            paragraph.paragraphSpacing = blockSpacing
            paragraph.firstLineHeadIndent = indent
            // Wrapped lines align with the text, not the marker.
            paragraph.headIndent = indent + 20
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indent + 20)]

            out.append(NSAttributedString(string: markerText, attributes: [
                .font: font,
                .foregroundColor: markerColor,
            ]))

            let body = inlines(item.content, style: style, font: font, color: style.textColor)
            if case .task(let checked) = item.marker, checked {
                body.addAttribute(.foregroundColor, value: style.secondaryColor,
                                  range: NSRange(location: 0, length: body.length))
            }
            out.append(body)

            out.addAttribute(.paragraphStyle, value: paragraph,
                             range: NSRange(location: out.length - markerText.count - body.length,
                                            length: markerText.count + body.length))
        }
        return out
    }

    /// A display equation: centred, on its own line, in the serif-ish italic that
    /// reads as mathematics without pulling in a TeX renderer.
    private static func mathBlock(_ content: [MarkdownInline], style: MarkdownStyle) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacingBefore = blockSpacing
        paragraph.paragraphSpacing = blockSpacing
        paragraph.lineSpacing = 3

        let out = inlines(content, style: style,
                          font: mathFont(size: style.bodyFontSize * 1.05),
                          color: style.textColor)
        out.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: out.length))
        return out
    }

    /// Italic system font stands in for a math face; it distinguishes variables from
    /// prose without shipping a font.
    public static func mathFont(size: CGFloat) -> PlatformFont {
        PlatformFont.markdownSystem(size: size).addingMarkdownTrait(.italic)
    }

    private static func thematicBreak(style: MarkdownStyle) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacingBefore = blockSpacing + 1
        paragraph.paragraphSpacing = blockSpacing + 1
        // The carrier line is collapsed to a hairline; without a line-height clamp it
        // reserves a full line box and the rule floats in a band of empty space.
        paragraph.minimumLineHeight = 7
        paragraph.maximumLineHeight = 7
        // A styled empty line; the rule is stroked by the text view.
        let out = NSMutableAttributedString(string: " ", attributes: [
            .font: PlatformFont.markdownSystem(size: style.bodyFontSize * 0.4),
            .paragraphStyle: paragraph,
            thematicBreakAttribute: true,
        ])
        return out
    }

    public static let thematicBreakAttribute = NSAttributedString.Key("SwiftMarkdownRule")

    private static func definitionList(_ definitions: [MarkdownDefinition], style: MarkdownStyle) -> NSAttributedString {
        let font = PlatformFont.markdownSystem(size: style.bodyFontSize)
        let termFont = PlatformFont.markdownSystem(size: style.bodyFontSize, weight: .semibold)
        let out = NSMutableAttributedString()

        for (index, definition) in definitions.enumerated() {
            if index > 0 { out.append(NSAttributedString(string: "\n")) }
            let term = inlines(definition.term, style: style, font: termFont, color: style.textColor)
            term.addAttribute(.paragraphStyle, value: bodyParagraphStyle(style),
                              range: NSRange(location: 0, length: term.length))
            out.append(term)

            for detail in definition.details {
                out.append(NSAttributedString(string: "\n"))
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = 3
                paragraph.firstLineHeadIndent = 18
                paragraph.headIndent = 18
                paragraph.paragraphSpacing = blockSpacing
                let body = inlines(detail, style: style, font: font, color: style.secondaryColor)
                body.addAttribute(.paragraphStyle, value: paragraph,
                                  range: NSRange(location: 0, length: body.length))
                out.append(body)
            }
        }
        return out
    }

    private static func footnote(label: String, content: [MarkdownInline], style: MarkdownStyle) -> NSAttributedString {
        let font = PlatformFont.markdownSystem(size: style.bodyFontSize * 0.9)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.firstLineHeadIndent = 0
        paragraph.headIndent = 18
        paragraph.paragraphSpacing = blockSpacing

        let out = NSMutableAttributedString(string: "\(label). ", attributes: [
            .font: PlatformFont.markdownSystem(size: style.bodyFontSize * 0.9, weight: .semibold),
            .foregroundColor: style.secondaryColor,
        ])
        out.append(inlines(content, style: style, font: font, color: style.secondaryColor))
        out.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: out.length))
        return out
    }

    // MARK: - Tables

    /// Column geometry for a table: how wide each column has to be, where each one
    /// starts, and how far the type had to shrink to get there. Split out from the
    /// builder so a view can ask what a table *wants* to be — its natural width —
    /// without building the string twice.
    struct TableMetrics {
        let widths: [CGFloat]
        let starts: [CGFloat]
        let gutter: CGFloat
        let scale: CGFloat

        /// The width the table draws into, border to border.
        var totalWidth: CGFloat {
            ((starts.last ?? 0) + (widths.last ?? 0) + MarkdownTableMetrics.horizontalPadding).rounded(.up)
        }
    }

    /// The width this table needs to keep every row on one line, ignoring
    /// `style.contentWidth` — the scrolling table view sizes itself from this.
    static func tableWidth(_ table: MarkdownTable, style: MarkdownStyle) -> CGFloat {
        let columnCount = max(table.headers.count, table.rows.map(\.count).max() ?? 0)
        guard columnCount > 0 else { return 0 }
        var unconstrained = style
        unconstrained.contentWidth = nil
        return tableMetrics(table, style: unconstrained, columnCount: columnCount).totalWidth
    }

    private static func tableMetrics(_ table: MarkdownTable, style: MarkdownStyle,
                                     columnCount: Int) -> TableMetrics {
        /// Breathing room between one column's text and the next column's start.
        /// Tightened before the type is, since a narrower gap costs less legibility
        /// than a smaller font does.
        var gutter: CGFloat = 12
        let tightGutter: CGFloat = 6
        /// Narrow enough to stay readable, wide enough that shrinking is a last resort.
        let minimumFontScale: CGFloat = 0.8

        /// Natural width of every column at this scale, measured from the rendered
        /// cells — so a mono code span or a bold header counts for what it actually
        /// draws rather than for what the body font would have drawn.
        func naturalWidths(scale: CGFloat) -> [CGFloat] {
            let (headerFont, bodyFont) = tableFonts(style: style, scale: scale)
            var rows: [(cells: [[MarkdownInline]], font: PlatformFont)] = []
            if table.hasHeader { rows.append((table.headers, headerFont)) }
            for row in table.rows { rows.append((row, bodyFont)) }

            // Flat on purpose. Measuring through a nested function that captured the
            // widths array crashed the 6.2 compiler in IRGen — see the note in the
            // README; this form is equivalent and does not.
            var widths = [CGFloat](repeating: 0, count: columnCount)
            for row in rows {
                for column in 0..<columnCount {
                    let cell = inlines(row.cells[safe: column] ?? [], style: style,
                                       font: row.font, color: style.textColor)
                    widths[column] = max(widths[column], cell.size().width.rounded(.up))
                }
            }
            return widths
        }

        // Shrink the type only as far as the overflow actually requires, and only down
        // to the floor — past that the table is unreadable and scrolling is the better
        // answer. Iterated because one pass does not land: font sizes quantise, so
        // halving the scale does not halve the measured width, and the gutters between
        // columns are a fixed cost the scale cannot touch.
        var scale: CGFloat = 1
        var widths = naturalWidths(scale: scale)
        if let available = style.contentWidth, available > 0 {
            let insets = MarkdownTableMetrics.horizontalPadding * 2
            if widths.reduce(0, +) > available - insets - gutter * CGFloat(columnCount - 1) {
                gutter = tightGutter
            }
            let budget = available - insets - gutter * CGFloat(columnCount - 1)
            for _ in 0..<4 {
                let total = widths.reduce(0, +)
                guard total > budget, scale > minimumFontScale else { break }
                scale = max(minimumFontScale, scale * budget / total)
                widths = naturalWidths(scale: scale)
            }
        }

        // Left edge of each column, and the right edge of the last one.
        var starts: [CGFloat] = []
        var x: CGFloat = MarkdownTableMetrics.horizontalPadding
        for width in widths {
            starts.append(x)
            x += width + gutter
        }

        return TableMetrics(widths: widths, starts: starts, gutter: gutter, scale: scale)
    }

    private static func tableFonts(style: MarkdownStyle,
                                   scale: CGFloat) -> (header: PlatformFont, body: PlatformFont) {
        let size = style.bodyFontSize * 0.95 * scale
        return (PlatformFont.markdownSystem(size: size, weight: .semibold),
                PlatformFont.markdownSystem(size: size))
    }

    /// Columns are laid out with tab stops on both platforms.
    ///
    /// AppKit has `NSTextTable`, which sizes and rules its own cells, and this used
    /// to use it there. It was dropped for one layout everywhere: the two platforms
    /// disagreed visibly — native tables stretch columns to fill the width and rule
    /// them vertically, where the tab-stop layout sizes each column to its content —
    /// and a table is the one block a reader is most likely to compare across
    /// devices. The cost is real and worth naming: `NSTextTable` can wrap a cell onto
    /// a second line and this cannot, because a tab-stop row is a single paragraph.
    /// Sizing columns to their content, and scaling the table when that does not fit,
    /// is what keeps that from mattering.
    ///
    /// Either way the table stays inside the one text storage, which is the property
    /// the whole renderer is built around — a SwiftUI grid here would reintroduce
    /// exactly the selection break this replaces.
    /// Columns are measured rather than fixed. A fixed grid breaks on the cell that
    /// is wider than its column: the text runs past the next tab stop, that stop is
    /// skipped, and the rest of the row lands in the wrong column or wraps to the
    /// next line with nothing holding it in place. Since a tab-stop row is one
    /// paragraph, a wrapped cell cannot be confined to its column — so the columns
    /// are sized to the content up front, and the whole table is scaled to fit when
    /// the content asks for more room than there is.
    static func table(_ table: MarkdownTable, style: MarkdownStyle) -> NSAttributedString {
        let columnCount = max(table.headers.count, table.rows.map(\.count).max() ?? 0)
        guard columnCount > 0 else { return NSAttributedString() }

        let metrics = tableMetrics(table, style: style, columnCount: columnCount)
        let widths = metrics.widths
        let starts = metrics.starts
        let gutter = metrics.gutter
        let scale = metrics.scale

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        // The row's own padding, which also gives the rules between rows somewhere
        // to sit that isn't tight against the type.
        paragraph.paragraphSpacing = MarkdownTableMetrics.verticalPadding
        paragraph.paragraphSpacingBefore = MarkdownTableMetrics.verticalPadding
        paragraph.firstLineHeadIndent = MarkdownTableMetrics.horizontalPadding
        paragraph.headIndent = MarkdownTableMetrics.horizontalPadding
        // Negative is measured in from the trailing edge, so an overlong cell stops
        // at the table's inner edge rather than running under its border.
        paragraph.tailIndent = -MarkdownTableMetrics.horizontalPadding
        paragraph.tabStops = (1..<columnCount).map { column in
            // A tab stop's alignment decides what the location means: where the text
            // starts, ends, or centres. That is what carries the column alignment
            // here, since the paragraph's own alignment would apply to the whole row.
            switch table.alignments[safe: column] ?? .leading {
            case .leading:
                return NSTextTab(textAlignment: .left, location: starts[column])
            case .center:
                return NSTextTab(textAlignment: .center,
                                 location: starts[column] + widths[column] / 2)
            case .trailing:
                return NSTextTab(textAlignment: .right,
                                 location: starts[column] + widths[column])
            }
        }
        // Anything past the last declared stop — a row with more cells than the
        // header promised — keeps landing on a regular grid instead of piling up.
        paragraph.defaultTabInterval = (widths.max() ?? 80) + gutter

        let out = NSMutableAttributedString()
        let (headerFont, bodyFont) = tableFonts(style: style, scale: scale)

        var rowIndex = 0
        func appendRow(_ cells: [[MarkdownInline]], font: PlatformFont, isHeader: Bool) {
            let start = out.length
            for column in 0..<columnCount {
                if column > 0 { out.append(NSAttributedString(string: "\t")) }
                out.append(inlines(cells[safe: column] ?? [], style: style,
                                   font: font, color: style.textColor))
            }
            out.append(NSAttributedString(string: "\n"))
            let range = NSRange(location: start, length: out.length - start)
            out.addAttribute(tableRowAttribute, value: rowIndex, range: range)
            if isHeader { out.addAttribute(tableHeaderAttribute, value: true, range: range) }
            rowIndex += 1
        }

        if table.hasHeader { appendRow(table.headers, font: headerFont, isHeader: true) }
        for row in table.rows { appendRow(row, font: bodyFont, isHeader: false) }

        out.addAttribute(.paragraphStyle, value: paragraph,
                         range: NSRange(location: 0, length: out.length))
        out.addAttribute(tableAttribute, value: true, range: NSRange(location: 0, length: out.length))
        return out
    }

    // MARK: - Inlines

    private static func inlines(_ nodes: [MarkdownInline], style: MarkdownStyle,
                                font: PlatformFont, color: PlatformColor) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        for node in nodes {
            out.append(inline(node, style: style, font: font, color: color))
        }
        return out
    }

    private static func inline(_ node: MarkdownInline, style: MarkdownStyle,
                               font: PlatformFont, color: PlatformColor) -> NSAttributedString {
        switch node {
        case .text(let string):
            return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])

        case .strong(let children):
            return inlines(children, style: style, font: font.addingMarkdownTrait(.bold), color: color)

        case .emphasis(let children):
            return inlines(children, style: style, font: font.addingMarkdownTrait(.italic), color: color)

        case .strikethrough(let children):
            let out = inlines(children, style: style, font: font, color: color)
            out.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue,
                             range: NSRange(location: 0, length: out.length))
            return out

        case .highlight(let children):
            let out = inlines(children, style: style, font: font, color: color)
            out.addAttribute(.backgroundColor, value: style.highlightColor,
                             range: NSRange(location: 0, length: out.length))
            return out

        case .subscriptText(let children):
            let out = inlines(children, style: style, font: font.withSize(font.pointSize * 0.75), color: color)
            out.addAttribute(.baselineOffset, value: -font.pointSize * 0.2,
                             range: NSRange(location: 0, length: out.length))
            return out

        case .superscriptText(let children):
            let out = inlines(children, style: style, font: font.withSize(font.pointSize * 0.75), color: color)
            out.addAttribute(.baselineOffset, value: font.pointSize * 0.35,
                             range: NSRange(location: 0, length: out.length))
            return out

        case .math(let children):
            // Already translated out of LaTeX; the italic face marks it as math.
            return inlines(children, style: style,
                           font: mathFont(size: font.pointSize), color: color)

        case .code(let string):
            // Hair spaces keep the fill off the glyphs, but they are whitespace: at a
            // wrap they land at the end of the previous line or the start of the next,
            // and TextKit paints a whitespace run's background out to the container
            // edge. That left a grey bar on the line above a span that wrapped. So the
            // spaces stay for the gap and the fill goes on the code alone.
            let codeFont = PlatformFont.markdownMono(size: font.pointSize * 0.92)
            let out = NSMutableAttributedString(string: "\u{200A}\(string)\u{200A}", attributes: [
                .font: codeFont,
                .foregroundColor: color,
            ])
            // Not `codeBackground`: a code block is a panel the eye is meant to land on,
            // whereas an inline span sits mid-sentence and only needs to be set apart
            // from the prose around it.
            out.addAttribute(.backgroundColor, value: PlatformColor.markdownQuaternaryLabel,
                             range: NSRange(location: 1, length: out.length - 2))
            return out

        case .link(let children, let destination):
            let out = inlines(children, style: style, font: font, color: style.accentColor)
            let range = NSRange(location: 0, length: out.length)
            if let url = URL(string: destination) {
                out.addAttribute(.link, value: url, range: range)
            }
            out.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            return out

        case .image(let alt, let source):
            // Images render as a labelled link rather than being fetched: chat content
            // is untrusted, and silently loading remote URLs would leak the session.
            let label = alt.isEmpty ? source : alt
            let out = NSMutableAttributedString(string: "🖼 \(label)", attributes: [
                .font: font,
                .foregroundColor: style.accentColor,
            ])
            if let url = URL(string: source) {
                out.addAttribute(.link, value: url, range: NSRange(location: 0, length: out.length))
            }
            return out

        case .footnoteReference(let label):
            return NSAttributedString(string: label, attributes: [
                .font: PlatformFont.markdownSystem(size: font.pointSize * 0.75),
                .foregroundColor: style.accentColor,
                .baselineOffset: font.pointSize * 0.35,
            ])
        }
    }
}

// MARK: - Helpers


private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
