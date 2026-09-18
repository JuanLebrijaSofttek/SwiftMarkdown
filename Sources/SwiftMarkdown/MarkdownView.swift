//
//  MarkdownView.swift
//  SwiftMarkdown
//
//  Renders one Markdown document. Prose, headings, lists and quotes share a single
//  text view, so a drag selects across all of them in one gesture — per-block SwiftUI
//  views each own their own selection scope, which is why selection stops at every
//  boundary when they are used instead. Code blocks and tables are the exceptions:
//  both scroll horizontally, which one shared text container cannot express.
//

import SwiftUI

// MARK: - Frame-rate throttle

/// Coalesces streaming deltas to one render per frame. Without it a fast model
/// turn re-parses the whole message on every token append.
final class PrecisionTimer60FPS: @unchecked Sendable {
    private var timer: DispatchSourceTimer?
    private let callback: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.swiftmarkdown.fps60timer", qos: .userInteractive)
    private var isProcessing = false

    init(callback: @escaping @Sendable () -> Void) {
        self.callback = callback
    }

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(16_666_666), leeway: .nanoseconds(0))
        timer.setEventHandler { [weak self] in
            guard let self, !self.isProcessing else { return }
            self.isProcessing = true
            DispatchQueue.main.async {
                self.callback()
                self.isProcessing = false
            }
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        isProcessing = false
    }

    deinit { stop() }
}

// MARK: - Render coordinator

@MainActor
@Observable
public final class MarkdownRenderCoordinator {

    public private(set) var segments: [MarkdownSegment] = []

    private var timer: PrecisionTimer60FPS?
    private var pendingText: String?
    private var renderedText: String?
    private var renderedStyleKey: String?
    private var currentStyle: MarkdownStyle?

    /// The last parse and the last split, each kept so the next delta can pick up where
    /// they left off rather than re-reading and re-rendering the whole message. Both
    /// verify for themselves that they still apply, so a wholly different message or a
    /// theme change simply falls back to doing the work.
    private var document: MarkdownDocument?
    private var segmentSet: MarkdownSegmentSet?
    /// Frames observed with nothing pending; the timer stops once the stream goes quiet.
    private var idleFrames = 0

    public init() {}

    /// Queues a render. Style changes (theme or appearance) bypass the throttle so the
    /// message never sits in stale colors.
    public func update(text: String, style: MarkdownStyle) {
        let styleKey = Self.key(for: style)
        if styleKey != renderedStyleKey {
            renderedStyleKey = styleKey
            renderNow(text: text, style: style)
            return
        }
        guard text != renderedText else { return }
        pendingText = text
        currentStyle = style
        if timer == nil {
            timer = PrecisionTimer60FPS { [weak self] in
                Task { @MainActor in self?.tick() }
            }
            timer?.start()
        }
    }

    private func tick() {
        guard let pending = pendingText, let style = currentStyle else {
            idleFrames += 1
            // ~1s of quiet: the turn is over, stop burning a timer per message.
            if idleFrames > 60 { stop() }
            return
        }
        idleFrames = 0
        pendingText = nil
        renderNow(text: pending, style: style)
    }

    private func renderNow(text: String, style: MarkdownStyle) {
        renderedText = text
        currentStyle = style
        let parsed = MarkdownBlockParser.parse(text, reusing: document)
        let split = MarkdownSegment.split(parsed, style: style, reusing: segmentSet)
        document = parsed
        segmentSet = split
        segments = split.segments
    }

    public func stop() {
        timer?.stop()
        timer = nil
        pendingText = nil
        idleFrames = 0
    }

    static func key(for style: MarkdownStyle) -> String {
        MarkdownStyle.key(for: style)
    }
}

// MARK: - View

public struct MarkdownView: View {

    /// Either text this view renders and re-renders itself, or segments somebody else
    /// already rendered. The second is the cheap one, and the only one that stays cheap
    /// in a lazy stack — see ``MarkdownSegment/render(_:style:)``.
    private enum Source {
        case text(String)
        case segments([MarkdownSegment])
    }

    private let source: Source

    /// Set to override the system-derived styling. Left `nil`, the view follows
    /// the ambient color scheme on its own.
    public let customStyle: MarkdownStyle?

    @Environment(\.colorScheme) private var colorScheme

    @State private var coordinator = MarkdownRenderCoordinator()

    /// See ``lazySegments(_:)``. Off by default, and deliberately so.
    private var isLazy = false

    /// Renders `text`, re-rendering as it changes. Use this for a message that is
    /// still arriving.
    public init(text: String, style: MarkdownStyle? = nil) {
        self.source = .text(text)
        self.customStyle = style
    }

    /// Displays segments rendered elsewhere, doing no parsing of its own.
    ///
    /// For a transcript: render each finished message once where it is owned — off the
    /// main actor if you like — and keep the segments. A lazy stack can then build and
    /// discard rows as often as it wants without re-parsing anything.
    ///
    /// The segments must have been rendered with the same `style` passed here, or the
    /// text will be laid out in one style and decorated in another.
    public init(segments: [MarkdownSegment], style: MarkdownStyle? = nil) {
        self.source = .segments(segments)
        self.customStyle = style
    }

    private var segments: [MarkdownSegment] {
        switch source {
        case .text: return coordinator.segments
        case .segments(let segments): return segments
        }
    }

    /// Nil for the pre-rendered case, which has nothing to react to.
    private var text: String? {
        if case .text(let text) = source { return text }
        return nil
    }

    private var style: MarkdownStyle {
        customStyle ?? MarkdownStyle.standard(appearanceIsDark: colorScheme == .dark)
    }

    /// Builds each segment's view only as it nears the viewport, rather than all of
    /// them when the message appears.
    ///
    /// Worth it for a message with many code blocks — each is a view with its own text
    /// stack, and each runs its highlighter on creation, so twenty realised in one
    /// frame is a stall. Not the default, because a `LazyVStack` has no intrinsic
    /// height: it reports what it has built so far, which outside a vertical
    /// `ScrollView` is nothing. Turn it on only where this view sits inside one.
    public func lazySegments(_ enabled: Bool = true) -> MarkdownView {
        var copy = self
        copy.isLazy = enabled
        return copy
    }

    @ViewBuilder
    private var segmentViews: some View {
        ForEach(segments) { segment in
            switch segment {
            case .prose(_, let attributed):
                MarkdownTextViewRepresentable(attributed: attributed, style: style)
                    .frame(maxWidth: .infinity, alignment: .topLeading)

            case .code(_, let language, let code):
                MarkdownCodeBlockViewHighlighted(language: language, code: code)

            case .table(_, let table):
                MarkdownTableView(table: table, style: style)
            }
        }
    }

    public var body: some View {
        Group {
            if isLazy {
                LazyVStack(alignment: .leading, spacing: 2) { segmentViews }
            } else {
                VStack(alignment: .leading, spacing: 2) { segmentViews }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear { render() }
        .onChange(of: text) { _, _ in render() }
        .onChange(of: colorScheme) { _, _ in render() }
        .onDisappear { coordinator.stop() }
    }

    private func render() {
        guard let text else { return }
        coordinator.update(text: text, style: style)
    }
}
