import AppKit
import SwiftUI
import LiteMuxCore

/// Editor tab: a thin path bar plus the native text view.
struct EditorPane: View {
    @Bindable var document: EditorDocument
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: FileIcon.symbol(for: FileEntry(name: document.fileName, path: document.path, kind: .file)))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Text(model.host(document.hostID)?.title ?? "")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(document.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
                Spacer()
                if document.isSaving {
                    ProgressView().controlSize(.mini)
                } else if document.isDirty {
                    Text("未保存").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Button {
                    model.saveActiveEditor()
                } label: {
                    Text("保存 ⌘S").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!document.isDirty || document.isSaving)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Theme.chromeColor.opacity(0.6), ignoresSafeAreaEdges: [])
            .hairline(.bottom)

            CodeEditor(document: document, fontSize: CGFloat(model.state.fontSize))
        }
    }
}

/// NSTextView with a line-number gutter and lightweight syntax colouring.
struct CodeEditor: NSViewRepresentable {
    let document: EditorDocument
    let fontSize: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(document: document) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.canvas
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay

        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.drawsBackground = true
        tv.backgroundColor = Theme.canvas
        tv.insertionPointColor = Theme.caret
        tv.selectedTextAttributes = [.backgroundColor: Theme.selection]
        tv.textContainerInset = NSSize(width: 6, height: 8)
        // No soft wrapping: config files and logs read better unwrapped.
        tv.isHorizontallyResizable = true
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        context.coordinator.textView = tv
        context.coordinator.apply(fontSize: fontSize)
        tv.string = document.text
        context.coordinator.loadedRevision = document.revision
        context.coordinator.highlightAll()

        let ruler = LineNumberRuler(textView: tv)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true

        Task { @MainActor in tv.window?.makeFirstResponder(tv) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        if c.fontSize != fontSize { c.apply(fontSize: fontSize) }
        if c.loadedRevision != document.revision, let tv = c.textView {
            tv.string = document.text
            c.loadedRevision = document.revision
            c.highlightAll()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let document: EditorDocument
        weak var textView: NSTextView?
        var loadedRevision = -1
        var fontSize: CGFloat = 13
        private var highlighter: SyntaxHighlighter
        private var pending: Task<Void, Never>?

        init(document: EditorDocument) {
            self.document = document
            self.highlighter = SyntaxHighlighter(language: SyntaxHighlighter.Language(fileExtension: document.fileExtension,
                                                                                       fileName: document.fileName))
        }

        func apply(fontSize: CGFloat) {
            self.fontSize = fontSize
            guard let tv = textView else { return }
            let font = Theme.monoFont(fontSize)
            tv.font = font
            tv.typingAttributes = [.font: font, .foregroundColor: Theme.canvasText]
            let style = NSMutableParagraphStyle()
            style.lineHeightMultiple = 1.12
            tv.defaultParagraphStyle = style
            highlighter.font = font
            highlightAll()
            tv.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            document.text = tv.string
            pending?.cancel()
            pending = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled else { return }
                self?.highlightAll()
            }
            tv.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }

        func highlightAll() {
            guard let tv = textView, let storage = tv.textStorage else { return }
            highlighter.apply(to: storage)
        }
    }
}

/// Gutter with line numbers in tabular monospaced digits. Line starts are
/// cached so scrolling a 5 MB log stays cheap.
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    private var lineStarts: [Int] = [0]
    private var cacheValid = false

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
        NotificationCenter.default.addObserver(self, selector: #selector(refresh),
                                               name: NSView.boundsDidChangeNotification,
                                               object: textView.enclosingScrollView?.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(textChanged),
                                               name: NSText.didChangeNotification, object: textView)
        textView.enclosingScrollView?.contentView.postsBoundsChangedNotifications = true
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func refresh() { needsDisplay = true }
    @objc private func textChanged() { cacheValid = false; needsDisplay = true }

    private func rebuildCache(_ text: NSString) {
        var starts = [0]
        let length = text.length
        var i = 0
        while i < length {
            let r = text.lineRange(for: NSRange(location: i, length: 0))
            let next = NSMaxRange(r)
            if next <= i { break }
            if next < length || (next == length && r.length > 0 && Self.endsWithNewline(text, r)) { starts.append(next) }
            i = next
        }
        lineStarts = starts
        cacheValid = true
        let digits = max(3, String(starts.count).count)
        let wanted = CGFloat(digits) * 8 + 18
        if abs(wanted - ruleThickness) > 0.5 { ruleThickness = wanted }
    }

    private static func endsWithNewline(_ text: NSString, _ r: NSRange) -> Bool {
        let c = text.character(at: NSMaxRange(r) - 1)
        return c == 10 || c == 13
    }

    /// 1-based line number for a character offset.
    private func lineNumber(at offset: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo + 1
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        Theme.canvas.setFill()
        bounds.fill()
        let text = tv.string as NSString
        if !cacheValid { rebuildCache(text) }

        let font = NSFont.monospacedDigitSystemFont(ofSize: max(9, (tv.font?.pointSize ?? 13) - 2), weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
        let inset = tv.textContainerInset.height
        let originY = convert(NSPoint.zero, from: tv).y

        let glyphRange = lm.glyphRange(forBoundingRect: tv.visibleRect, in: tc)
        let charRange = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        var line = lineNumber(at: charRange.location)
        while line - 1 < lineStarts.count {
            let start = lineStarts[line - 1]
            if start > NSMaxRange(charRange) { break }
            var lineRect: NSRect
            if start >= text.length {
                lineRect = lm.extraLineFragmentRect
                if lineRect.isEmpty && text.length > 0 { break }
            } else {
                lineRect = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: start), effectiveRange: nil)
            }
            let label = "\(line)" as NSString
            let size = label.size(withAttributes: attrs)
            let y = originY + lineRect.minY + inset + (lineRect.height - size.height) / 2
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y), withAttributes: attrs)
            line += 1
        }
        Theme.hairline.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()
    }
}
