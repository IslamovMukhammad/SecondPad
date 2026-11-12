import AppKit

/// Icons for the sites the focus tracker knows ("web.youtube" → youtube.com), fetched at run
/// time from the site itself (never bundled), re-drawn by the Mac into a small PNG and kept in
/// memory. Only the fixed list of sites in `CategoryRules.platforms`, only https.
final class SiteIcons {

    private var cache: [String: Data] = [:]
    private var failedAt: [String: Date] = [:]
    var fetch: @Sendable (URL) async -> Data? = { url in
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count < 512_000 else { return nil }
        return data
    }

    /// The site's host for a platform id, or nil for anything not on the list.
    nonisolated static func host(for id: String) -> String? {
        CategoryRules.platforms.first { $0.platform.id == id }?.suffix
    }

    /// Where to look, best first.
    nonisolated static func candidates(host: String) -> [URL] {
        ["https://\(host)/apple-touch-icon.png", "https://www.\(host)/apple-touch-icon.png",
         "https://\(host)/favicon.ico", "https://www.\(host)/favicon.ico"].compactMap(URL.init(string:))
    }

    func png(for id: String) async -> Data? {
        if let cached = cache[id] { return cached }
        if let failed = failedAt[id], Date().timeIntervalSince(failed) < 3600 { return nil }
        guard let host = Self.host(for: id) else { return nil }
        for url in Self.candidates(host: host) {
            if let data = await fetch(url), let png = Self.redraw(data) {
                cache[id] = png
                return png
            }
        }
        failedAt[id] = Date()
        return nil
    }

    /// Whatever image format came back (PNG, ICO, …) is drawn into a fresh 64 × 64 PNG, so the
    /// tablet only ever gets a plain PNG made by the Mac.
    nonisolated static func redraw(_ data: Data) -> Data? {
        guard let image = NSImage(data: data), image.size.width >= 8, image.size.height >= 8 else { return nil }
        let size = 64
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
