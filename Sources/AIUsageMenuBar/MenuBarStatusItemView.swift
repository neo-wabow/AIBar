import AppKit

final class MenuBarStatusItemView: NSControl {
    var lines: [MenuBarStatusLine] = [] {
        didSet {
            rebuildRows()
            invalidateIntrinsicContentSize()
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
        return ceil(Self.horizontalPadding * 2 + nameColumnWidth(for: visibleLines) + Self.columnSpacing + valueColumnWidth(for: visibleLines))
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: preferredWidth, height: NSStatusBar.system.thickness)
    }

    private static let lineFont = NSFont.systemFont(ofSize: 10.5, weight: .regular)
    private static let horizontalPadding: CGFloat = 5
    private static let columnSpacing: CGFloat = 6

    private let rowsStack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
        rebuildRows()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
        rebuildRows()
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHighlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(
                roundedRect: bounds.insetBy(dx: 1, dy: 2),
                xRadius: 4,
                yRadius: 4
            ).fill()
        }

        super.draw(dirtyRect)
    }

    override func mouseDown(with event: NSEvent) {
        sendAction(action, to: target)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    private func setupView() {
        wantsLayer = true

        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = -5
        rowsStack.distribution = .gravityAreas

        addSubview(rowsStack)

        NSLayoutConstraint.activate([
            rowsStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalPadding),
            rowsStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalPadding)
        ])

        updateColors()
    }

    private func rebuildRows() {
        rowsStack.arrangedSubviews.forEach { view in
            rowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let visibleLines = visibleLines
        let nameWidth = nameColumnWidth(for: visibleLines)
        let valueWidth = valueColumnWidth(for: visibleLines)

        for line in visibleLines {
            rowsStack.addArrangedSubview(makeRow(for: line, nameWidth: nameWidth, valueWidth: valueWidth))
        }

        updateColors()
    }

    private func makeRow(for line: MenuBarStatusLine, nameWidth: CGFloat, valueWidth: CGFloat) -> NSStackView {
        let nameLabel = makeLabel(line.name, alignment: .left)
        let valueLabel = makeLabel(line.value, alignment: .right)

        let row = NSStackView(views: [nameLabel, valueLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Self.columnSpacing

        NSLayoutConstraint.activate([
            nameLabel.widthAnchor.constraint(equalToConstant: nameWidth),
            valueLabel.widthAnchor.constraint(equalToConstant: valueWidth)
        ])

        return row
    }

    private func updateColors() {
        let color: NSColor = isHighlighted ? .selectedMenuItemTextColor : .labelColor
        rowsStack.arrangedSubviews.forEach { row in
            row.subviews.forEach { view in
                if let label = view as? NSTextField {
                    label.textColor = color
                }
            }
        }
    }

    private var visibleLines: [MenuBarStatusLine] {
        lines.isEmpty
            ? [MenuBarStatusLine(symbolName: "chart.bar.fill", name: "AI", value: "--")]
            : lines
    }

    private func makeLabel(_ text: String, alignment: NSTextAlignment) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = Self.lineFont
        label.alignment = alignment
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        label.allowsDefaultTighteningForTruncation = true
        return label
    }

    private func nameColumnWidth(for lines: [MenuBarStatusLine]) -> CGFloat {
        ceil(lines.map { textWidth($0.name) }.max() ?? textWidth("AI"))
    }

    private func valueColumnWidth(for lines: [MenuBarStatusLine]) -> CGFloat {
        ceil(lines.map { textWidth($0.value) }.max() ?? textWidth("--"))
    }

    private func textWidth(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: Self.lineFont]).width
    }
}
