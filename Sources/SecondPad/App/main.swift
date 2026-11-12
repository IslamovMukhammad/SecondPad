import AppKit

let arguments = ProcessInfo.processInfo.arguments

// build.sh: draw the icon into an iconset and exit.
if let index = arguments.firstIndex(of: "--make-iconset"), index + 1 < arguments.count {
    do {
        try IconArt.writeIconset(to: URL(fileURLWithPath: arguments[index + 1]))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("make-iconset: \(error)\n".utf8))
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Menu-bar only: no Dock icon (LSUIElement in Info.plist does the same for the built app).
app.setActivationPolicy(.accessory)
app.run()
