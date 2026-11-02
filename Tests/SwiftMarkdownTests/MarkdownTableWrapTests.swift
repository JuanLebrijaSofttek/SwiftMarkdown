//
//  MarkdownTableWrapTests.swift
//  SwiftMarkdownTests
//
//  A long cell wraps within its column instead of widening the whole table, so a
//  table fits the width it is given and scrolls only when wrapping cannot help.
//

import Foundation
import Testing
@testable import SwiftMarkdown

@Suite("Table wrapping")
struct MarkdownTableWrapTests {

    private static let source = """
    | Harness | Stars | Licence | Notes |
    |---|---|---|---|
    | Gemini CLI | ~109k | Apache-2.0 | Repo now says it is for Code Assist Standard/Enterprise; free and AI Pro/Ultra access moved to Antigravity CLI on 18 June 2026 |
    | Cline | ~71.2k | Apache-2.0 | JetBrains plugin is not open source |
    """

    private func table() throws -> MarkdownTable {
        guard case .table(let table) = MarkdownBlockParser.parse(Self.source)[0] else {
            throw CocoaError(.featureUnsupported)
        }
        return table
    }

    @Test("A long cell wraps so the table fits its width")
    func wrapsToFit() throws {
        let table = try table()
        var style = MarkdownStyle.standard(appearanceIsDark: false)
        style.contentWidth = 520

        #expect(MarkdownAttributedBuilder.tableWidth(table, style: style) <= 520)
        let rendered = MarkdownAttributedBuilder.table(table, style: style).string
        #expect(rendered.contains("\u{2028}"))
        // Every word survives the wrapping, in order.
        let words = rendered.split(whereSeparator: { $0.isWhitespace || $0 == "\u{2028}" })
        #expect(words.joined(separator: " ").contains("Antigravity CLI on 18 June 2026"))
    }

    @Test("Short columns keep their natural width")
    func shortRowsUnwrapped() throws {
        let table = try table()
        var style = MarkdownStyle.standard(appearanceIsDark: false)
        style.contentWidth = 520
        let rows = MarkdownAttributedBuilder.table(table, style: style).string
            .split(separator: "\n")
        // Header and the short "Cline" row stay on one line.
        #expect(!rows[0].contains("\u{2028}"))
        #expect(!rows[2].contains("\u{2028}"))
    }

    @Test("A long column is capped even with room to spare")
    func capsWideColumns() throws {
        let table = try table()
        var style = MarkdownStyle.standard(appearanceIsDark: false)
        style.contentWidth = 4000
        let width = MarkdownAttributedBuilder.tableWidth(table, style: style)
        #expect(width < 4000)
        #expect(MarkdownAttributedBuilder.table(table, style: style).string.contains("\u{2028}"))
    }
}
