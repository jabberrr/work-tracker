import SwiftUI
import AppKit

extension Color {
    /// "#RRGGBB", "RRGGBB" or "#RRGGBBAA"; invalid → gray.
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var r: Double = 0.557, g: Double = 0.557, b: Double = 0.576, a: Double = 1   // #8E8E93
        if (s.count == 6 || s.count == 8), s.allSatisfy({ $0.isHexDigit }), let value = UInt64(s, radix: 16) {
            if s.count == 6 {
                r = Double((value >> 16) & 0xFF) / 255
                g = Double((value >> 8) & 0xFF) / 255
                b = Double(value & 0xFF) / 255
            } else {
                r = Double((value >> 24) & 0xFF) / 255
                g = Double((value >> 16) & 0xFF) / 255
                b = Double((value >> 8) & 0xFF) / 255
                a = Double(value & 0xFF) / 255
            }
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    /// sRGB "#RRGGBB" (via NSColor).
    var hexString: String {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return "#8E8E93" }
        func byte(_ v: CGFloat) -> Int { min(255, max(0, Int((v * 255).rounded()))) }
        return String(format: "#%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }
}

/// (Extra) A named palette entry.
struct LabelSwatch: Hashable, Identifiable {
    let name: String
    let hex: String
    var id: String { hex }
}

enum LabelPalette {
    /// (Extra) Curated label/tag colors with names (used for accessibility labels and tooltips).
    /// Mid-chroma so they read on light and dark surfaces alike; includes every seeded color.
    static let swatches: [LabelSwatch] = [
        LabelSwatch(name: "Blue", hex: "#5B8DEF"),
        LabelSwatch(name: "Sky", hex: "#4AA3DF"),
        LabelSwatch(name: "Teal", hex: "#2F9E9A"),
        LabelSwatch(name: "Green", hex: "#27AE60"),
        LabelSwatch(name: "Olive", hex: "#8AA34A"),
        LabelSwatch(name: "Mustard", hex: "#D4A72C"),
        LabelSwatch(name: "Orange", hex: "#F2994A"),
        LabelSwatch(name: "Red", hex: "#D9534F"),
        LabelSwatch(name: "Pink", hex: "#D45D8C"),
        LabelSwatch(name: "Purple", hex: "#9B51E0"),
        LabelSwatch(name: "Indigo", hex: "#6E6ACF"),
        LabelSwatch(name: "Brown", hex: "#8D6E63"),
        LabelSwatch(name: "Slate", hex: "#607D8B"),
        LabelSwatch(name: "Gray", hex: "#9B9B9B"),
        LabelSwatch(name: "Neutral", hex: "#8E8E93")
    ]

    /// ≥ 12 curated label/tag colors ("#RRGGBB").
    static let hexColors: [String] = swatches.map { $0.hex }

    /// ≥ 30 curated SF Symbols for labels (all available on macOS 14).
    static let symbols: [String] = [
        "circle.fill", "brain.head.profile", "person.2.fill", "tray.full.fill", "book.fill",
        "list.bullet.clipboard", "hammer.fill", "wrench.and.screwdriver.fill",
        "chevron.left.forwardslash.chevron.right", "terminal.fill", "cpu", "server.rack", "ant.fill",
        "doc.text.fill", "pencil", "paintbrush.pointed.fill", "paintpalette.fill", "lightbulb.fill",
        "magnifyingglass", "chart.bar.fill", "chart.line.uptrend.xyaxis", "envelope.fill", "phone.fill",
        "bubble.left.and.bubble.right.fill", "video.fill", "calendar", "checklist", "flag.fill",
        "target", "star.fill", "bolt.fill", "leaf.fill", "graduationcap.fill", "text.book.closed.fill",
        "building.2.fill", "briefcase.fill", "dollarsign.circle.fill", "cart.fill", "shippingbox.fill",
        "gearshape.fill", "puzzlepiece.fill", "testtube.2", "globe", "house.fill", "figure.walk",
        "heart.fill", "cup.and.saucer.fill", "music.note", "headphones", "camera.fill", "airplane",
        "folder.fill"
    ]

    /// (Extra) Name for a palette color ("Blue"), or nil for a custom color.
    static func name(forHex hex: String) -> String? {
        let key = normalized(hex)
        return swatches.first { normalized($0.hex) == key }?.name
    }

    /// (Extra) Uppercased "#RRGGBB" form for comparisons.
    static func normalized(_ hex: String) -> String {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !s.hasPrefix("#") { s = "#" + s }
        if s.count == 9 { s = String(s.prefix(7)) }   // drop alpha
        return s
    }

    /// (Extra) Human-readable name for an SF Symbol ("person.2.fill" → "person 2").
    static func accessibilityName(forSymbol symbol: String) -> String {
        symbol
            .replacingOccurrences(of: ".fill", with: "")
            .replacingOccurrences(of: ".", with: " ")
    }
}
