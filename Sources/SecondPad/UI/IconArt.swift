import AppKit

/// The app icon, drawn in code: a dark landscape tablet showing the dashboard's cards, with the
/// lime focus accent. The same drawing makes the macOS iconset (`--make-iconset`), the
/// tablet's home-screen icons and the menu-bar glyph.
enum IconArt {

    static func image(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(in: rect)
            return true
        }
    }

    static func draw(in rect: NSRect) {
        let s = rect.width
        // Background squircle.
        let base = NSBezierPath(roundedRect: rect.insetBy(dx: s * 0.06, dy: s * 0.06), xRadius: s * 0.2, yRadius: s * 0.2)
        NSGradient(starting: NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.16, alpha: 1),
                   ending: NSColor(calibratedRed: 0.04, green: 0.05, blue: 0.06, alpha: 1))?.draw(in: base, angle: -90)

        // The tablet (landscape).
        let tablet = NSRect(x: s * 0.16, y: s * 0.27, width: s * 0.68, height: s * 0.46)
        let body = NSBezierPath(roundedRect: tablet, xRadius: s * 0.06, yRadius: s * 0.06)
        NSColor(calibratedWhite: 0.02, alpha: 1).setFill()
        body.fill()
        NSColor(calibratedWhite: 1, alpha: 0.22).setStroke()
        body.lineWidth = max(1, s * 0.012)
        body.stroke()

        // Its screen: three cards, one lime ring (the timer).
        let screen = tablet.insetBy(dx: s * 0.035, dy: s * 0.035)
        let gap = s * 0.018
        let card = NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.13, alpha: 1)
        let leftW = (screen.width - gap) * 0.58
        let left = NSRect(x: screen.minX, y: screen.minY, width: leftW, height: screen.height)
        let right = NSRect(x: left.maxX + gap, y: screen.minY, width: screen.width - leftW - gap, height: screen.height)
        let r = s * 0.025
        card.setFill()
        NSBezierPath(roundedRect: left, xRadius: r, yRadius: r).fill()
        let topRight = NSRect(x: right.minX, y: right.midY + gap / 2, width: right.width, height: right.height / 2 - gap / 2)
        let bottomRight = NSRect(x: right.minX, y: right.minY, width: right.width, height: right.height / 2 - gap / 2)
        NSBezierPath(roundedRect: topRight, xRadius: r, yRadius: r).fill()
        NSBezierPath(roundedRect: bottomRight, xRadius: r, yRadius: r).fill()

        // Session rows on the big card (yellow = working, blue = needs you).
        let dotR = s * 0.018
        let rows: [(NSColor, CGFloat)] = [(NSColor(calibratedRed: 1, green: 0.84, blue: 0.04, alpha: 1), 0.72),
                                          (NSColor(calibratedRed: 0.35, green: 0.78, blue: 0.98, alpha: 1), 0.45),
                                          (NSColor(calibratedWhite: 1, alpha: 0.25), 0.18)]
        for (color, y) in rows {
            let cy = left.minY + left.height * y
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: left.minX + s * 0.03, y: cy - dotR, width: dotR * 2, height: dotR * 2)).fill()
            NSColor(calibratedWhite: 1, alpha: 0.18).setFill()
            NSBezierPath(roundedRect: NSRect(x: left.minX + s * 0.075, y: cy - s * 0.008, width: left.width * 0.55, height: s * 0.016),
                         xRadius: s * 0.008, yRadius: s * 0.008).fill()
        }

        // The timer ring.
        let lime = NSColor(calibratedRed: 0.85, green: 1, blue: 0.36, alpha: 1)
        let center = NSPoint(x: topRight.midX, y: topRight.midY)
        let radius = min(topRight.width, topRight.height) * 0.3
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = s * 0.016
        NSColor(calibratedWhite: 1, alpha: 0.12).setStroke()
        track.stroke()
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: -160, clockwise: true)
        arc.lineWidth = s * 0.016
        arc.lineCapStyle = .round
        lime.setStroke()
        arc.stroke()

        // Pomodoro dots.
        for i in 0..<3 {
            let d = s * 0.026
            let x = bottomRight.minX + s * 0.025 + CGFloat(i) * (d + s * 0.012)
            (i < 2 ? lime : NSColor(calibratedWhite: 1, alpha: 0.15)).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: bottomRight.midY - d / 2, width: d, height: d)).fill()
        }
    }

    static func png(size: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// Writes AppIcon.iconset (build.sh calls `SecondPad --make-iconset <dir>`).
    static func writeIconset(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                guard let data = png(size: base * scale) else { continue }
                try data.write(to: directory.appendingPathComponent(name))
            }
        }
    }

    /// The menu-bar glyph: a small tablet outline (template image, follows the menu bar's colour).
    static func menuBarImage(linked: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 16), flipped: false) { _ in
            let outline = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 2.5, width: 17, height: 11), xRadius: 2.5, yRadius: 2.5)
            outline.lineWidth = 1.5
            NSColor.black.setStroke()
            outline.stroke()
            if linked {
                NSColor.black.setFill()
                NSBezierPath(roundedRect: NSRect(x: 4.5, y: 5.5, width: 6, height: 5), xRadius: 1, yRadius: 1).fill()
                NSBezierPath(roundedRect: NSRect(x: 12, y: 5.5, width: 3.5, height: 5), xRadius: 1, yRadius: 1).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// App icons for "Where attention went", drawn by macOS from the installed app. Only real bundle
/// ids of installed apps; anything else gets the tablet's letter badge.
enum AppIcons {
    private static var cache: [String: Data] = [:]

    static func png(bundleID: String) -> Data? {
        guard bundleID.count <= 200, !bundleID.hasPrefix("web."),
              bundleID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
        if let cached = cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        let size = 64
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        let data = rep.representation(using: .png, properties: [:])
        if let data { cache[bundleID] = data }
        return data
    }
}
