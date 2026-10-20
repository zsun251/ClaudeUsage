import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let sessionItem = NSMenuItem(title: "Session: –", action: nil, keyEquivalent: "")
    let weeklyItem = NSMenuItem(title: "Weekly: –", action: nil, keyEquivalent: "")
    let updatedItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    var lastUpdated: String?

    func applicationDidFinishLaunching(_ n: Notification) {
        item.button?.title = "✳︎ …"
        menu.addItem(sessionItem)
        menu.addItem(weeklyItem)
        menu.addItem(.separator())
        menu.addItem(updatedItem)
        menu.addItem(NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Open usage page", action: #selector(openPage), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        refresh()
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in self.refresh() }
        // After sleep: wait for the network, then refresh
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.refresh() }
        }
    }

    @objc func openPage() { NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!) }

    func run(_ path: String, _ args: [String]) -> Data? {
        let p = Process(); let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return data
    }

    let service = "Claude Code-credentials"

    func credentials() -> [String: Any]? {
        guard let data = run("/usr/bin/security", ["find-generic-password", "-s", service, "-w"]) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // Read-only: never renew here. The refresh token rotates, so renewing would
    // invalidate the copy a running Claude Code holds and log it out.
    // An expired token (~8h) is left for Claude Code to renew on its next use.
    func token() -> String? {
        guard let o = credentials()?["claudeAiOauth"] as? [String: Any],
              (o["expiresAt"] as? Double ?? 0) / 1000 > Date().timeIntervalSince1970 + 60 else { return nil }
        return o["accessToken"] as? String
    }

    // Keep the old numbers visible, but make clear they're stale
    func showStale() {
        item.button?.title = "✳︎ stale"
        updatedItem.title = "Login expired – open `claude` to renew" + (lastUpdated.map { " (data from \($0))" } ?? "")
    }

    func resetText(_ iso: String?) -> String {
        guard let iso else { return "" }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return "" }
        let r = RelativeDateTimeFormatter(); r.unitsStyle = .short
        return "  (resets " + r.localizedString(for: d, relativeTo: Date()) + ")"
    }

    @objc func refresh() { fetch(retries: 3) }

    func fetch(retries: Int) {
        DispatchQueue.global().async {
            guard let t = self.token() else {
                DispatchQueue.main.async { self.showStale() }
                return
            }
            var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            URLSession.shared.dataTask(with: req) { data, resp, _ in
                let code = (resp as? HTTPURLResponse)?.statusCode
                // Token rejected: wait for Claude Code to renew it
                if code == 401 {
                    DispatchQueue.main.async { self.showStale() }
                    return
                }
                // Network not ready yet (e.g. just woke up): retry in 30s
                if code == nil && retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { self.fetch(retries: retries - 1) }
                    return
                }
                DispatchQueue.main.async {
                    guard let data, code == 200,
                          let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        self.item.button?.title = "✳︎ !"
                        self.updatedItem.title = "Error – run `claude` once to refresh login"
                        return
                    }
                    let s = j["five_hour"] as? [String: Any], w = j["seven_day"] as? [String: Any]
                    let sp = Int((s?["utilization"] as? Double) ?? 0), wp = Int((w?["utilization"] as? Double) ?? 0)
                    self.item.button?.title = "✳︎ \(sp)% · \(wp)%"
                    self.sessionItem.title = "Session (5h): \(sp)%" + self.resetText(s?["resets_at"] as? String)
                    self.weeklyItem.title = "Weekly: \(wp)%" + self.resetText(w?["resets_at"] as? String)
                    let df = DateFormatter(); df.timeStyle = .short
                    self.lastUpdated = df.string(from: Date())
                    self.updatedItem.title = "Updated \(self.lastUpdated!)"
                }
            }.resume()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
