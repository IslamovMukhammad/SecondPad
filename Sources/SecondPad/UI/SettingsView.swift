import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var liveUsage: LiveUsage
    @State private var cityQuery = ""
    @State private var cityResults: [WeatherPlace] = []
    @State private var searching = false
    @State private var focusMinutes = 25
    @State private var breakMinutes = 5
    @State private var longBreakMinutes = 20
    @State private var soundOnMac = true
    @State private var locating = false
    @State private var locationError: String?
    @State private var macLocation = MacLocation()

    var body: some View {
        Form {
            Section("Tablet") {
                LabeledContent("Connection", value: linkText)
                Text("Android tablet over USB: turn on USB debugging on the tablet and install adb "
                     + "(Android platform tools). SecondPad runs `adb reverse` and opens "
                     + "http://127.0.0.1:\(String(model.web.port))/ in Chrome with its own key. The server "
                     + "listens on this Mac only and answers only the page that has the key.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show the StandBy clock when this Mac sleeps or locks", isOn: $model.standbyOnSleep)
                Toggle("Use this Mac's SF Rounded on the tablet", isOn: $model.standbyMacFont)
                Text("The StandBy digits in this Mac's own SF Pro Rounded, sent to your tablet over the cable "
                     + "(SecondPad ships no font). Apple licenses its fonts for Apple platforms, so this is off "
                     + "by default; off, the tablet's own font is used.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Claude Code") {
                LabeledContent("Hooks", value: model.hooks.hooks ? "Installed" : "Not installed")
                LabeledContent("Plan limits", value: statusLineText)
                HStack {
                    Button(model.hooks.hooks ? "Reinstall Hooks" : "Install Hooks") { model.installHooks() }
                    if model.hooks.hooks { Button("Remove Hooks") { model.removeHooks() } }
                }
                if let error = model.hookError { Text(error).font(.caption).foregroundStyle(.red) }
                Text("Adds a small hook script to ~/.claude/settings.json (a backup is kept). It sends only the "
                     + "session state, never your prompts or code, over a private socket with a per-install token.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Live usage (5-hour and 7-day limits from Anthropic)", isOn: $liveUsage.enabled)
                Text(liveUsage.enabled ? liveUsage.status
                     : "Off. When on, reads Claude Code's login from the Keychain (kept in memory only) and asks "
                       + "api.anthropic.com for your usage every 5 minutes. Undocumented endpoint.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Pomodoro") {
                Stepper("Focus: \(focusMinutes) min", value: $focusMinutes, in: 5...90, step: 5)
                    .onChange(of: focusMinutes) { model.pomodoro.focusMinutes = focusMinutes }
                Stepper("Break: \(breakMinutes) min", value: $breakMinutes, in: 1...30)
                    .onChange(of: breakMinutes) { model.pomodoro.breakMinutes = breakMinutes }
                Stepper("Long break: \(longBreakMinutes) min", value: $longBreakMinutes, in: 5...60, step: 5)
                    .onChange(of: longBreakMinutes) { model.pomodoro.longBreakMinutes = longBreakMinutes }
                Picker("Breathing during breaks", selection: $model.breathingPattern) {
                    Text("Box · 4-4-4-4").tag("box")
                    Text("4-7-8").tag("478")
                    Text("Cyclic sighing").tag("sigh")
                }
                Text("During a focus period only, the front app (and Chrome's tab domain, never in incognito) "
                     + "is checked to show purity and distractions on the Deep Focus page. Nothing is recorded "
                     + "outside focus.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Quick timer") {
                Toggle("Play the chime on this Mac", isOn: $soundOnMac)
                    .onChange(of: soundOnMac) { model.quickTimer.soundOnMac = soundOnMac }
            }

            Section("Weather") {
                LabeledContent("Location", value: model.weather.place?.name ?? "Not set")
                Button(locating ? "Finding this Mac…" : "Use This Mac's Location") { useMacLocation() }
                    .disabled(locating)
                if let locationError { Text(locationError).font(.caption).foregroundStyle(.red) }
                HStack {
                    TextField("Search a city", text: $cityQuery).onSubmit(search)
                    Button("Search", action: search).disabled(cityQuery.trimmingCharacters(in: .whitespaces).isEmpty || searching)
                }
                ForEach(Array(cityResults.enumerated()), id: \.offset) { _, place in
                    Button(place.name) {
                        model.weather.setPlace(place)
                        cityResults = []
                        cityQuery = ""
                    }
                }
                if model.weather.place != nil {
                    Button("Clear City") { model.weather.setPlace(nil) }
                }
                Text("Open-Meteo, free and keyless. Either this Mac's approximate location (asked once, rounded to "
                     + "about 1 km) or a city you search; then only its coordinates are sent, every 15 minutes.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Spotify") {
                Text("Now playing uses AppleScript. macOS asks once for permission to control Spotify; "
                     + "if you said no, allow it in System Settings → Privacy & Security → Automation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 680)
        .onAppear {
            focusMinutes = model.pomodoro.focusMinutes
            breakMinutes = model.pomodoro.breakMinutes
            longBreakMinutes = model.pomodoro.longBreakMinutes
            soundOnMac = model.quickTimer.soundOnMac
        }
    }

    private var linkText: String {
        switch model.linkStatus {
        case .noADB: "adb not found"
        case .noDevice: "No tablet"
        case .linked: model.viewers > 0 ? "Connected · page open" : "Connected · waiting for the page"
        }
    }

    private var statusLineText: String {
        if model.hooks.statusLine { return "From Claude Code's statusLine" }
        if model.hooks.foreignStatusLine { return liveUsage.enabled ? "Live usage (your own statusLine is kept)" : "Your own statusLine is set: turn on Live usage" }
        return liveUsage.enabled ? "Live usage" : "Install hooks or turn on Live usage"
    }

    private func useMacLocation() {
        locating = true
        locationError = nil
        Task {
            do {
                let place = try await macLocation.place()
                model.weather.setPlace(place)
            } catch {
                locationError = (error as? MacLocation.Failure)?.description ?? error.localizedDescription
            }
            locating = false
        }
    }

    private func search() {
        let query = cityQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        searching = true
        Task {
            let found = await WeatherService.search(query)
            cityResults = found
            searching = false
        }
    }
}
