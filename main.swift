// AgentAwake — menu-bar toggle for caffeinate + lid-closed wakefulness (pmset disablesleep).
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var caffeinate: Process?

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "☕️"
        let menu = NSMenu(); menu.delegate = self
        statusItem.menu = menu
        rebuild(menu)
    }

    var caffeinated: Bool { caffeinate?.isRunning == true }

    var lidAwake: Bool {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g"]
        let out = Pipe(); p.standardOutput = out
        try? p.run(); p.waitUntilExit()
        let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in s.split(separator: "\n") where line.contains("SleepDisabled") {
            return line.contains("1")
        }
        return false
    }

    func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let caff = NSMenuItem(title: (caffeinated ? "✓ " : "") + "Stay awake (caffeinate)",
                              action: #selector(toggleCaffeinate), keyEquivalent: "c")
        caff.target = self; menu.addItem(caff)
        let lid = NSMenuItem(title: (lidAwake ? "✓ " : "") + "Awake with lid closed (admin)",
                             action: #selector(toggleLid), keyEquivalent: "l")
        lid.target = self; menu.addItem(lid)
        let both = NSMenuItem(title: "Agent mode: both ON", action: #selector(agentMode), keyEquivalent: "a")
        both.target = self; menu.addItem(both)
        menu.addItem(.separator())
        let off = NSMenuItem(title: "Everything OFF (sleep normally)", action: #selector(allOff), keyEquivalent: "o")
        off.target = self; menu.addItem(off)
        menu.addItem(.separator())
        let q = NSMenuItem(title: "Quit (stops caffeinate; lid setting stays)",
                           action: #selector(quit), keyEquivalent: "q")
        q.target = self; menu.addItem(q)
    }

    func menuWillOpen(_ menu: NSMenu) { rebuild(menu); updateIcon() }

    func updateIcon() {
        statusItem.button?.title = caffeinated ? (lidAwake ? "☕️🔒" : "☕️") : (lidAwake ? "👁️" : "😴")
    }

    @objc func toggleCaffeinate() {
        if caffeinated { caffeinate?.terminate(); caffeinate = nil }
        else {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
            p.arguments = ["-ims"]; try? p.run(); caffeinate = p
        }
        updateIcon()
    }

    func setLid(_ on: Bool) {
        let script = "do shell script \"pmset -a disablesleep \(on ? 1 : 0)\" with administrator privileges"
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]; try? p.run(); p.waitUntilExit()
        updateIcon()
    }

    @objc func toggleLid() { setLid(!lidAwake) }
    @objc func agentMode() { if !caffeinated { toggleCaffeinate() }; if !lidAwake { setLid(true) } }
    @objc func allOff() { if caffeinated { toggleCaffeinate() }; if lidAwake { setLid(false) } }

    @objc func quit() {
        caffeinate?.terminate()
        NSApplication.shared.terminate(nil)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
