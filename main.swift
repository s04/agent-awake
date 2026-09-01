// AgentAwake — menu-bar toggle for caffeinate + lid-closed wakefulness (pmset disablesleep),
// with guards that restore normal sleep when the agent is done, the battery is low, the
// machine overheats, or a timer ends. Locks the screen when the lid is reopened, since with
// sleep disabled macOS never goes through a sleep/wake cycle and never shows the lock screen.
import AppKit
import IOKit
import IOKit.ps
import ServiceManagement
import UserNotifications

let repo = "s04/agent-awake"
let pmset = "/usr/bin/pmset"
let sudoersFile = "/private/etc/sudoers.d/agentawake"
let lowBatteryPercent = 20

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var caffeinate: Process?
    var lidWasClosed = false, externalDisplayWhileOpen = false, clamshellClose = false
    var wasOnAC = true
    var lowBatteryFired = false, heatFired = false, watchedWasRunning = false
    var awakeUntil: Date?
    var offTimer: Timer?

    // MARK: - Preferences
    let d = UserDefaults.standard
    let prefDefaults: [String: Bool] = [
        "lockOnLidOpen": true, "offOnUnplug": false, "offOnLowBattery": true,
        "offOnOverheat": true, "offOnProcessExit": false, "restoreSleepOnQuit": false,
    ]
    func pref(_ k: String) -> Bool { d.object(forKey: k) as? Bool ?? prefDefaults[k] ?? false }
    @objc func togglePref(_ i: NSMenuItem) { let k = i.representedObject as! String; d.set(!pref(k), forKey: k) }
    var watched: [String] {
        get { d.stringArray(forKey: "watchedProcesses") ?? ["claude", "codex", "cursor-agent", "gemini", "aider"] }
        set { d.set(newValue, forKey: "watchedProcesses") }
    }

    // MARK: - Lifecycle
    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu(); menu.delegate = self
        statusItem.menu = menu
        lidWasClosed = lidClosed
        wasOnAC = power.onAC
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.pollLid() }
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.pollGuards() }
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.checkThermal() }
        updateIcon()
    }

    // agentawake://on  agentawake://off  agentawake://lock   (use `open -g` from hooks)
    func application(_ app: NSApplication, open urls: [URL]) {
        for u in urls {
            switch u.host {
            case "on": agentMode()
            case "off": allOff()
            case "lock": lockScreen()
            default: break
            }
        }
    }

    func applicationWillTerminate(_ n: Notification) {
        caffeinate?.terminate()
        if pref("restoreSleepOnQuit") && lidAwake { setLid(false, wait: true) }
    }

    // MARK: - System state
    @discardableResult
    func run(_ path: String, _ args: [String]) -> (status: Int32, out: String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "") }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        return (p.terminationStatus, out)
    }

    var caffeinated: Bool { caffeinate?.isRunning == true }

    var lidAwake: Bool {
        for line in run(pmset, ["-g"]).out.split(separator: "\n") where line.contains("SleepDisabled") {
            return line.contains("1")
        }
        return false
    }

    // Physical lid sensor, read from the power-management root domain. No process spawn, cheap to poll.
    var lidClosed: Bool {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard svc != 0 else { return false }
        defer { IOObjectRelease(svc) }
        let v = IORegistryEntryCreateCFProperty(svc, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return (v as? Bool) ?? false
    }

    var power: (onAC: Bool, percent: Int) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return (true, 100) }
        var onAC = true, pct = 100
        for src in list {
            guard let desc = IOPSGetPowerSourceDescription(info, src)?.takeUnretainedValue() as? [String: Any] else { continue }
            if let c = desc[kIOPSCurrentCapacityKey] as? Int { pct = c }
            onAC = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        }
        return (onAC, pct)
    }

    // True when the sudoers rule installed by togglePasswordless() is present.
    var passwordless: Bool { run("/usr/bin/sudo", ["-n", "-l", pmset, "-a", "disablesleep", "0"]).status == 0 }

    var anythingOn: Bool { caffeinated || lidAwake }

    // MARK: - Watchers
    // Locks on close so the session is already locked before the lid ever reopens, and again on
    // reopen in case the app started with the lid shut. Skipped when an external display was
    // attached at close time: that is clamshell mode, and the normal screen-lock timeout applies.
    func pollLid() {
        let closed = lidClosed
        defer { lidWasClosed = closed }
        if !closed { externalDisplayWhileOpen = NSScreen.screens.count > 1 }
        guard closed != lidWasClosed, pref("lockOnLidOpen") else { return }
        if closed { clamshellClose = externalDisplayWhileOpen }
        if !clamshellClose { lockScreen() }
    }

    func pollGuards() {
        let pw = power
        if pref("offOnUnplug") && wasOnAC && !pw.onAC && anythingOn { allOff(reason: "Unplugged from power") }
        wasOnAC = pw.onAC
        if pref("offOnLowBattery") && !pw.onAC && pw.percent <= lowBatteryPercent {
            if !lowBatteryFired && anythingOn { allOff(reason: "Battery at \(pw.percent)%") }
            lowBatteryFired = true
        } else { lowBatteryFired = false }
        if pref("offOnProcessExit") {
            let running = watched.contains { run("/usr/bin/pgrep", ["-x", $0]).status == 0 }
            if watchedWasRunning && !running && anythingOn { allOff(reason: "Agent process exited") }
            watchedWasRunning = running
        }
        checkThermal()
    }

    func checkThermal() {
        let hot = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        guard hot else { heatFired = false; return }
        guard pref("offOnOverheat"), !heatFired, lidClosed, lidAwake else { return }
        heatFired = true
        allOff(reason: "Overheating with the lid closed")
    }

    // Same call ⌃⌘Q makes (private login.framework). Falls back to display sleep, which locks
    // when "Require password after display is turned off" is set in Lock Screen settings.
    func lockScreen() {
        if let h = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_NOW),
           let sym = dlsym(h, "SACLockScreenImmediate") {
            typealias Fn = @convention(c) () -> Int32
            _ = unsafeBitCast(sym, to: Fn.self)()
            return
        }
        run(pmset, ["displaysleepnow"])
    }

    // MARK: - Actions
    @objc func toggleCaffeinate() {
        if caffeinated { caffeinate?.terminate(); caffeinate = nil }
        else {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
            p.arguments = ["-dims"]; try? p.run(); caffeinate = p
        }
        updateIcon()
    }

    // Uses the passwordless sudo rule when installed, otherwise an admin-password prompt.
    func setLid(_ on: Bool, wait: Bool = false) {
        let p = Process()
        if passwordless {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            p.arguments = ["-n", pmset, "-a", "disablesleep", on ? "1" : "0"]
        } else {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "do shell script \"\(pmset) -a disablesleep \(on ? 1 : 0)\" with administrator privileges"]
        }
        p.terminationHandler = { [weak self] _ in DispatchQueue.main.async { self?.updateIcon() } }
        try? p.run()
        if wait { p.waitUntilExit() }
    }

    @objc func toggleLid() { setLid(!lidAwake) }
    @objc func agentMode() {
        if !caffeinated { toggleCaffeinate() }
        if !lidAwake { setLid(true) }
        d.set(true, forKey: "lockOnLidOpen")
    }

    @objc func allOffClicked() { allOff() }
    func allOff(reason: String? = nil) {
        cancelTimer()
        if caffeinated { toggleCaffeinate() }
        if lidAwake { setLid(false) }
        if let r = reason {
            notify("Sleep restored: \(r)", passwordless ? "" : "Enter your admin password to finish restoring normal sleep.")
        }
    }

    @objc func startTimer(_ item: NSMenuItem) {
        let secs = TimeInterval(item.tag)
        if !caffeinated { toggleCaffeinate() }
        awakeUntil = Date().addingTimeInterval(secs)
        offTimer?.invalidate()
        offTimer = Timer.scheduledTimer(withTimeInterval: secs, repeats: false) { [weak self] _ in
            self?.allOff(reason: "Timer ended")
        }
    }
    @objc func cancelTimer() { awakeUntil = nil; offTimer?.invalidate(); offTimer = nil }

    // Installs (or removes) a sudoers rule allowing exactly `pmset -a disablesleep 0|1` without a
    // password, so the automatic guards can restore sleep while the machine is unattended.
    @objc func togglePasswordless() {
        let sh: String
        if passwordless {
            sh = "rm -f \(sudoersFile)"
        } else {
            let rule = "\(NSUserName()) ALL=(root) NOPASSWD: \(pmset) -a disablesleep 0, \(pmset) -a disablesleep 1"
            sh = "t=$(mktemp) && echo '\(rule)' >$t && visudo -cf $t && install -m 0440 -o root -g wheel $t \(sudoersFile)"
        }
        let r = run("/usr/bin/osascript", ["-e", "do shell script \"\(sh)\" with administrator privileges"])
        if r.status != 0 { alert("Couldn't change the sudo rule", "The command was cancelled or failed.") }
    }

    @objc func editWatched() {
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        f.stringValue = watched.joined(separator: ", ")
        if alert("Watched processes", "Comma-separated process names (as shown by pgrep -x). When the last one exits, sleep is restored.",
                 buttons: ["Save", "Cancel"], accessory: f) == .alertFirstButtonReturn {
            watched = f.stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
    }

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }
    @objc func toggleLaunchAtLogin() {
        do { try launchAtLogin ? SMAppService.mainApp.unregister() : SMAppService.mainApp.register() }
        catch { alert("Couldn't change launch at login", error.localizedDescription) }
    }

    var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0" }

    // Compares against the latest GitHub release; opens the release page if newer. No Sparkle, no
    // background polling: a signed/notarized build is the prerequisite for real in-place updates.
    @objc func checkForUpdates() {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        URLSession.shared.dataTask(with: url) { [self] data, _, err in
            let j = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let tag = (j?["tag_name"] as? String) ?? ""
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            DispatchQueue.main.async { [self] in
                guard !latest.isEmpty, let page = j?["html_url"] as? String else {
                    alert("Couldn't check for updates", err?.localizedDescription ?? "No releases found."); return
                }
                if latest.compare(version, options: .numeric) == .orderedDescending {
                    if alert("AgentAwake \(latest) is available", "You have \(version).", buttons: ["Download", "Later"]) == .alertFirstButtonReturn {
                        NSWorkspace.shared.open(URL(string: page)!)
                    }
                } else { alert("AgentAwake \(version) is up to date", "") }
            }
        }.resume()
    }

    @objc func quit() { NSApplication.shared.terminate(nil) }

    // MARK: - UI
    @discardableResult
    func alert(_ title: String, _ text: String, buttons: [String] = ["OK"], accessory: NSView? = nil) -> NSApplication.ModalResponse {
        let a = NSAlert(); a.messageText = title; a.informativeText = text; a.accessoryView = accessory
        buttons.forEach { a.addButton(withTitle: $0) }
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal()
    }

    func notify(_ title: String, _ body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let c = UNUserNotificationCenter.current()
        c.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            let n = UNMutableNotificationContent(); n.title = title; n.body = body
            c.add(UNNotificationRequest(identifier: UUID().uuidString, content: n, trigger: nil))
        }
    }

    func item(_ menu: NSMenu, _ title: String, _ sel: Selector, _ key: String = "", on: Bool? = nil, tag: Int = 0, obj: Any? = nil) {
        let i = NSMenuItem(title: (on == true ? "✓ " : "") + title, action: sel, keyEquivalent: key)
        i.target = self; i.tag = tag; i.representedObject = obj; menu.addItem(i)
    }
    func prefItem(_ menu: NSMenu, _ title: String, _ key: String) {
        item(menu, title, #selector(togglePref(_:)), on: pref(key), obj: key)
    }

    func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let pwless = passwordless
        item(menu, "Stay awake (caffeinate)", #selector(toggleCaffeinate), "c", on: caffeinated)
        item(menu, "Awake with lid closed" + (pwless ? "" : " (admin)"), #selector(toggleLid), "l", on: lidAwake)
        prefItem(menu, "Lock screen on lid close and reopen", "lockOnLidOpen")
        item(menu, "Agent mode: all ON", #selector(agentMode), "a")

        let timer = NSMenuItem(title: awakeUntil.map { "Awake for… (\(remaining($0)) left)" } ?? "Awake for…", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (t, m) in [("30 minutes", 30), ("1 hour", 60), ("2 hours", 120), ("4 hours", 240), ("8 hours", 480)] {
            item(sub, t, #selector(startTimer(_:)), tag: m * 60)
        }
        if awakeUntil != nil { sub.addItem(.separator()); item(sub, "Cancel timer", #selector(cancelTimer)) }
        timer.submenu = sub; menu.addItem(timer)
        menu.addItem(.separator())
        item(menu, "Everything OFF (sleep normally)", #selector(allOffClicked), "o")
        menu.addItem(.separator())

        let auto = NSMenuItem(title: "Auto-off", action: nil, keyEquivalent: "")
        let a = NSMenu()
        prefItem(a, "When unplugged from power", "offOnUnplug")
        prefItem(a, "Below \(lowBatteryPercent)% battery", "offOnLowBattery")
        prefItem(a, "When overheating with lid closed", "offOnOverheat")
        prefItem(a, "When agent exits (\(watched.prefix(2).joined(separator: ", "))…)", "offOnProcessExit")
        item(a, "Edit watched processes…", #selector(editWatched))
        a.addItem(.separator())
        prefItem(a, "Restore sleep on quit", "restoreSleepOnQuit")
        a.addItem(.separator())
        item(a, pwless ? "Sleep toggle without password (click to remove)" : "Allow sleep toggle without password…",
             #selector(togglePasswordless), on: pwless)
        auto.submenu = a; menu.addItem(auto)
        menu.addItem(.separator())

        item(menu, "Launch at login", #selector(toggleLaunchAtLogin), on: launchAtLogin)
        item(menu, "Check for updates… (v\(version))", #selector(checkForUpdates))
        menu.addItem(.separator())
        item(menu, pref("restoreSleepOnQuit") ? "Quit (restores normal sleep)" : "Quit (stops caffeinate; lid setting stays)",
             #selector(quit), "q")
    }

    func remaining(_ until: Date) -> String {
        let m = max(0, Int(until.timeIntervalSinceNow / 60))
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }

    func menuWillOpen(_ menu: NSMenu) { rebuild(menu); updateIcon() }

    func updateIcon() {
        statusItem.button?.title = caffeinated ? (lidAwake ? "☕️🔒" : "☕️") : (lidAwake ? "👁️" : "😴")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
