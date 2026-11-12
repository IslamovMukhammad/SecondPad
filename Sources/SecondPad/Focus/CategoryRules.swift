import Foundation

/// What kind of time an app (or a site in Chrome) is, during a Pomodoro focus period.
nonisolated enum ActivityCategory: String, Codable, CaseIterable, Sendable {
    case code, claude, planning, learning, video, chat, social, music, reading, other, afk

    /// Counts toward purity.
    static let onTask: Set<ActivityCategory> = [.code, .claude, .planning, .learning]
    /// Breaks focus. Reading and away are neutral: they don't break focus, they don't count either.
    static let distraction: Set<ActivityCategory> = [.chat, .social, .video, .music, .other]

    /// The colour of a distraction's letter badge on the tablet.
    var colorHex: String {
        switch self {
        case .code: "#30d158"
        case .claude: "#ffd60a"
        case .planning: "#7d7aff"
        case .learning: "#5ac8fa"
        case .video: "#bf5af2"
        case .chat: "#ff9f0a"
        case .social: "#ff375f"
        case .music: "#64d2ff"
        case .reading: "#8e8e93"
        case .other: "#6e6e73"
        case .afk: "#3a3a3c"
        }
    }
}

/// A site in Chrome that is treated as its own "app".
nonisolated struct WebPlatform: Equatable, Sendable {
    let id: String
    let name: String
    let category: ActivityCategory
}

/// Fixed rules, by bundle id (names change with the language, ids don't) and by domain.
nonisolated enum CategoryRules {

    static let appRules: [String: ActivityCategory] = [
        "com.microsoft.VSCode": .code,
        "com.apple.dt.Xcode": .code,
        "com.apple.Terminal": .code,
        "com.googlecode.iterm2": .code,
        "com.mitchellh.ghostty": .code,
        "dev.warp.Warp-Stable": .code,
        "com.todesktop.230313mzl4w4u92": .code,   // Cursor
        "com.sublimetext.4": .code,
        "com.jetbrains.intellij": .code,
        "com.anthropic.claudefordesktop": .claude,
        "ru.keepcoder.Telegram": .chat,
        "com.tdesktop.Telegram": .chat,
        "com.tinyspeck.slackmacgap": .chat,
        "com.apple.MobileSMS": .chat,
        "com.apple.mail": .chat,
        "net.whatsapp.WhatsApp": .chat,
        "com.hnc.Discord": .chat,
        "com.spotify.client": .music,
        "com.apple.Music": .music,
        "com.apple.TV": .video,
        "com.apple.Preview": .reading,
        "notion.id": .reading,
        "md.obsidian": .reading,
        "com.apple.Notes": .planning,
        "com.apple.reminders": .planning,
        "com.apple.iCal": .planning,
    ]

    /// Only Chrome's tab is read (AppleScript, domain only, never in incognito).
    static let browserBundleIDs: Set<String> = ["com.google.Chrome"]

    static let platforms: [(suffix: String, platform: WebPlatform)] = [
        ("youtube.com", WebPlatform(id: "web.youtube", name: "YouTube", category: .video)),
        ("youtu.be", WebPlatform(id: "web.youtube", name: "YouTube", category: .video)),
        ("instagram.com", WebPlatform(id: "web.instagram", name: "Instagram", category: .social)),
        ("github.com", WebPlatform(id: "web.github", name: "GitHub", category: .code)),
        ("facebook.com", WebPlatform(id: "web.facebook", name: "Facebook", category: .social)),
        ("x.com", WebPlatform(id: "web.x", name: "X", category: .social)),
        ("twitter.com", WebPlatform(id: "web.x", name: "X", category: .social)),
        ("tiktok.com", WebPlatform(id: "web.tiktok", name: "TikTok", category: .social)),
        ("reddit.com", WebPlatform(id: "web.reddit", name: "Reddit", category: .social)),
        ("web.telegram.org", WebPlatform(id: "web.telegram", name: "Telegram Web", category: .chat)),
        ("web.whatsapp.com", WebPlatform(id: "web.whatsapp", name: "WhatsApp Web", category: .chat)),
        ("discord.com", WebPlatform(id: "web.discord", name: "Discord", category: .chat)),
        ("netflix.com", WebPlatform(id: "web.netflix", name: "Netflix", category: .video)),
        ("twitch.tv", WebPlatform(id: "web.twitch", name: "Twitch", category: .video)),
        ("claude.ai", WebPlatform(id: "web.claude", name: "Claude", category: .claude)),
    ]

    static func category(bundleID: String?) -> ActivityCategory {
        guard let bundleID else { return .other }
        return appRules[bundleID] ?? .other
    }

    static func platform(domain: String) -> WebPlatform? {
        let host = domain.lowercased()
        return platforms.first { host == $0.suffix || host.hasSuffix("." + $0.suffix) }?.platform
    }

    /// A page in Chrome. Unknown sites count as reading (neutral); no domain (no permission yet,
    /// incognito) counts as "other".
    static func category(domain: String?) -> ActivityCategory {
        guard let domain else { return .other }
        if let platform = platform(domain: domain) { return platform.category }
        if domain.hasSuffix("anthropic.com") { return .claude }
        if domain.hasSuffix("slack.com") { return .chat }
        if domain.hasSuffix("vimeo.com") { return .video }
        return .reading
    }

    /// Reading gets a longer idle allowance (10 min) before it counts as away.
    static func isReadingContext(isBrowser: Bool, bundleID: String?, domain: String?) -> Bool {
        if isBrowser {
            let category = category(domain: domain)
            return category == .reading || category == .code
        }
        return category(bundleID: bundleID) == .reading
    }

    /// "https://www.youtube.com/watch?v=…" → "youtube.com"
    static func domain(fromURL text: String) -> String? {
        guard let url = URL(string: text), var host = url.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host.isEmpty ? nil : host
    }

    /// The away rule while a focus period runs.
    static func isAway(locked: Bool, idle: TimeInterval, mediaActive: Bool, claudeWorking: Bool,
                       readingContext: Bool) -> Bool {
        if locked { return true }
        if idle < 120 { return false }
        if mediaActive { return false }
        if claudeWorking, idle < 300 { return false }
        if readingContext, idle < 600 { return false }
        return true
    }
}
