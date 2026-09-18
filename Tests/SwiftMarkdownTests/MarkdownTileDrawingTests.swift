//
//  MarkdownTileDrawingTests.swift
//  SwiftMarkdownTests
//
//  `MarkdownDecoration.draw` only decorates what the dirty rect touches, so that the
//  cost of a scroll tracks the viewport rather than the length of the message. The
//  hazard in that is shapes: a code panel or a table that starts above the rect has to
//  be drawn whole anyway, or its corners get rounded at the tile boundary and its frame
//  ends up around whichever rows happened to be visible.
//
//  So: drawing in bands, the way a scroll view asks for tiles, must produce exactly
//  what one full draw produces — down to the pixel.
//

#if canImport(UIKit) && !canImport(AppKit)
import SwiftUI
import UIKit
import Testing
@testable import SwiftMarkdown

@MainActor
@Suite("Tile drawing")
struct MarkdownTileDrawingTests {

    @Test("Banded drawing matches a single full draw")
    func tilesMatchFullDraw() {
        let style = MarkdownStyle.standard(appearanceIsDark: false)

        var subjects: [(String, NSAttributedString)] = []
        for (index, segment) in MarkdownSegment.render(MarkdownPreviewSample.kitchenSink,
                                                       style: style).enumerated() {
            switch segment {
            case .prose(_, let attributed):
                subjects.append(("prose \(index)", attributed))
            case .table(_, let table):
                subjects.append(("table \(index)",
                                 MarkdownAttributedBuilder.table(table, style: style)))
            case .code:
                break   // its own view, with no decoration pass of its own
            }
        }
        // Panels, quotes, rules and a table, or this is testing nothing.
        #expect(subjects.count >= 4)

        // And one long unbroken run, tall enough to span many tiles.
        var long = ""
        while long.count < 10_000 {
            long += """
            ## Heading

            A paragraph with **bold** and `code`, long enough to wrap a few times at a
            phone width.

            > A quote, which draws a bar.

            ---

            """
        }
        for case .prose(_, let attributed) in MarkdownSegment.render(long, style: style) {
            subjects.append(("long prose", attributed))
        }

        for (name, attributed) in subjects {
            #expect(bandedDrawing(of: attributed, style: style) == fullDrawing(of: attributed, style: style),
                    "\(name) draws differently in bands than in one pass")
        }
    }

    // MARK: - Drawing

    private static let width: CGFloat = 390
    private static let band: CGFloat = 60

    private func fullDrawing(of attributed: NSAttributedString, style: MarkdownStyle) -> Data {
        draw(attributed, style: style) { view, _, _ in view.draw(view.bounds) }
    }

    private func bandedDrawing(of attributed: NSAttributedString, style: MarkdownStyle) -> Data {
        draw(attributed, style: style) { view, context, height in
            var y: CGFloat = 0
            while y < height {
                let band = CGRect(x: 0, y: y, width: Self.width,
                                  height: min(Self.band, height - y))
                // Clipped, because that is what the real tiled draw does.
                context.saveGState()
                context.clip(to: band)
                view.draw(band)
                context.restoreGState()
                y += Self.band
            }
        }
    }

    private func draw(_ attributed: NSAttributedString,
                      style: MarkdownStyle,
                      body: (MarkdownUITextView, CGContext, CGFloat) -> Void) -> Data {
        let height = measuredHeight(of: attributed, width: Self.width)

        let (storage, layoutManager, container) = makeTextKitStack()
        let view = MarkdownUITextView(
            frame: CGRect(x: 0, y: 0, width: Self.width, height: height),
            textContainer: container)
        view.markdownTextStorage = storage
        view.markdownLayoutManager = layoutManager
        view.isEditable = false
        view.isScrollEnabled = false
        view.backgroundColor = .white
        view.textContainerInset = .zero
        view.style = style
        storage.setAttributedString(attributed)
        view.layoutIfNeeded()

        let size = CGSize(width: Self.width, height: height)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            body(view, context.cgContext, height)
        }.pngData()!
    }
}
#endif
