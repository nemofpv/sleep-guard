// How the menu looks: the badge icons and the status block at the top.
//
// The colours are taken from the app icon rather than from the system palette: the gold of the
// puppy stands for "awake", the night blue behind it for "sleep". Everything that keeps the Mac
// awake is gold, everything that lets it sleep is blue, and the rest stays grey.

import AppKit

enum BadgeStyle {
    case awake, sleep, neutral, alert

    var fill: NSColor {
        switch self {
        case .awake: return NSColor(srgbRed: 0.969, green: 0.765, blue: 0.294, alpha: 1)   // #F7C34B
        case .sleep:
            // #273A59 as in the icon; lifted in dark mode, where it would sink into the menu.
            return NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor(srgbRed: 0.290, green: 0.388, blue: 0.580, alpha: 1)
                    : NSColor(srgbRed: 0.153, green: 0.227, blue: 0.349, alpha: 1)
            }
        case .neutral: return .systemGray
        case .alert: return .systemRed
        }
    }

    /// The colour of the glyph on top of `fill`. Gold is too light to carry white.
    var ink: NSColor {
        self == .awake ? NSColor(srgbRed: 0.106, green: 0.153, blue: 0.251, alpha: 1) : .white
    }
}

enum Glyph {
    case symbol(String)   // an SF Symbol name
    case text(String)     // one or two characters, such as "2" or "+1"
}

/// A rounded square with a glyph on it, in the manner of the icons in System Settings.
/// Drawn on demand, so it follows the display scale and the light or dark appearance.
func badge(_ glyph: Glyph, _ style: BadgeStyle, side: CGFloat = 18) -> NSImage {
    NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
        style.fill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: side * 0.27, yRadius: side * 0.27).fill()

        let room = side * 0.72   // the glyph never comes closer to the edge than this allows
        func centred(_ size: NSSize) -> NSRect {
            let scale = min(1, room / max(size.width, size.height))
            let fitted = NSSize(width: size.width * scale, height: size.height * scale)
            return NSRect(x: (side - fitted.width) / 2, y: (side - fitted.height) / 2, width: fitted.width, height: fitted.height)
        }

        switch glyph {
        case .symbol(let name):
            let look = NSImage.SymbolConfiguration(pointSize: side * 0.58, weight: .semibold)
                .applying(.init(paletteColors: [style.ink]))
            // A name this macOS does not know leaves the badge blank, which is harmless.
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(look) {
                image.draw(in: centred(image.size))
            }
        case .text(let text):
            func rounded(_ size: CGFloat) -> NSFont {
                let base = NSFont.systemFont(ofSize: size, weight: .bold)
                return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
            }
            var font = rounded(side * 0.64)
            let natural = NSAttributedString(string: text, attributes: [.font: font]).size().width
            if natural > room { font = rounded(font.pointSize * room / natural) }
            let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: style.ink])
            // Centred on the cap height rather than on the line box, or digits sit visibly low.
            // draw(at:) takes the bottom of the line box: the baseline plus the (negative) descender.
            string.draw(at: NSPoint(x: (side - string.size().width) / 2, y: (side - font.capHeight) / 2 + font.descender))
        }
        return true
    }
}

/// The block at the top of the menu: a large badge, what the Mac is doing, and until when,
/// with `corner` (the version) in small print at the top right.
/// A view rather than a menu item, so it is neither dimmed like a disabled item nor
/// highlighted like one that can be clicked.
func statusHeader(glyph: Glyph, style: BadgeStyle, title: String, detail: String, corner: String) -> NSView {
    let icon = NSImageView(image: badge(glyph, style, side: 30))
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.widthAnchor.constraint(equalToConstant: 30).isActive = true
    icon.heightAnchor.constraint(equalToConstant: 30).isActive = true

    let titleLabel = NSTextField(labelWithString: title)
    titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
    let cornerLabel = NSTextField(labelWithString: corner)
    cornerLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    cornerLabel.textColor = .tertiaryLabelColor
    let detailLabel = NSTextField(labelWithString: detail)
    detailLabel.font = .systemFont(ofSize: 11)
    detailLabel.textColor = .secondaryLabelColor

    let text = NSStackView(views: [titleLabel, detailLabel])
    text.orientation = .vertical
    text.alignment = .leading
    text.spacing = 1

    let row = NSStackView(views: [icon, text])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 9
    row.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 16)
    // The menu sizes the block through its frame. A stack view made with init(views:) ignores
    // its frame in layout unless told otherwise, and would shrink back to the width of its content.
    row.translatesAutoresizingMaskIntoConstraints = true

    // The corner text is outside the stacks: on the title's line, at the right edge of the block
    // however wide the menu makes it, and never closer to the title than the last constraint allows.
    cornerLabel.translatesAutoresizingMaskIntoConstraints = false
    row.addSubview(cornerLabel)
    NSLayoutConstraint.activate([
        cornerLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
        cornerLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -row.edgeInsets.right),
        cornerLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 12),
    ])

    let size = row.fittingSize
    row.frame = NSRect(x: 0, y: 0, width: max(size.width, 230), height: size.height)
    row.autoresizingMask = [.width]
    return row
}
