import AppKit
import SwiftUI

/// The end-of-period question on the Mac, the same one the tablet asks. Whichever answers first
/// wins; the other side closes.
final class PromptPanel {

    private let answer: (Bool) -> Void
    private var panel: NSPanel?

    init(answer: @escaping (Bool) -> Void) {
        self.answer = answer
    }

    static func question(_ prompt: PomodoroTimer.Prompt) -> String {
        switch prompt {
        case .startBreak: "Focus done · take a break?"
        case .startLongBreak: "4 in a row · long break?"
        case .startFocus: "Break's over · focus again?"
        }
    }

    static func labels(_ prompt: PomodoroTimer.Prompt) -> (yes: String, no: String) {
        switch prompt {
        case .startBreak, .startLongBreak: ("Start Break", "Skip")
        case .startFocus: ("Start Focus", "Not Now")
        }
    }

    func show(_ prompt: PomodoroTimer.Prompt?) {
        panel?.orderOut(nil)
        panel = nil
        guard let prompt else { return }
        let view = PromptView(question: Self.question(prompt), labels: Self.labels(prompt)) { [weak self] yes in
            self?.panel?.orderOut(nil)
            self?.panel = nil
            self?.answer(yes)
        }
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 340, height: 108)
        let panel = NSPanel(contentRect: host.frame, styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = host
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - 340 - 16, y: frame.maxY - 108 - 12))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }
}

private struct PromptView: View {
    let question: String
    let labels: (yes: String, no: String)
    let answer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pomodoro").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(question).font(.headline)
            HStack {
                Button(labels.no) { answer(false) }
                Spacer()
                Button(labels.yes) { answer(true) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 340, height: 108)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
