import AppKit
import PawmitCore

/// 알림을 보낸 에이전트의 터미널(탭)로 이동.
///
/// bezel(MIT, boxed-dev/bezel)의 `TerminalJumpPlan`·`TerminalJumper`·`TerminalJumpSecurity`를 줄여 옮겼다.
/// 그 세션으로 이동. Claude 데스크탑·Codex 앱 안 세션이면 그 대화를 바로 연다
/// (claude://code/continue?session=…, codex://threads/<id>). 아니면 tmux → iTerm2 → Terminal.app → kitty → IDE 작업공간 → 앱 활성화 순.
enum TerminalJumper {
    static func jump(_ env: HookEnvelope, cwd: String?) {
        let hint = env.env
        let tty = env.tty
        let program = (hint["TERM_PROGRAM"] ?? "").lowercased()
        let bundle = (hint["__CFBundleIdentifier"] ?? "").lowercased()
        let session = AgentAdapters.normalize(env).sessionID

        DispatchQueue.global(qos: .userInitiated).async {
            if bundle == AppSessions.claudeDesktopBundle {
                if let session, let local = AppSessions.claudeLocalSessionID(cliSessionID: session),
                   let url = AppSessions.claudeDesktopURL(localSessionID: local) {
                    Log.info("terminal jump → Claude 앱 대화 \(local)")
                    open(url)
                } else {
                    Log.info("terminal jump → Claude 앱 (대화를 못 찾음)")
                    activate(AppSessions.claudeDesktopBundle)
                }
                return
            }
            if bundle == AppSessions.codexAppBundle {
                if let session, let url = AppSessions.codexThreadURL(sessionID: session) {
                    open(url)
                } else {
                    activate(AppSessions.codexAppBundle)
                }
                return
            }
            if let pane = hint["TMUX_PANE"], isSafe(pane) {
                var args = ["select-pane", "-t", pane]
                if let tmux = hint["TMUX"], let socket = tmux.split(separator: ",").first.map(String.init), isSafe(socket), !socket.isEmpty {
                    args = ["-S", socket] + args
                }
                for path in ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"] where FileManager.default.fileExists(atPath: path) {
                    _ = run(path, args)
                    break
                }
            }
            if program.contains("iterm") || bundle.contains("iterm") || hint["ITERM_SESSION_ID"] != nil {
                let guid = hint["ITERM_SESSION_ID"].map { s -> String in s.split(separator: ":").last.map(String.init) ?? s }
                if selectITerm(guid: guid, tty: tty) { return }
                activate("com.googlecode.iterm2")
                return
            }
            if program.contains("apple_terminal") || bundle == "com.apple.terminal" {
                if let tty, selectTerminalApp(tty: tty) { return }
                activate("com.apple.Terminal")
                return
            }
            if let kitty = hint["KITTY_WINDOW_ID"], isSafe(kitty) {
                _ = run("/usr/bin/env", ["kitty", "@", "focus-window", "--match", "id:\(kitty)"])
                activate("net.kovidgoyal.kitty")
                return
            }
            if program.contains("vscode") || bundle.contains("visualstudiocode") || bundle.contains("todesktop") || hint["CURSOR_TRACE_ID"] != nil {
                let cli = bundle.contains("todesktop") || hint["CURSOR_TRACE_ID"] != nil ? "cursor" : "code"
                if let cwd, isSafe(cwd), run("/usr/bin/env", [cli, "-r", cwd]) { return }
            }
            if let guess = bundleGuess(program: program, bundle: hint["__CFBundleIdentifier"]) {
                activate(guess)
            }
        }
    }

    private static func selectITerm(guid: String?, tty: String?) -> Bool {
        guard guid != nil || tty != nil else { return false }
        var match = "set matched to false\n"
        if let guid {
            match += "try\nif unique ID of s is \"\(escape(guid))\" then set matched to true\nend try\n"
        }
        if let tty {
            match += "if not matched then\ntry\nif tty of s is \"\(escape(tty))\" then set matched to true\nend try\nend if\n"
        }
        let script = """
        tell application "iTerm2"
          if not (it is running) then error "not running"
          activate
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                \(match)
                if matched then
                  select w
                  select t
                  select s
                  set index of w to 1
                  return "ok"
                end if
              end repeat
            end repeat
          end repeat
          error "no match"
        end tell
        """
        return appleScript(script)
    }

    private static func selectTerminalApp(tty: String) -> Bool {
        let full = escape(tty)
        let short = escape(tty.replacingOccurrences(of: "/dev/", with: ""))
        let script = """
        tell application "Terminal"
          activate
          repeat with w in windows
            repeat with t in tabs of w
              set tabTTY to tty of t as text
              if tabTTY is "\(full)" or tabTTY contains "\(short)" then
                set frontmost of w to true
                set selected of t to true
                return "ok"
              end if
            end repeat
          end repeat
          error "no match"
        end tell
        """
        return appleScript(script)
    }

    private static func appleScript(_ source: String) -> Bool {
        var ok = false
        DispatchQueue.main.sync {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            ok = error == nil
            if let error { Log.info("terminal jump AppleScript 실패: \(error[NSAppleScript.errorNumber] ?? "?")") }
        }
        return ok
    }

    /// 앱 주소(claude://, codex://) 열기 — 주소를 받은 앱이 앞으로 오면서 그 대화로 간다
    private static func open(_ url: URL) {
        DispatchQueue.main.async { NSWorkspace.shared.open(url) }
    }

    private static func activate(_ bundleID: String) {
        DispatchQueue.main.async {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                app.activate()
            } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        }
    }

    private static func bundleGuess(program: String, bundle: String?) -> String? {
        if program.contains("ghostty") { return "com.mitchellh.ghostty" }
        if program.contains("warp") { return "dev.warp.Warp-Stable" }
        if program.contains("wezterm") { return "com.github.wez.wezterm" }
        if program.contains("kitty") { return "net.kovidgoyal.kitty" }
        if program.contains("zed") { return "dev.zed.Zed" }
        return bundle
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// AppleScript 문자열 리터럴 안에 넣을 값 이스케이프 (bezel TerminalJumpSecurity)
    static func escape(_ value: String) -> String {
        var out = ""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x5C: out += "\\\\"
            case 0x22: out += "\\\""
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x00..<0x20, 0x7F...0x9F: continue
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    static func isSafe(_ s: String) -> Bool {
        !s.isEmpty && !s.contains("\0") && !s.contains("\n") && !s.contains("\r")
    }
}
