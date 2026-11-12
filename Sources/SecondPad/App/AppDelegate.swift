import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var model: AppModel!
    private var menuBar: MenuBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = ProcessInfo.processInfo.arguments
        model = AppModel(demo: arguments.contains("--demo"))
        menuBar = MenuBarController(model: model)
        model.start()
        // `--install-hooks` / `--remove-hooks`: the same code as the Settings buttons, from Terminal.
        if arguments.contains("--install-hooks") || arguments.contains("--remove-hooks") {
            if arguments.contains("--install-hooks") { model.installHooks() } else { model.removeHooks() }
            let state = model.hooks
            print(model.hookError.map { "Error: \($0)" }
                  ?? "Hooks \(state.hooks ? "installed" : "removed"); statusLine \(state.statusLine ? "SecondPad's" : state.foreignStatusLine ? "your own (kept)" : "none")")
            NSApp.terminate(nil)
            return
        }
        // Dev: draw the menu-bar window into a PNG without showing anything (screenshots, checks).
        if let i = arguments.firstIndex(of: "--render-popover"), i + 1 < arguments.count {
            let renderer = ImageRenderer(content: PopoverView(model: model, openSettings: {}, close: {}, snapshot: true))
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: arguments[i + 1]))
            }
            NSApp.terminate(nil)
            return
        }
        if arguments.contains("--open-settings") { menuBar.showSettings() }
        if arguments.contains("--open-popover") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.menuBar.showPopover() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }
}
