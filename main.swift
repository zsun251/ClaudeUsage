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

    func run(_ path: String, _ args: [String], input: String? = nil) -> Data? {
        let p = Process(); let pipe = Pipe(); let inPipe = Pipe()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        if input != nil { p.standardInput = inPipe }
        guard (try? p.run()) != nil else { return nil }
        if let input {
            inPipe.fileHandleForWriting.write(input.data(using: .utf8)!)
            try? inPipe.fileHandleForWriting.close()
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return data
    }

    let service = "Claude Code-credentials"

    func credentials() -> [String: Any]? {
        guard let data = run("/usr/bin/security", ["find-generic-password", "-s", service, "-w"]) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // Access tokens last ~8h, so after a long sleep it has usually expired.
    // Renew it the same way Claude Code does and write it back, since the refresh token rotates.
    func token(forceRenew: Bool = false) -> String? {
        guard var j = credentials(), var o = j["claudeAiOauth"] as? [String: Any] else { return nil }
        let expiresAt = (o["expiresAt"] as? Double ?? 0) / 1000
        if !forceRenew && expiresAt > Date().timeIntervalSince1970 + 60 { return o["accessToken"] as? String }
        guard let rt = o["refreshToken"] as? String else { return nil }
        var req = URLRequest(url: URL(string: "https://platform.claude.com/v1/oauth/token")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token", "refresh_token": rt,
            "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
            "scope": ((o["scopes"] as? [String]) ?? []).joined(separator: " ")])
        var result: [String: Any]?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if (resp as? HTTPURLResponse)?.statusCode == 200, let data {
                result = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            done.signal()
        }.resume()
        done.wait()
        guard let r = result, let at = r["access_token"] as? String, let exp = r["expires_in"] as? Double else { return nil }
        o["accessToken"] = at
        if let newRt = r["refresh_token"] as? String { o["refreshToken"] = newRt }
        o["expiresAt"] = (Date().timeIntervalSince1970 + exp) * 1000
        j["claudeAiOauth"] = o
        if let out = try? JSONSerialization.data(withJSONObject: j) {
            // Hex via stdin so the secret never appears in process arguments
            let hex = out.map { String(format: "%02x", $0) }.joined()
            _ = run("/usr/bin/security", ["-i"], input: "add-generic-password -U -a \(NSUserName()) -s \"\(service)\" -X \(hex)\n")
        }
        return at
    }

    func resetText(_ iso: String?) -> String {
        guard let iso else { return "" }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return "" }
        let r = RelativeDateTimeFormatter(); r.unitsStyle = .short
        return "  (resets " + r.localizedString(for: d, relativeTo: Date()) + ")"
    }

    @objc func refresh() { fetch(retries: 3, renewed: false) }

    func fetch(retries: Int, renewed: Bool) {
        DispatchQueue.global().async {
            guard let t = self.token(forceRenew: renewed) else {
                DispatchQueue.main.async {
                    self.item.button?.title = "✳︎ no login"
                    // Keep the old numbers visible, but make clear they're stale
                    self.updatedItem.title = "Not logged in – run `claude /login`" + (self.lastUpdated.map { " (data from \($0))" } ?? "")
                }
                return
            }
            var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            URLSession.shared.dataTask(with: req) { data, resp, _ in
                let code = (resp as? HTTPURLResponse)?.statusCode
                // Token rejected: renew it, then retry once
                if code == 401 && !renewed {
                    self.fetch(retries: retries, renewed: true); return
                }
                // Network not ready yet (e.g. just woke up): retry in 30s
                if code == nil && retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { self.fetch(retries: retries - 1, renewed: renewed) }
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
