import AppKit

final class MenuBarStatusItemView: NSControl {
    var lines: [MenuBarStatusLine] = [] {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    override var isHighlighted: Bool {
        didSet {
            updateColors()
            needsDisplay = true
        }
    }

    var preferredWidth: CGFloat {
        let visibleLines = visibleLines
        return ceil(
            Self.horizontalPadding * 2
                + Self.iconSize
                + Self.iconCodeSpacing
                + codeColumnWidth(for: visibleLines)
                + Self.columnSpacing
                + valueColumnWidth(for: visibleLines)
        )
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: preferredWidth, height: NSStatusBar.system.thickness)
    }

    override var isFlipped: Bool { true }

    private static let lineFont = NSFont.systemFont(ofSize: 10.0, weight: .regular)
    private static let horizontalPadding: CGFloat = 5
    private static let iconSize: CGFloat = 8
    private static let iconCodeSpacing: CGFloat = 3
    private static let columnSpacing: CGFloat = 6
    private static let rowGap: CGFloat = 1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    override func draw(_ dirtyRect: NSRect) {
        let textColor: NSColor
        if isHighlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(
                roundedRect: bounds.insetBy(dx: 1, dy: 2),
                xRadius: 4,
                yRadius: 4
            ).fill()
            textColor = .selectedMenuItemTextColor
        } else {
            textColor = .labelColor
        }

        drawLines(color: textColor)
    }

    override func mouseDown(with event: NSEvent) {
        sendAction(action, to: target)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    private func setupView() {
        wantsLayer = true
    }

    private func updateColors() {
        needsDisplay = true
    }

    private var visibleLines: [MenuBarStatusLine] {
        lines.isEmpty
            ? [MenuBarStatusLine(symbolName: "chart.bar.fill", name: "AI", code: "AI", value: "--")]
            : lines
    }

    private func drawLines(color: NSColor) {
        let visibleLines = visibleLines.prefix(2)
        let allLines = Array(visibleLines)
        let codeWidth = codeColumnWidth(for: allLines)
        let valueWidth = valueColumnWidth(for: allLines)
        let contentWidth = Self.iconSize + Self.iconCodeSpacing + codeWidth + Self.columnSpacing + valueWidth
        let lineHeight = ceil(Self.lineFont.ascender - Self.lineFont.descender)
        let totalHeight = lineHeight * CGFloat(allLines.count) + Self.rowGap * CGFloat(max(allLines.count - 1, 0))
        let startX = floor((bounds.width - contentWidth) / 2)
        let startY = floor((bounds.height - totalHeight) / 2)

        for (index, line) in allLines.enumerated() {
            let y = startY + CGFloat(index) * (lineHeight + Self.rowGap)
            let iconY = y + floor((lineHeight - Self.iconSize) / 2)
            drawIcon(line.symbolName, in: NSRect(x: startX, y: iconY, width: Self.iconSize, height: Self.iconSize), color: color)
            drawText(
                line.code,
                in: NSRect(x: startX + Self.iconSize + Self.iconCodeSpacing, y: y, width: codeWidth, height: lineHeight),
                alignment: .left,
                color: color
            )
            drawText(
                line.value,
                in: NSRect(
                    x: startX + Self.iconSize + Self.iconCodeSpacing + codeWidth + Self.columnSpacing,
                    y: y,
                    width: valueWidth,
                    height: lineHeight
                ),
                alignment: .right,
                color: color
            )
        }
    }

    private func drawText(_ text: String, in rect: NSRect, alignment: NSTextAlignment, color: NSColor) {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byClipping

        (text as NSString).draw(
            in: rect,
            withAttributes: [
                .font: Self.lineFont,
                .foregroundColor: color,
                .paragraphStyle: style
            ]
        )
    }

    private func drawIcon(_ symbolName: String, in rect: NSRect, color: NSColor) {
        guard let image = symbolImage(named: symbolName) else { return }
        image.drawTinted(in: rect, color: color)
    }

    private func codeColumnWidth(for lines: [MenuBarStatusLine]) -> CGFloat {
        ceil(lines.map { textWidth($0.code) }.max() ?? textWidth("AI"))
    }

    private func valueColumnWidth(for lines: [MenuBarStatusLine]) -> CGFloat {
        ceil(lines.map { textWidth($0.value) }.max() ?? textWidth("--"))
    }

    private func textWidth(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: Self.lineFont]).width
    }

    private func symbolImage(named name: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: Self.iconSize, weight: .regular)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = true
        return image
    }
}

private extension NSImage {
    func drawTinted(in rect: NSRect, color: NSColor) {
        guard let copy = copy() as? NSImage else { return }
        copy.lockFocus()
        color.set()
        NSRect(origin: .zero, size: copy.size).fill(using: .sourceAtop)
        copy.unlockFocus()
        copy.draw(in: rect)
    }
}
