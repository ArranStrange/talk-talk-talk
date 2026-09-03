import AppKit

/// Retains a menu item's closure: NSMenuItem.target is weak, so without
/// this the action would be deallocated before the click arrives.
final class MenuAction: NSObject {
    private let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}

final class MenuBarController: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?
    private var actions: [MenuAction] = []
    private let coord: Coordinator

    init(coordinator: Coordinator) { self.coord = coordinator }

    private static let glyph: [String: String] = [
        "idle": "◍", "loading": "◐", "synthesizing": "◐", "summarising": "◓",
        "playing": "◉", "paused": "◑", "ready": "◈",
    ]
    private static let colors: [String: NSColor] = [
        "idle":         NSColor(white: 0.55, alpha: 1),
        "summarising":  NSColor(srgbRed: 0.62, green: 0.45, blue: 0.95, alpha: 1),
        "loading":      NSColor(srgbRed: 0.95, green: 0.60, blue: 0.10, alpha: 1),
        "synthesizing": NSColor(srgbRed: 0.95, green: 0.60, blue: 0.10, alpha: 1),
        "playing":      NSColor(srgbRed: 0.20, green: 0.72, blue: 0.32, alpha: 1),
        "paused":       NSColor(srgbRed: 0.90, green: 0.75, blue: 0.10, alpha: 1),
        "ready":        NSColor(srgbRed: 0.30, green: 0.50, blue: 0.95, alpha: 1),
    ]
    private static let stateLabel: [String: String] = [
        "idle": "Idle", "loading": "Loading model…", "synthesizing": "Preparing…",
        "playing": "Speaking", "paused": "Paused", "ready": "Reply ready",
        "summarising": "Summarising…",
    ]

    private static let voices: [(String, [String], String)] = [
        ("American female", ["af_heart", "af_bella", "af_nicole", "af_sarah",
                             "af_sky", "af_nova", "af_alloy", "af_aoede",
                             "af_jessica", "af_kore", "af_river"], "en-us"),
        ("American male",   ["am_michael", "am_adam", "am_puck", "am_echo",
                             "am_eric", "am_fenrir", "am_liam", "am_onyx"], "en-us"),
        ("British female",  ["bf_emma", "bf_isabella", "bf_alice", "bf_lily"], "en-gb"),
        ("British male",    ["bm_george", "bm_fable", "bm_daniel", "bm_lewis"], "en-gb"),
    ]
    private static let speeds: [Double] = [0.8, 0.9, 1.0, 1.1, 1.25, 1.5]
    private static let providers: [(String, String)] = [
        ("claude-cli", "Claude Code CLI (no key, uses your plan)"),
        ("anthropic",  "Claude API (needs key)"),
        ("openai",     "ChatGPT API (needs key)"),
        ("extractive", "Local, no AI (free, instant)"),
    ]
    private static let models: [String: [String]] = [
        "claude-cli": ["haiku", "sonnet", "opus"],
        "anthropic":  ["claude-haiku-4-5-20251001", "claude-sonnet-5", "claude-opus-5"],
        "openai":     ["gpt-4o-mini", "gpt-4o"],
        "extractive": [],
    ]

    func install() {
        let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self          // rebuilt on open, so it is never stale
        i.menu = menu
        item = i
        updateGlyph(state: "idle")
    }

    func remove() {
        if let i = item { NSStatusBar.system.removeStatusItem(i) }
        item = nil
    }

    func updateGlyph(state: String) {
        guard let button = item?.button else { return }
        button.attributedTitle = NSAttributedString(
            string: MenuBarController.glyph[state] ?? "◍",
            attributes: [.font: NSFont(name: "Helvetica", size: 14)
                                ?? .systemFont(ofSize: 14),
                         .foregroundColor: MenuBarController.colors[state]
                                ?? MenuBarController.colors["idle"]!])
    }

    // MARK: building

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        actions.removeAll()
        let st = coord.state
        let cfg = Config()
        let speaking = (st == "playing" || st == "paused")

        // 1. what is happening
        add(menu, MenuBarController.stateLabel[st] ?? st, enabled: false)

        // 2. the switches worth reaching for first
        menu.addItem(.separator())
        add(menu, "Auto-read", checked: Prefs.autoRead) { self.coord.toggleAutoRead() }
        add(menu, "TL;DR", checked: cfg.tldrOn) { self.coord.toggleTldr() }
        add(menu, "Bring To Front") { self.coord.bringPillToFront() }

        // 3. acting on what is happening right now
        menu.addItem(.separator())
        if st == "summarising" {
            add(menu, "Cancel summarising") { self.coord.cancelSummarise() }
        } else if st == "ready" {
            add(menu, "Play reply") { self.coord.playPending(.speak) }
            add(menu, "Dismiss reply") { self.coord.dismissReady() }
        } else {
            add(menu, st == "paused" ? "Resume" : "Pause", enabled: speaking) {
                Daemon.toggle()
            }
            add(menu, "Rewind 10s", enabled: speaking) { Daemon.back() }
            add(menu, "Stop", enabled: speaking) { Daemon.stop() }
        }

        // 4. starting something new
        menu.addItem(.separator())
        add(menu, "Speak selection") { self.coord.readSelection(.speak) }
        add(menu, "Selection → reader") { self.coord.readSelection(.reader) }
        add(menu, "Speak clipboard") { self.coord.speakClipboard(.speak) }
        add(menu, "Clipboard → reader") { self.coord.speakClipboard(.reader) }
        add(menu, "Speak the last reply", enabled: st == "ready") {
            self.coord.playPending(.speak)
        }
        add(menu, "Last reply → reader", enabled: st == "ready") {
            self.coord.playPending(.reader)
        }

        // 5. RSVP
        menu.addItem(.separator())
        add(menu, "Read-along words while speaking", checked: Prefs.readAlong) {
            self.coord.toggleReadAlong()
        }
        let wpmMenu = NSMenu()
        for wpm in [200, 250, 300, 350, 400, 500, 600, 800] {
            add(wpmMenu, "\(wpm) wpm", checked: Prefs.readerWpm == wpm) {
                Prefs.readerWpm = wpm
            }
        }
        addSubmenu(menu, "Reader speed (\(Prefs.readerWpm) wpm)", wpmMenu)
        if coord.reader.isOpen {
            let (at, total) = coord.reader.position
            add(menu, "Reader position: \(at) / \(total)", enabled: false)
            add(menu, "Close reader") { self.coord.reader.close() }
        }

        // 6. TLDR settings
        menu.addItem(.separator())
        addSubmenu(menu, "TL;DR options", tldrMenu(cfg))

        // 7. voice
        menu.addItem(.separator())
        let voiceMenu = NSMenu()
        for (group, ids, lang) in MenuBarController.voices {
            let sub = NSMenu()
            for id in ids {
                let bare = id.replacingOccurrences(of: "^[a-z]+_", with: "",
                                                   options: .regularExpression)
                add(sub, bare.prefix(1).uppercased() + bare.dropFirst(),
                    checked: cfg.voice == id) {
                    Config.update { $0["voice"] = id; $0["lang"] = lang }
                    Hud.shared.show("Voice: \(id)")
                }
            }
            addSubmenu(voiceMenu, group, sub)
        }
        addSubmenu(menu, "Voice (\(cfg.voice))", voiceMenu)

        let speedMenu = NSMenu()
        for sp in MenuBarController.speeds {
            add(speedMenu, trim(sp) + "x", checked: abs(cfg.speed - sp) < 0.001) {
                Config.set("speed", sp)
                Hud.shared.show("Speed: \(self.trim(sp))x")
            }
        }
        addSubmenu(menu, "Speaking speed (\(trim(cfg.speed))x)", speedMenu)

        // 8. housekeeping
        menu.addItem(.separator())
        add(menu, "Hotkeys…") {
            Hud.shared.show("""
            ⌃⌥S speak selection
            ⌃⌥R selection in the reader
            ⌃⌥P speak the reply / pause
            ⌃⌥← rewind 10s
            ⌃⌥X cancel / dismiss / stop
            ⌃⌥A auto-read on/off
            ⌃⌥T TLDR on/off (applies to both)
               in the reader: hold R to read · ↑↓ speed
               ←→ step a word · esc close
            """, seconds: 6)
        }
        add(menu, "Start at login", checked: LoginItem.enabled) {
            if let problem = LoginItem.set(!LoginItem.enabled) {
                Hud.shared.show(problem, seconds: 5)
            } else {
                Hud.shared.show(LoginItem.enabled
                                ? "Will start at login" : "Will not start at login")
            }
        }
        add(menu, "Reset pill position") {
            Prefs.pillAnchor = nil
            self.coord.bringPillToFront()
        }
        add(menu, "Restart speech engine") {
            Daemon.quit()
            Hud.shared.show("Engine will reload on next use")
        }
        menu.addItem(.separator())
        add(menu, "Quit Talk Talk Talk") { self.coord.quit() }
    }

    private func tldrMenu(_ cfg: Config) -> NSMenu {
        let m = NSMenu()
        let current = cfg.tldrProvider

        let provMenu = NSMenu()
        for (id, label) in MenuBarController.providers {
            add(provMenu, label, checked: current == id) {
                Config.update { $0["tldr_provider"] = id; $0["tldr_model"] = nil }
                Hud.shared.show("TLDR via \(label)")
            }
        }
        addSubmenu(m, "Provider", provMenu)

        let available = MenuBarController.models[current] ?? []
        if !available.isEmpty {
            let modelMenu = NSMenu()
            let chosen = cfg.tldrModel ?? available[0]
            for name in available {
                add(modelMenu, name, checked: chosen == name) {
                    Config.set("tldr_model", name)
                }
            }
            modelMenu.addItem(.separator())
            add(modelMenu, "Custom model…") {
                if let v = self.prompt(title: "TLDR model",
                                      message: "Model identifier to send to the "
                                             + "\(current) API:",
                                      value: cfg.tldrModel ?? ""), !v.isEmpty {
                    Config.set("tldr_model", v)
                }
            }
            addSubmenu(m, "Model", modelMenu)
        }

        let lenMenu = NSMenu()
        for n in [1, 2, 3, 5] {
            add(lenMenu, "\(n) sentence\(n == 1 ? "" : "s")",
                checked: cfg.tldrSentences == n) {
                Config.set("tldr_sentences", n)
            }
        }
        addSubmenu(m, "Summary length", lenMenu)

        let minMenu = NSMenu()
        for n in [40, 70, 120, 200] {
            add(minMenu, "over \(n) words", checked: cfg.tldrMinWords == n) {
                Config.set("tldr_min_words", n)
                Hud.shared.show("Only summarising text over \(n) words")
            }
        }
        addSubmenu(m, "Only summarise (over \(cfg.tldrMinWords) words)", minMenu)

        m.addItem(.separator())
        for (provider, label) in [("anthropic", "Store Claude API key…"),
                                  ("openai", "Store ChatGPT API key…")] {
            add(m, label) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("ttt-set-key \(provider)", forType: .string)
                Hud.shared.show("Command copied — paste it in Terminal.\n"
                                + "Your key is typed straight into the Keychain.",
                                seconds: 5)
            }
        }
        add(m, "Set Claude workspace id…") {
            if let v = self.prompt(
                title: "Claude workspace id",
                message: "Identity-linked API keys must name a workspace.\n"
                       + "Find it in console.anthropic.com → Settings → Workspaces "
                       + "(wrkspc_…):",
                value: cfg.workspaceId ?? "") {
                let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                Config.set("anthropic_workspace_id", t.isEmpty ? nil : t)
                Hud.shared.show(t.isEmpty ? "Workspace id cleared" : "Workspace: \(t)")
            }
        }
        return m
    }

    // MARK: helpers

    private func trim(_ d: Double) -> String {
        d == d.rounded() ? String(Int(d)) : String(format: "%g", d)
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, checked: Bool = false,
                     enabled: Bool = true,
                     action: (() -> Void)? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.state = checked ? .on : .off
        if let action, enabled {
            let holder = MenuAction(action)
            actions.append(holder)
            item.target = holder
            item.action = #selector(MenuAction.fire)
        } else {
            item.isEnabled = false
        }
        menu.addItem(item)
        return item
    }

    private func addSubmenu(_ menu: NSMenu, _ title: String, _ sub: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = sub
        menu.addItem(item)
    }

    private func prompt(title: String, message: String, value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        return response == .alertFirstButtonReturn ? field.stringValue : nil
    }
}
