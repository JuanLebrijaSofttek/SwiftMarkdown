//
//  Platform.swift
//  SwiftMarkdown
//
//  AppKit and UIKit spell the same things differently. Everything the renderer
//  needs from either is funnelled through here, so the views below read as one
//  codebase instead of two interleaved ones.
//

import SwiftUI

#if canImport(AppKit)
import AppKit

public typealias PlatformColor = NSColor
public typealias PlatformFont = NSFont
typealias PlatformFontDescriptor = NSFontDescriptor
#elseif canImport(UIKit)
import UIKit

public typealias PlatformColor = UIColor
public typealias PlatformFont = UIFont
typealias PlatformFontDescriptor = UIFontDescriptor
#endif

extension PlatformFont {

    public static var markdownBodySize: CGFloat {
        #if canImport(AppKit)
        NSFont.systemFontSize
        #else
        UIFont.systemFontSize
        #endif
    }

    public static func markdownSystem(size: CGFloat, weight: PlatformFont.Weight = .regular) -> PlatformFont {
        systemFont(ofSize: size, weight: weight)
    }

    public static func markdownMono(size: CGFloat) -> PlatformFont {
        #if canImport(AppKit)
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        #else
        UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        #endif
    }

    /// Returns this font with `trait` added, or itself when the family has no
    /// such face — a missing bold is a styling miss, not a reason to fail.
    func addingMarkdownTrait(_ trait: MarkdownFontTrait) -> PlatformFont {
        #if canImport(AppKit)
        let symbolic: NSFontDescriptor.SymbolicTraits = trait == .bold ? .bold : .italic
        let descriptor = fontDescriptor.withSymbolicTraits(
            fontDescriptor.symbolicTraits.union(symbolic))
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
        #else
        let symbolic: UIFontDescriptor.SymbolicTraits = trait == .bold ? .traitBold : .traitItalic
        guard let descriptor = fontDescriptor.withSymbolicTraits(
            fontDescriptor.symbolicTraits.union(symbolic)) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
        #endif
    }
}

enum MarkdownFontTrait {
    case bold
    case italic
}

public extension PlatformColor {
    /// Bridges a SwiftUI `Color` into the platform type the text stack needs.
    static func from(_ color: Color) -> PlatformColor {
        PlatformColor(color)
    }

    /// The system's primary text color, under either kit's name for it.
    static var markdownLabel: PlatformColor {
        #if canImport(AppKit)
        NSColor.labelColor
        #else
        UIColor.label
        #endif
    }

    /// The system's de-emphasised text color.
    static var markdownSecondaryLabel: PlatformColor {
        #if canImport(AppKit)
        NSColor.secondaryLabelColor
        #else
        UIColor.secondaryLabel
        #endif
    }

    /// The faintest of the system's label colors, used as the inline-code fill.
    static var markdownQuaternaryLabel: PlatformColor {
        #if canImport(AppKit)
        NSColor.quaternaryLabelColor
        #else
        UIColor.quaternaryLabel
        #endif
    }

    /// The user's accent color where the platform exposes one, blue otherwise.
    static var markdownAccent: PlatformColor {
        #if canImport(AppKit)
        NSColor.controlAccentColor
        #else
        UIColor.tintColor
        #endif
    }
}
