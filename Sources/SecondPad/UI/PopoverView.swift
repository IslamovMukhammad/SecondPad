import SwiftUI

/// The menu-bar window: add a task, run the Pomodoro and the Quick timer. The task LIST lives on
/// the tablet; here you only create tasks (Return adds one and keeps the field ready for the next).
struct PopoverView: View {
    let model: AppModel
    let openSettings: () -> Void
    let close: () -> Void
    /// Drawn offscreen for a screenshot: the text field is shown as its placeholder.
    var snapshot = false

    @State private var draft = ""
    @State private var added: String?
    @State private var addedTick = 0
    @State private var pomodoroSettings = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 14) {
                header
                taskField
                pomodoroCard
                timerCard
                if model.weather.place == nil && !model.isDemo { weatherHint }
                footer
            }
            .padding(16)
            .frame(width: 340)
        }
        // A solid surface, like the dashboard: the translucent default let the desktop show through.
        .background(Color(red: 0.086, green: 0.09, blue: 0.105))
        .environment(\.colorScheme, .dark)
        .onAppear { fieldFocused = true }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: IconArt.image(size: 30))
                .resizable().frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("SecondPad").font(.system(size: 15, weight: .semibold))
                HStack(spacing: 5) {
                    Circle().fill(linkColor).frame(width: 7, height: 7)
                    Text(linkText).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            IconButton(symbol: "gearshape", help: "Settings") { close(); openSettings() }
        }
    }

    private var linkText: String {
        if model.isDemo { return "Demo mode" }
        switch model.link.status {
        case .noADB: return "adb not found"
        case .noDevice: return model.web.viewerCount > 0 ? "Open in a browser" : "No tablet connected"
        case .linked: return model.web.viewerCount > 0 ? "Tablet connected" : "Tablet plugged in · page not open"
        }
    }

    private var linkColor: Color {
        if model.web.viewerCount > 0 { return .green }
        if case .linked = model.link.status { return .orange }
        return .secondary.opacity(0.6)
    }

    // MARK: - New task

    private var taskField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 17)).foregroundStyle(Color.accentColor)
                if snapshot {
                    Text("New task for today").font(.system(size: 14)).foregroundStyle(.secondary)
                    Spacer()
                } else {
                    TextField("New task for today", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .focused($fieldFocused)
                        .onSubmit(add)
                }
                if !draft.isEmpty {
                    Text("↩").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12).frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(fieldFocused ? Color.accentColor.opacity(0.6) : .primary.opacity(0.1)))
            Group {
                if let added {
                    Label("Added “\(added)”", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .id(addedTick)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    Text(openCountText).foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11)).lineLimit(1).padding(.leading, 4)
        }
    }

    private var openCountText: String {
        let open = model.tasks.today.filter { !$0.done }.count
        return open == 0 ? "Ticked on the tablet · nothing open today" : open == 1 ? "1 open today · tick it on the tablet" : "\(open) open today · tick them on the tablet"
    }

    private func add() {
        guard let task = model.tasks.add(draft) else { return }
        draft = ""
        let short = task.text.count > 34 ? String(task.text.prefix(34)) + "…" : task.text
        withAnimation(.easeOut(duration: 0.18)) { added = short; addedTick += 1 }
        let tick = addedTick
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            if addedTick == tick { withAnimation(.easeOut(duration: 0.2)) { added = nil } }
        }
    }

    // MARK: - Pomodoro

    private var pomodoroCard: some View {
        let p = model.pomodoro
        let m = p.message
        return Card {
            HStack(alignment: .firstTextBaseline) {
                Label("Pomodoro", systemImage: "timer").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(pomodoroState(p)).font(.system(size: 12, weight: .semibold)).foregroundStyle(pomodoroTint(p))
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { pomodoroSettings.toggle() }
                } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 22)
                        .background(Capsule().fill(Color.white.opacity(pomodoroSettings ? 0.16 : 0.07)))
                }
                .buttonStyle(PressStyle()).help("Pomodoro settings")
            }
            if pomodoroSettings { pomodoroSettingsRows(p) }
            HStack(alignment: .center) {
                Text(clock(p.prompt == nil ? m.remaining : (p.prompt == .startFocus ? p.focusDuration : m.total)))
                    .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(p.phase == .idle || p.prompt != nil ? .secondary : .primary)
                Spacer()
                if let prompt = p.prompt {
                    let labels = PromptPanel.labels(prompt)
                    PillButton(title: labels.no, style: .plain) { p.answer(false) }
                    PillButton(title: labels.yes, style: .filled) { p.answer(true) }
                } else {
                    if p.phase != .idle { IconButton(symbol: "arrow.counterclockwise", help: "Reset") { p.reset() } }
                    PillButton(title: p.running ? "Pause" : (p.phase == .idle ? "Start" : "Resume"), style: .filled) { p.toggle() }
                }
            }
            HStack(spacing: 5) {
                ForEach(0..<PomodoroTimer.longBreakEvery, id: \.self) { i in
                    Capsule().fill(i < m.completedSinceLongBreak ? Color.green : .primary.opacity(0.12)).frame(width: 18, height: 4)
                }
                Spacer()
                Text(m.completed == 1 ? "1 done today" : "\(m.completed) done today").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    /// Focus / break / long break lengths and the breathing guide, right here (same values as Settings).
    private func pomodoroSettingsRows(_ p: PomodoroTimer) -> some View {
        VStack(spacing: 6) {
            MinutesRow(title: "Focus", value: Binding(get: { p.focusMinutes }, set: { p.focusMinutes = $0 }), range: 5...90, step: 5)
            MinutesRow(title: "Break", value: Binding(get: { p.breakMinutes }, set: { p.breakMinutes = $0 }), range: 1...30, step: 1)
            MinutesRow(title: "Long break", value: Binding(get: { p.longBreakMinutes }, set: { p.longBreakMinutes = $0 }), range: 5...60, step: 5)
            HStack {
                Text("Breathing in breaks").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: Binding(get: { model.breathingPattern }, set: { model.breathingPattern = $0 })) {
                    Text("Box").tag("box"); Text("4-7-8").tag("478"); Text("Sighing").tag("sigh")
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 170)
            }
            Text("Long break after every \(PomodoroTimer.longBreakEvery) focus periods. Changes apply to the next period.")
                .font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.18)))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func pomodoroState(_ p: PomodoroTimer) -> String {
        if let prompt = p.prompt { return PromptPanel.question(prompt) }
        switch (p.phase, p.running) {
        case (.idle, _): return "Ready"
        case (.focus, true): return "Focus"
        case (.focus, false): return "Paused"
        case (.breakTime, _): return "Break"
        case (.longBreak, _): return "Long break"
        }
    }

    private func pomodoroTint(_ p: PomodoroTimer) -> Color {
        if p.prompt != nil { return .accentColor }
        switch p.phase {
        case .focus: return p.running ? .green : .orange
        case .breakTime, .longBreak: return .cyan
        case .idle: return .secondary
        }
    }

    // MARK: - Quick timer

    private var timerCard: some View {
        let t = model.quickTimer
        return Card {
            HStack {
                Label("Quick timer", systemImage: "hourglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                SoundToggle(symbol: "ipad.landscape", on: t.soundOnTablet, help: "Sound on the tablet") { t.soundOnTablet.toggle() }
                SoundToggle(symbol: "laptopcomputer", on: t.soundOnMac, help: "Sound on this Mac") { t.soundOnMac.toggle() }
            }
            if t.isRunning {
                HStack {
                    let left = t.remaining()
                    Text(clock(Int(left.rounded(.up))))
                        .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(left <= 30 ? Color.orange : .primary)
                    Text("of \(Int(t.totalSeconds / 60)) min").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    PillButton(title: "Stop", style: .plain) { t.stop() }
                }
                GeometryReader { geo in
                    let left = t.totalSeconds > 0 ? t.remaining() / t.totalSeconds : 0
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule().fill(left * t.totalSeconds <= 30 ? Color.orange : Color.green)
                            .frame(width: max(4, geo.size.width * left))
                    }
                }
                .frame(height: 5)
            } else {
                HStack(spacing: 6) {
                    ForEach(QuickTimer.presets, id: \.self) { minutes in
                        PillButton(title: "\(minutes)", style: minutes == t.minutes ? .selected : .plain, wide: true) { t.start(minutes: minutes) }
                    }
                }
                HStack(spacing: 8) {
                    Stepper(value: Binding(get: { t.minutes }, set: { t.setMinutes($0) }), in: QuickTimer.minMinutes...QuickTimer.maxMinutes) {
                        Text("\(t.minutes) min").font(.system(size: 13, weight: .medium)).monospacedDigit()
                    }
                    Spacer()
                    PillButton(title: "Start", style: .filled) { t.start() }
                }
            }
        }
    }

    // MARK: - Weather not set yet

    private var weatherHint: some View {
        Button { close(); openSettings() } label: {
            HStack(spacing: 8) {
                Image(systemName: "location.circle").font(.system(size: 15)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Set a location for the weather").font(.system(size: 12, weight: .semibold))
                    Text("This Mac's location or a city, in Settings").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.055)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 4) {
            FooterButton(title: "On Tablet", symbol: "ipad.landscape", disabled: !linked) { model.link.openPageNow() }
                .help("Open the dashboard on the tablet")
            FooterButton(title: "In Browser", symbol: "safari", disabled: false) {
                if let url = model.browserURL { NSWorkspace.shared.open(url) }
                close()
            }
            Spacer()
            FooterButton(title: "Quit", symbol: "power", disabled: false) { NSApp.terminate(nil) }
        }
    }

    private var linked: Bool { if case .linked = model.link.status { return true }; return false }

    private func clock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

// MARK: - Pieces

private struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.055)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.08)))
    }
}

private struct MinutesRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    var body: some View {
        HStack {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Text("\(value) min").font(.system(size: 13, weight: .semibold)).monospacedDigit().frame(width: 56, alignment: .trailing)
            Stepper("", value: $value, in: range, step: step).labelsHidden()
        }
    }
}

private struct PillButton: View {
    enum Style { case filled, plain, selected }
    let title: String
    let style: Style
    var wide = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: wide ? .infinity : nil)
                .padding(.horizontal, wide ? 0 : 14).frame(height: 30)
                .foregroundStyle(style == .filled ? Color.white : style == .selected ? Color.accentColor : .primary)
                .background(Capsule().fill(background))
                .overlay(Capsule().strokeBorder(style == .selected ? Color.accentColor.opacity(0.7) : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
    }

    private var background: Color {
        switch style {
        case .filled: return Color.accentColor.opacity(hover ? 0.85 : 1)
        case .plain, .selected: return .primary.opacity(hover ? 0.12 : 0.07)
        }
    }
}

private struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 30)
                .background(Circle().fill(.primary.opacity(hover ? 0.12 : 0.06)))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle()).help(help).onHover { hover = $0 }
    }
}

private struct SoundToggle: View {
    let symbol: String
    let on: Bool
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 11))
                Image(systemName: on ? "speaker.wave.2.fill" : "speaker.slash.fill").font(.system(size: 10))
            }
            .foregroundStyle(on ? Color.primary : Color.secondary.opacity(0.6))
            .padding(.horizontal, 7).frame(height: 22)
            .background(Capsule().fill(.primary.opacity(on ? 0.09 : 0.04)))
        }
        .buttonStyle(PressStyle()).help(help + (on ? ": on" : ": off"))
    }
}

private struct FooterButton: View {
    let title: String
    let symbol: String
    let disabled: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 12)).lineLimit(1).fixedSize()
                .padding(.horizontal, 8).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(.primary.opacity(hover && !disabled ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle()).disabled(disabled).opacity(disabled ? 0.4 : 1).onHover { hover = $0 }
    }
}

/// Press feedback: a slight scale-down, fast (140 ms ease-out).
private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}
