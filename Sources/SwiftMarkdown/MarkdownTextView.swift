//
//  MarkdownTextView.swift
//  SwiftMarkdown
//
//  A non-editable text view hosting one message's rendered Markdown. Sizes itself
//  to its content so the surrounding chat ScrollView still does the scrolling.
//
//  The decorations below — code panels, block-quote bars, horizontal rules —
//  cannot be expressed as text attributes, so both platforms draw them by reading
//  the marker attributes the builder left behind.
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Corner radius shared by the code panel and its Copy button chrome.
enum MarkdownDecoration {
    static let codeCornerRadius: CGFloat = 8

    /// Draws the panels, bars and rules for `storage` into the current context.
    /// Written against TextKit 1 because `NSTextTable` — which GFM tables need on
    /// macOS — has no TextKit 2 equivalent.
    static func draw(storage: NSTextStorage,
                     layoutManager: NSLayoutManager,
                     container: NSTextContainer,
                     origin: CGPoint,
                     style: MarkdownStyle) {
        let full = NSRange(location: 0, length: storage.length)
        guard full.length > 0 else { return }

        func box(_ range: NSRange) -> CGRect {
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            return layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
                .offsetBy(dx: origin.x, dy: origin.y)
        }

        storage.enumerateAttribute(MarkdownAttributedBuilder.codeBlockAttribute, in: full) { value, range, _ in
            guard value != nil else { return }
            let rect = box(range).insetBy(dx: -4, dy: -6)
            style.codeBackground.setFill()
            fill(roundedRect: rect, radius: codeCornerRadius)
        }

        if MarkdownAttributedBuilder.debugBlockBorders {
            storage.enumerateAttribute(MarkdownAttributedBuilder.blockBoundaryAttribute, in: full) { value, range, _ in
                guard value != nil else { return }
                PlatformColor.systemBlue.setStroke()
                stroke(roundedRect: box(range), radius: 0, lineWidth: 1)
            }
        }

        storage.enumerateAttribute(MarkdownAttributedBuilder.quoteDepthAttribute, in: full) { value, range, _ in
            guard let depth = value as? Int else { return }
            let rect = box(range)
            style.quoteBarColor.setFill()
            for level in 0..<depth {
                let x = rect.minX + CGFloat(level) * 18 + 2
                fill(rect: CGRect(x: x, y: rect.minY, width: 3, height: rect.height))
            }
        }

        storage.enumerateAttribute(MarkdownAttributedBuilder.thematicBreakAttribute, in: full) { value, range, _ in
            guard value != nil else { return }
            let rect = box(range)
            // The divider colour is tuned for hairlines between chrome and disappears
            // against the message background; the rule reads as a break only in the
            // secondary text colour.
            style.secondaryColor.setFill()
            fill(rect: CGRect(x: rect.minX, y: rect.midY, width: container.size.width, height: 1))
        }

        // The tab-stop table draws no cell borders of its own, so the whole frame is
        // drawn here: a rounded outer border, a filled header, and a rule between
        // each pair of rows. Only horizontal rules, no column
        // dividers: with columns sized to their content the vertical gaps are uneven,
        // and ruling them draws attention to that rather than to the data.
        storage.enumerateAttribute(MarkdownAttributedBuilder.tableAttribute, in: full) { value, range, _ in
            guard value != nil else { return }

            // Row boxes in document order. A row's glyph box is just its text, so the
            // padding around it is added back here — the two halves share
            // `MarkdownTableMetrics` precisely so these agree.
            var rows: [(index: Int, box: CGRect)] = []
            storage.enumerateAttribute(MarkdownAttributedBuilder.tableRowAttribute,
                                       in: range) { value, rowRange, _ in
                guard let index = value as? Int else { return }
                rows.append((index, box(rowRange)))
            }
            rows.sort { $0.index < $1.index }
            guard let first = rows.first, let last = rows.last else { return }

            let pad = MarkdownTableMetrics.verticalPadding
            // Full content width, not the glyph width: a short final column would
            // otherwise pull the right edge in and leave the table ragged.
            let rect = CGRect(x: origin.x,
                              y: first.box.minY - pad,
                              width: container.size.width,
                              height: (last.box.maxY + pad) - (first.box.minY - pad))

            clipped(to: rect, radius: MarkdownTableMetrics.cornerRadius) {
                if let header = rows.first(where: { isHeader(storage, row: $0.index, within: range) }) {
                    style.codeHeaderBackground.setFill()
                    fill(rect: CGRect(x: rect.minX, y: rect.minY,
                                      width: rect.width,
                                      height: (header.box.maxY + pad) - rect.minY))
                }

                // A rule under every row but the last, placed midway between the two
                // rows' text so it reads as belonging to neither.
                style.dividerColor.setFill()
                for (current, next) in zip(rows, rows.dropFirst()) {
                    let y = ((current.box.maxY + next.box.minY) / 2).rounded()
                    fill(rect: CGRect(x: rect.minX, y: y, width: rect.width, height: 1))
                }
            }

            style.dividerColor.setStroke()
            stroke(roundedRect: rect, radius: MarkdownTableMetrics.cornerRadius,
                   lineWidth: MarkdownTableMetrics.borderWidth)
        }
    }

    /// Whether the row at `index` is the one marked as the table's header.
    private static func isHeader(_ storage: NSTextStorage, row index: Int, within table: NSRange) -> Bool {
        var result = false
        storage.enumerateAttribute(MarkdownAttributedBuilder.tableRowAttribute,
                                   in: table) { value, range, stop in
            guard value as? Int == index else { return }
            result = storage.attribute(MarkdownAttributedBuilder.tableHeaderAttribute,
                                       at: range.location, effectiveRange: nil) != nil
            stop.pointee = true
        }
        return result
    }

    /// The header row's range inside a table's range, if it is marked.
    private static func headerRange(in storage: NSTextStorage, within table: NSRange) -> NSRange? {
        var found: NSRange?
        storage.enumerateAttribute(MarkdownAttributedBuilder.tableHeaderAttribute, in: table) { value, range, stop in
            if value != nil {
                found = range
                stop.pointee = true
            }
        }
        return found
    }

    /// Runs `body` with the current context clipped to a rounded rect.
    private static func clipped(to rect: CGRect, radius: CGFloat, _ body: () -> Void) {
        #if canImport(AppKit)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
        body()
        NSGraphicsContext.restoreGraphicsState()
        #else
        guard let context = UIGraphicsGetCurrentContext() else { return body() }
        context.saveGState()
        UIBezierPath(roundedRect: rect, cornerRadius: radius).addClip()
        body()
        context.restoreGState()
        #endif
    }

    private static func fill(roundedRect: CGRect, radius: CGFloat) {
        #if canImport(AppKit)
        NSBezierPath(roundedRect: roundedRect, xRadius: radius, yRadius: radius).fill()
        #else
        UIBezierPath(roundedRect: roundedRect, cornerRadius: radius).fill()
        #endif
    }

    private static func fill(rect: CGRect) {
        #if canImport(AppKit)
        NSBezierPath(rect: rect).fill()
        #else
        UIBezierPath(rect: rect).fill()
        #endif
    }


    private static func stroke(roundedRect rect: CGRect, radius: CGFloat, lineWidth: CGFloat) {
        // Matches the native table border's own bounding box exactly — this draws
        // on top of it (called after `super.drawBackground`/`super.draw` below), so
        // sizing it any smaller left both edges visible as a double border instead
        // of this one fully covering the native edge that goes missing on the right.
        #if canImport(AppKit)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        #else
        let path = UIBezierPath(roundedRect: rect, cornerRadius: radius)
        #endif
        path.lineWidth = lineWidth
        path.stroke()
    }
}

// MARK: - AppKit

#if canImport(AppKit)

public final class MarkdownNSTextView: NSTextView {

    var style: MarkdownStyle?

    /// The text currently in the storage, by identity. A message whose segments were
    /// reused hands back the very same string, and comparing pointers settles that in
    /// no time where comparing contents is proportional to the message.
    var applied: NSAttributedString?

    /// Last measurement, valid while both the text and the proposed width hold.
    var measurement: MarkdownMeasurement?

    /// TextKit 1 ownership runs storage -> layout manager -> container, and the
    /// back-references are weak. The view has to keep the top of that chain alive.
    var markdownTextStorage: NSTextStorage?
    var markdownLayoutManager: NSLayoutManager?

    override public func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let style, let layoutManager, let textContainer, let textStorage else { return }
        MarkdownDecoration.draw(storage: textStorage, layoutManager: layoutManager,
                                container: textContainer, origin: textContainerOrigin,
                                style: style)
    }

    // Chat text is read-only, but it still has to take focus for selection to work.
    override public var acceptsFirstResponder: Bool { true }
}

public struct MarkdownTextViewRepresentable: NSViewRepresentable {

    public let attributed: NSAttributedString
    public let style: MarkdownStyle

    /// Extra room above and below the text. Only the scrolling table view asks for it:
    /// the table's border is painted a few points outside the outermost row, and with
    /// the view sized exactly to its glyphs that border falls outside the bounds and
    /// is clipped away.
    public var verticalInset: CGFloat = 0

    public init(attributed: NSAttributedString, style: MarkdownStyle, verticalInset: CGFloat = 0) {
        self.attributed = attributed
        self.style = style
        self.verticalInset = verticalInset
    }

    public func makeNSView(context: Context) -> MarkdownNSTextView {
        let (storage, layoutManager, container) = makeTextKitStack()

        let textView = MarkdownNSTextView(frame: .zero, textContainer: container)
        textView.markdownTextStorage = storage
        textView.markdownLayoutManager = layoutManager
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: verticalInset)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.linkTextAttributes = [
            .foregroundColor: style.accentColor,
            .cursor: NSCursor.pointingHand,
        ]
        textView.style = style
        return textView
    }

    public func updateNSView(_ textView: MarkdownNSTextView, context: Context) {
        textView.style = style
        textView.textContainerInset = NSSize(width: 0, height: verticalInset)
        guard textView.applied !== attributed else { return }
        if textView.textStorage?.matchesChat(attributed) != true {
            textView.textStorage?.setAttributedString(attributed)
        }
        textView.applied = attributed
        textView.needsDisplay = true
    }

    public func sizeThatFits(_ proposal: ProposedViewSize,
                             nsView: MarkdownNSTextView,
                             context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return CGSize(width: width,
                      height: nsView.height(of: attributed, width: width) + verticalInset * 2)
    }
}

#endif

// MARK: - UIKit

#if canImport(UIKit) && !canImport(AppKit)

public final class MarkdownUITextView: UITextView {

    var style: MarkdownStyle?

    /// The text currently in the storage, by identity. A message whose segments were
    /// reused hands back the very same string, and comparing pointers settles that in
    /// no time where comparing contents is proportional to the message.
    var applied: NSAttributedString?

    /// Last measurement, valid while both the text and the proposed width hold.
    var measurement: MarkdownMeasurement?

    /// TextKit 1 ownership runs storage -> layout manager -> container, and the
    /// back-references are weak. The view has to keep the top of that chain alive.
    var markdownTextStorage: NSTextStorage?
    var markdownLayoutManager: NSLayoutManager?

    override public func draw(_ rect: CGRect) {
        guard let style, let container = textContainer as NSTextContainer? else {
            super.draw(rect)
            return
        }
        // Decorations go under the glyphs, so they are drawn before `super`.
        MarkdownDecoration.draw(storage: textStorage, layoutManager: layoutManager,
                                container: container,
                                origin: CGPoint(x: textContainerInset.left,
                                                y: textContainerInset.top),
                                style: style)
        super.draw(rect)
    }
}

public struct MarkdownTextViewRepresentable: UIViewRepresentable {

    public let attributed: NSAttributedString
    public let style: MarkdownStyle

    /// Extra room above and below the text. Only the scrolling table view asks for it:
    /// the table's border is painted a few points outside the outermost row, and with
    /// the view sized exactly to its glyphs that border falls outside the bounds and
    /// is clipped away.
    public var verticalInset: CGFloat = 0

    public init(attributed: NSAttributedString, style: MarkdownStyle, verticalInset: CGFloat = 0) {
        self.attributed = attributed
        self.style = style
        self.verticalInset = verticalInset
    }

    public func makeUIView(context: Context) -> MarkdownUITextView {
        let (storage, layoutManager, container) = makeTextKitStack()

        let textView = MarkdownUITextView(frame: .zero, textContainer: container)
        textView.markdownTextStorage = storage
        textView.markdownLayoutManager = layoutManager
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false     // the transcript scrolls, not the message
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: verticalInset, left: 0,
                                                   bottom: verticalInset, right: 0)
        textView.linkTextAttributes = [.foregroundColor: style.accentColor]
        textView.style = style
        return textView
    }

    public func updateUIView(_ textView: MarkdownUITextView, context: Context) {
        textView.style = style
        textView.textContainerInset = UIEdgeInsets(top: verticalInset, left: 0,
                                                   bottom: verticalInset, right: 0)
        guard textView.applied !== attributed else { return }
        if !textView.textStorage.matchesChat(attributed) {
            textView.textStorage.setAttributedString(attributed)
        }
        textView.applied = attributed
        textView.setNeedsDisplay()
    }

    public func sizeThatFits(_ proposal: ProposedViewSize,
                             uiView: MarkdownUITextView,
                             context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return CGSize(width: width,
                      height: uiView.height(of: attributed, width: width) + verticalInset * 2)
    }
}

#endif

// MARK: - Shared plumbing

/// An explicit TextKit 1 stack. Both the decoration drawing above and macOS table
/// layout need a layout manager, which the default TextKit 2 stack does not vend.
func makeTextKitStack() -> (NSTextStorage, NSLayoutManager, NSTextContainer) {
    let storage = NSTextStorage()
    let layoutManager = NSLayoutManager()
    let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    container.widthTracksTextView = true
    container.lineFragmentPadding = 0
    layoutManager.addTextContainer(container)
    storage.addLayoutManager(layoutManager)
    return (storage, layoutManager, container)
}

/// One remembered result of ``measuredHeight(of:width:)``.
struct MarkdownMeasurement {
    let attributed: NSAttributedString
    let width: CGFloat
    let height: CGFloat
}

#if canImport(AppKit)
extension MarkdownNSTextView: MarkdownMeasuring {}
#elseif canImport(UIKit)
extension MarkdownUITextView: MarkdownMeasuring {}
#endif

/// Caches a message's measured height against the view that will display it.
///
/// SwiftUI re-proposes a size on every layout pass, and laying out a whole message to
/// answer costs the same whether or not anything changed. During a stream that is once
/// per frame for every message on screen — the settled ones included, which is most of a
/// long transcript.
@MainActor
protocol MarkdownMeasuring: AnyObject {
    var measurement: MarkdownMeasurement? { get set }
}

extension MarkdownMeasuring {
    func height(of attributed: NSAttributedString, width: CGFloat) -> CGFloat {
        // Identity, not equality: the segment builder hands back the same string for text
        // it reused, and an equality check here would be the cost this is avoiding.
        if let measurement, measurement.attributed === attributed, measurement.width == width {
            return measurement.height
        }
        let height = MarkdownHeightCache.height(of: attributed, width: width)
        measurement = MarkdownMeasurement(attributed: attributed, width: width, height: height)
        return height
    }
}

/// Measured heights, kept outside the views that use them.
///
/// The per-view cache above dies with its view, which in a lazy stack is every time a
/// row scrolls far enough away. Laying the same settled message out again on the way
/// back costs exactly what it cost the first time. Keyed on the attributed string
/// itself, so pre-rendered segments — which outlive any view — keep their heights for
/// as long as the caller holds them.
@MainActor
enum MarkdownHeightCache {

    /// Weak keys with pointer identity: the entry goes away with the string it measured,
    /// and comparing two long attributed strings for equality would cost more than the
    /// measurement this is saving.
    private static let heights = NSMapTable<NSAttributedString, NSMutableDictionary>(
        keyOptions: [.weakMemory, .objectPointerPersonality],
        valueOptions: .strongMemory)

    static func height(of attributed: NSAttributedString, width: CGFloat) -> CGFloat {
        let key = width as NSNumber
        if let widths = heights.object(forKey: attributed),
           let height = widths[key] as? CGFloat {
            return height
        }
        let height = measuredHeight(of: attributed, width: width)
        let widths = heights.object(forKey: attributed) ?? {
            let fresh = NSMutableDictionary()
            heights.setObject(fresh, forKey: attributed)
            return fresh
        }()
        widths[key] = height
        return height
    }
}

/// Measures with a disposable TextKit stack rather than the live view's own container.
/// The live container tracks the view's actual bounds on its own (`widthTracksTextView`);
/// mutating it here too, to test a candidate width mid-layout, raced that auto-tracking
/// during a continuous resize — SwiftUI's speculative width and AppKit's committed one
/// fought over the same object, and the message bounced between the two from frame to
/// frame. A scratch stack settles that: this call can never be seen by the live view.
func measuredHeight(of attributed: NSAttributedString, width: CGFloat) -> CGFloat {
    let storage = NSTextStorage(attributedString: attributed)
    let layoutManager = NSLayoutManager()
    let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
    container.lineFragmentPadding = 0
    layoutManager.addTextContainer(container)
    storage.addLayoutManager(layoutManager)

    layoutManager.ensureLayout(for: container)
    return ceil(layoutManager.usedRect(for: container).height)
}

extension NSTextStorage {
    /// Named to avoid colliding with NSAttributedString's own `isEqual(to:)`.
    func matchesChat(_ other: NSAttributedString) -> Bool {
        length == other.length && string == other.string
    }
}
