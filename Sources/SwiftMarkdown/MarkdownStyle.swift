//
//  MarkdownStyle.swift
//  SwiftMarkdown
//
//  The concrete fonts and colors the attributed-string builder works in. A
//  separate type from the SwiftUI view layer because the builder runs below
//  SwiftUI and cannot resolve a `Color` itself.
//

import SwiftUI

public struct MarkdownStyle {

    // Changing any of these by hand drops the recorded identity, so a style adjusted
    // after it was built is no longer mistaken for the one it was built from.
    public var bodyFontSize: CGFloat = PlatformFont.markdownBodySize { didSet { identity = "" } }
    public var textColor: PlatformColor { didSet { identity = "" } }
    public var secondaryColor: PlatformColor { didSet { identity = "" } }
    public var accentColor: PlatformColor { didSet { identity = "" } }
    public var codeBackground: PlatformColor { didSet { identity = "" } }
    public var quoteBarColor: PlatformColor { didSet { identity = "" } }
    public var highlightColor: PlatformColor { didSet { identity = "" } }
    public var dividerColor: PlatformColor { didSet { identity = "" } }
    /// Fill for the code block's header strip.
    public var codeHeaderBackground: PlatformColor { didSet { identity = "" } }

    /// Width the text will be laid out in, when the caller knows it. Only the
    /// tab-stop table path consults it — that layout has to size its columns up
    /// front, having no equivalent of AppKit's automatic table layout to defer to.
    /// Left `nil`, columns take their natural widths and a wide table may wrap.
    public var contentWidth: CGFloat? { didSet { identity = "" } }

    /// Multipliers for H1…H6.
    public var headingScales: [CGFloat] = [1.7, 1.4, 1.2, 1.08, 1.0, 0.95] { didSet { identity = "" } }

    /// What this style was built from, when that is knowable — see ``key(for:)``.
    /// Empty for a style assembled colour by colour, which falls back to describing them.
    var identity: String = ""

    public init(bodyFontSize: CGFloat = PlatformFont.markdownBodySize,
                textColor: PlatformColor,
                secondaryColor: PlatformColor,
                accentColor: PlatformColor,
                codeBackground: PlatformColor,
                quoteBarColor: PlatformColor,
                highlightColor: PlatformColor,
                dividerColor: PlatformColor,
                codeHeaderBackground: PlatformColor,
                contentWidth: CGFloat? = nil,
                headingScales: [CGFloat] = [1.7, 1.4, 1.2, 1.08, 1.0, 0.95]) {
        self.bodyFontSize = bodyFontSize
        self.textColor = textColor
        self.secondaryColor = secondaryColor
        self.accentColor = accentColor
        self.codeBackground = codeBackground
        self.quoteBarColor = quoteBarColor
        self.highlightColor = highlightColor
        self.dividerColor = dividerColor
        self.codeHeaderBackground = codeHeaderBackground
        self.contentWidth = contentWidth
        self.headingScales = headingScales
    }

    /// Cheap identity for a style, used to notice theme and appearance changes — every
    /// attribute in a rendered message depends on these, so nothing survives one.
    ///
    /// Describing the colours is the fallback rather than the rule because a dynamic
    /// colour's description carries a per-instance UUID: two styles built from the same
    /// palette would never match, and every cache keyed on this would miss every time.
    static func key(for style: MarkdownStyle) -> String {
        style.identity.isEmpty
            ? "\(style.bodyFontSize)-\(style.textColor)-\(style.codeBackground)-\(style.accentColor)"
            : style.identity
    }

    /// The default style: system text colors, so a document follows the platform's
    /// appearance without the host configuring anything.
    ///
    /// `appearanceIsDark` is passed rather than read because this runs below SwiftUI,
    /// where there is no environment to ask — pass `colorScheme == .dark`.
    public static func standard(appearanceIsDark: Bool,
                                bodyFontSize: CGFloat = PlatformFont.markdownBodySize,
                                contentWidth: CGFloat? = nil) -> MarkdownStyle {
        var style = MarkdownStyle(
            bodyFontSize: bodyFontSize,
            textColor: .markdownLabel,
            secondaryColor: .markdownSecondaryLabel,
            accentColor: .markdownAccent,
            codeBackground: PlatformColor.from(MarkdownColors.codeBackground),
            quoteBarColor: PlatformColor.markdownSecondaryLabel.withAlphaComponent(0.4),
            // Yellow behind dark text needs less alpha than behind light text to
            // read as a highlight rather than a blot.
            highlightColor: PlatformColor.systemYellow.withAlphaComponent(appearanceIsDark ? 0.35 : 0.45),
            dividerColor: PlatformColor.from(MarkdownColors.divider),
            codeHeaderBackground: PlatformColor.from(MarkdownColors.codeHeader),
            contentWidth: contentWidth)
        // Width belongs in the identity: it changes what the table path builds, so a
        // style that differs only by width must not be mistaken for a cache hit.
        style.identity = "standard-\(appearanceIsDark)-\(bodyFontSize)-\(contentWidth ?? -1)"
        return style
    }
}

// MARK: - Chrome

/// The few fills the code-block chrome needs that no semantic system color covers.
/// Neutral greys on purpose: they sit correctly on any background the host puts
/// the document on, in either appearance.
public enum MarkdownColors {
    public static let codeBackground = Color.gray.opacity(0.15)
    public static let codeHeader = Color.gray.opacity(0.22)
    public static let divider = Color.gray.opacity(0.3)
}

// MARK: - Table metrics

/// Geometry the table shares between the two halves that draw it: the builder,
/// which reserves the space, and the text view, which paints into it. They have to
/// agree, and a constant in only one of them is how they stop agreeing.
enum MarkdownTableMetrics {
    /// Inset from the table's outer edge to its first column's text.
    static let horizontalPadding: CGFloat = 14
    /// Space above and below a row's text, so rows are not set solid.
    static let verticalPadding: CGFloat = 7
    static let cornerRadius: CGFloat = 8
    static let borderWidth: CGFloat = 1
}
