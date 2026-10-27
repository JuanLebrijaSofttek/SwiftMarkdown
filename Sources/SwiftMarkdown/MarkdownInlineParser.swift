//
//  MarkdownInlineParser.swift
//  SwiftMarkdown
//
//  Inline span parsing: emphasis, code spans, links, images and the extended
//  delimiters from the Markdown Guide cheat sheet.
//

import Foundation

public enum MarkdownInlineParser {

    public static func parse(_ text: String) -> [MarkdownInline] {
        let chars = Array(text)
        return parse(chars, 0, chars.count, autolinks: true)
    }

    // MARK: - Core

    /// `autolinks` is off inside a link's label: a URL there is the label's
    /// text, and a link inside a link has nowhere to go.
    private static func parse(_ c: [Character], _ lo: Int, _ hi: Int, autolinks: Bool) -> [MarkdownInline] {
        var out: [MarkdownInline] = []
        var buf = ""
        var i = lo

        func flush() {
            if !buf.isEmpty { out.append(.text(buf)); buf = "" }
        }

        while i < hi {
            let ch = c[i]

            // Backslash escape — the next punctuation character is literal.
            if ch == "\\", i + 1 < hi, c[i + 1].isPunctuation || c[i + 1].isSymbol {
                buf.append(c[i + 1])
                i += 2
                continue
            }

            // A soft break stays a break: model output leans on its own line structure,
            // so joining lines into a paragraph the way CommonMark does reads worse here.
            if ch == "\n" {
                while buf.hasSuffix(" ") { buf.removeLast() }
                buf.append("\n")
                i += 1
                continue
            }

            // Code spans bind tighter than everything else — their content is literal.
            if ch == "`" {
                let run = runLength(c, i, "`", hi)
                if let close = findCodeFence(c, from: i + run, hi: hi, length: run) {
                    flush()
                    out.append(.code(codeSpanContent(c, i + run, close)))
                    i = close + run
                    continue
                }
            }

            // Math span: $...$ or $$...$$. Checked after code spans so `$5` in a code
            // span stays literal, and gated by looksLikeMath so prose about prices does
            // not turn into an equation.
            if ch == "$" {
                let run = min(runLength(c, i, "$", hi), 2)
                if let close = findCloserRun(c, from: i + run, hi: hi, marker: "$", length: run) {
                    let body = String(c[(i + run)..<close])
                    if MarkdownMath.looksLikeMath(body) {
                        flush()
                        out.append(.math(MarkdownMath.render(body)))
                        i = close + run
                        continue
                    }
                }
            }

            // Autolinks: `<https://…>`, and bare `https://…` or `www.…` URLs as
            // GitHub renders them. Models write sources as bare URLs as often as
            // as links, and a URL that cannot be clicked has to be copied by hand.
            if autolinks, let link = scanAutolink(c, at: i, lo: lo, hi: hi) {
                flush()
                out.append(.link(children: [.text(link.text)], destination: link.destination))
                i = link.end
                continue
            }

            // Image: ![alt](src)
            if ch == "!", i + 1 < hi, c[i + 1] == "[",
               let link = scanLink(c, at: i + 1, hi: hi) {
                flush()
                out.append(.image(alt: String(c[link.labelRange]), source: link.destination))
                i = link.end
                continue
            }

            if ch == "[" {
                // Footnote reference: [^label]
                if i + 1 < hi, c[i + 1] == "^",
                   let close = find(c, from: i + 2, hi: hi, char: "]") {
                    flush()
                    out.append(.footnoteReference(label: String(c[(i + 2)..<close])))
                    i = close + 1
                    continue
                }
                if let link = scanLink(c, at: i, hi: hi) {
                    flush()
                    out.append(.link(children: parse(c, link.labelRange.lowerBound, link.labelRange.upperBound,
                                                     autolinks: false),
                                     destination: link.destination))
                    i = link.end
                    continue
                }
            }

            // Paired delimiters, longest first so ** beats * and ~~ beats ~.
            if let match = matchDelimiter(c, at: i, hi: hi) {
                flush()
                out.append(match.wrap(parse(c, i + match.length, match.closeIndex, autolinks: autolinks)))
                i = match.closeIndex + match.length
                continue
            }

            buf.append(ch)
            i += 1
        }

        flush()
        return out
    }

    // MARK: - Delimiters

    private struct DelimiterMatch {
        let length: Int
        let closeIndex: Int
        let wrap: @Sendable ([MarkdownInline]) -> MarkdownInline
    }

    /// Delimiter specs in resolution order. Longer runs are listed before their
    /// single-character forms so `**` is never mistaken for two `*`.
    private static let delimiters: [(marker: Character, length: Int, intrawordAllowed: Bool, wrap: @Sendable ([MarkdownInline]) -> MarkdownInline)] = [
        ("*", 2, true,  { .strong($0) }),
        ("_", 2, false, { .strong($0) }),
        ("~", 2, true,  { .strikethrough($0) }),
        ("=", 2, true,  { .highlight($0) }),
        ("*", 1, true,  { .emphasis($0) }),
        ("_", 1, false, { .emphasis($0) }),
        ("~", 1, true,  { .subscriptText($0) }),
        ("^", 1, true,  { .superscriptText($0) }),
    ]

    private static func matchDelimiter(_ c: [Character], at i: Int, hi: Int) -> DelimiterMatch? {
        for spec in delimiters {
            guard c[i] == spec.marker, runLength(c, i, spec.marker, hi) >= spec.length else { continue }
            // `_` inside a word is a literal underscore, so snake_case and __init__ survive.
            if !spec.intrawordAllowed, i > 0, c[i - 1].isLetter || c[i - 1].isNumber { continue }
            // CommonMark left-flanking: an opener is never followed by whitespace, so
            // arithmetic like `2 * 3 * 4` stays literal instead of turning into italics.
            guard i + spec.length < hi, !c[i + spec.length].isWhitespace else { continue }
            guard let close = findCloser(c, from: i + spec.length, hi: hi,
                                         marker: spec.marker, length: spec.length,
                                         intrawordAllowed: spec.intrawordAllowed),
                  close > i + spec.length else { continue }
            return DelimiterMatch(length: spec.length, closeIndex: close, wrap: spec.wrap)
        }
        return nil
    }

    /// Finds the closing delimiter run, skipping escapes and code spans so a `*`
    /// inside backticks never closes emphasis opened outside them.
    private static func findCloser(_ c: [Character], from: Int, hi: Int,
                                   marker: Character, length: Int,
                                   intrawordAllowed: Bool) -> Int? {
        var j = from
        while j < hi {
            if c[j] == "\\" { j += 2; continue }
            if c[j] == "`" {
                let run = runLength(c, j, "`", hi)
                if let close = findCodeFence(c, from: j + run, hi: hi, length: run) {
                    j = close + run
                    continue
                }
            }
            if c[j] == marker, runLength(c, j, marker, hi) >= length {
                if !intrawordAllowed, j + length < hi, c[j + length].isLetter || c[j + length].isNumber {
                    j += length
                    continue
                }
                // Right-flanking: a closer is never preceded by whitespace.
                if c[j - 1].isWhitespace {
                    j += length
                    continue
                }
                return j
            }
            j += 1
        }
        return nil
    }

    // MARK: - Links

    private struct LinkScan {
        let labelRange: Range<Int>
        let destination: String
        let end: Int
    }

    /// Scans `[label](destination)` starting at the opening bracket. Brackets and
    /// parentheses are balanced so `[see (this)](url)` and nested labels survive.
    private static func scanLink(_ c: [Character], at i: Int, hi: Int) -> LinkScan? {
        guard c[i] == "[" else { return nil }
        var depth = 0
        var j = i
        var labelEnd = -1
        while j < hi {
            if c[j] == "\\" { j += 2; continue }
            if c[j] == "[" { depth += 1 }
            if c[j] == "]" {
                depth -= 1
                if depth == 0 { labelEnd = j; break }
            }
            j += 1
        }
        guard labelEnd > i, labelEnd + 1 < hi, c[labelEnd + 1] == "(" else { return nil }

        var parens = 0
        var k = labelEnd + 1
        var destEnd = -1
        while k < hi {
            if c[k] == "\\" { k += 2; continue }
            if c[k] == "(" { parens += 1 }
            if c[k] == ")" {
                parens -= 1
                if parens == 0 { destEnd = k; break }
            }
            k += 1
        }
        guard destEnd > labelEnd + 1 else { return nil }

        return LinkScan(labelRange: (i + 1)..<labelEnd,
                        destination: normalizeDestination(String(c[(labelEnd + 2)..<destEnd])),
                        end: destEnd + 1)
    }

    /// Strips the optional `<>` wrapper and any `"title"` suffix.
    private static func normalizeDestination(_ raw: String) -> String {
        var dest = raw.trimmingCharacters(in: .whitespaces)
        if let space = dest.firstIndex(where: { $0 == " " || $0 == "\t" }) {
            dest = String(dest[dest.startIndex..<space])
        }
        if dest.hasPrefix("<"), dest.hasSuffix(">"), dest.count >= 2 {
            dest = String(dest.dropFirst().dropLast())
        }
        return dest
    }

    // MARK: - Autolinks

    private struct AutolinkScan {
        let text: String
        let destination: String
        let end: Int
    }

    private static let schemes = ["https://", "http://"]

    /// A URL starting at `i`, as GitHub's extended autolinks read one.
    ///
    /// Bare URLs start at a word boundary and end at whitespace or `<`; trailing
    /// punctuation that ends the sentence rather than the URL — `.`, `,`, `)` with
    /// no `(` to close, quotes — is left out, so "see https://example.com." links
    /// `https://example.com`.
    private static func scanAutolink(_ c: [Character], at i: Int, lo: Int, hi: Int) -> AutolinkScan? {
        if c[i] == "<" {
            guard let close = find(c, from: i + 1, hi: hi, char: ">") else { return nil }
            let inner = String(c[(i + 1)..<close])
            guard schemes.contains(where: { inner.lowercased().hasPrefix($0) }),
                  !inner.contains(where: \.isWhitespace), inner.count > 8
            else { return nil }
            return AutolinkScan(text: inner, destination: inner, end: close + 1)
        }

        guard c[i] == "h" || c[i] == "H" || c[i] == "w" || c[i] == "W" else { return nil }
        if i > lo {
            let before = c[i - 1]
            guard before.isWhitespace || "*_~(\"'".contains(before) else { return nil }
        }
        let head = String(c[i..<min(hi, i + 8)]).lowercased()
        let isWWW = head.hasPrefix("www.")
        guard isWWW || schemes.contains(where: { head.hasPrefix($0) }) else { return nil }

        var end = i
        while end < hi, !c[end].isWhitespace, c[end] != "<" { end += 1 }
        // Trim what reads as the sentence's punctuation, then any `)` the URL
        // did not open.
        while end > i {
            let last = c[end - 1]
            if "?!.,:;*_~'\"".contains(last) {
                end -= 1
            } else if last == ")" {
                let opens = c[i..<end].filter { $0 == "(" }.count
                let closes = c[i..<end].filter { $0 == ")" }.count
                guard closes > opens else { break }
                end -= 1
            } else {
                break
            }
        }
        let text = String(c[i..<end])
        // Something after the scheme, and a dot in the host: `https://` alone
        // and `www.` alone are words.
        let rest = isWWW ? String(text.dropFirst(4)) : String(text.drop { $0 != "/" }.dropFirst(2))
        let host = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        guard !host.isEmpty, isWWW ? host.contains(".") : true,
              host.allSatisfy({ $0.isLetter || $0.isNumber || "-._:[]@".contains($0) })
        else { return nil }
        return AutolinkScan(text: text, destination: isWWW ? "https://" + text : text, end: end)
    }

    // MARK: - Scanning helpers

    private static func runLength(_ c: [Character], _ i: Int, _ ch: Character, _ hi: Int) -> Int {
        var n = 0
        while i + n < hi, c[i + n] == ch { n += 1 }
        return n
    }

    private static func find(_ c: [Character], from: Int, hi: Int, char: Character) -> Int? {
        var j = from
        while j < hi {
            if c[j] == "\\" { j += 2; continue }
            if c[j] == char { return j }
            j += 1
        }
        return nil
    }

    /// Locates a closing backtick run of exactly `length` — a longer run doesn't close a
    /// shorter opener, which is what lets ``code with ` inside`` work.
    /// Next run of `length` `marker` characters, skipping escapes. Used for math spans,
    /// which have no flanking rules of their own.
    private static func findCloserRun(_ c: [Character], from: Int, hi: Int,
                                      marker: Character, length: Int) -> Int? {
        var j = from
        while j < hi {
            if c[j] == "\\" { j += 2; continue }
            if c[j] == marker, runLength(c, j, marker, hi) >= length { return j }
            j += 1
        }
        return nil
    }

    private static func findCodeFence(_ c: [Character], from: Int, hi: Int, length: Int) -> Int? {
        var j = from
        while j < hi {
            if c[j] == "`" {
                let run = runLength(c, j, "`", hi)
                if run == length { return j }
                j += run
                continue
            }
            j += 1
        }
        return nil
    }

    /// CommonMark strips one leading and trailing space when both are present, so
    /// `` ` ``code`` ` `` renders without the padding used to escape the backticks.
    private static func codeSpanContent(_ c: [Character], _ lo: Int, _ hi: Int) -> String {
        var content = String(c[lo..<hi])
        if content.count > 2, content.hasPrefix(" "), content.hasSuffix(" "),
           content.contains(where: { $0 != " " }) {
            content = String(content.dropFirst().dropLast())
        }
        return content
    }
}
