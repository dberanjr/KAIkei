import Testing
@testable import UsageCore

@Suite struct TerminalControlTests {
    // pid -> (parent pid, command path), shaped like `ps -axo pid=,ppid=,comm=`.
    let table: [Int: ProcessInfoRow] = [
        500: .init(ppid: 400, command: "/Users/x/.nvm/bin/node"),
        400: .init(ppid: 300, command: "-zsh"),
        300: .init(ppid: 200, command: "/usr/bin/login"),
        200: .init(ppid: 1, command: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
        600: .init(ppid: 700, command: "claude"),
        700: .init(ppid: 1, command: "/Applications/iTerm.app/Contents/MacOS/iTerm2"),
        800: .init(ppid: 900, command: "claude"),
        900: .init(ppid: 1, command: "/Applications/Ghostty.app/Contents/MacOS/ghostty"),
    ]

    @Test func findsTerminalAppAmongAncestors() {
        #expect(TerminalControl.detectApp(pid: 500, table: table) == .terminal)
        #expect(TerminalControl.detectApp(pid: 600, table: table) == .iterm)
    }

    @Test func unknownHostIsReportedAsUnsupported() {
        #expect(TerminalControl.detectApp(pid: 800, table: table) == .unsupported)
    }

    @Test func survivesParentCycles() {
        let loop: [Int: ProcessInfoRow] = [1: .init(ppid: 2, command: "a"), 2: .init(ppid: 1, command: "b")]
        #expect(TerminalControl.detectApp(pid: 1, table: loop) == .unsupported)
    }

    @Test func terminalScriptTargetsTheTabByTTY() throws {
        let script = try #require(TerminalControl.appleScript(app: .terminal, tty: "ttys003", command: .compact))
        #expect(script.contains("tell application \"Terminal\""))
        #expect(script.contains("/dev/ttys003"))
        #expect(script.contains("do script \"/compact\" in"))
    }

    @Test func itermScriptWritesToTheSessionByTTY() throws {
        let script = try #require(TerminalControl.appleScript(app: .iterm, tty: "ttys010", command: .clear))
        #expect(script.contains("tell application \"iTerm2\""))
        #expect(script.contains("/dev/ttys010"))
        #expect(script.contains("write text \"/clear\""))
    }

    @Test func refusesATTYThatCouldInjectScript() {
        #expect(TerminalControl.appleScript(app: .terminal, tty: "ttys001\" & (do shell script \"x\") & \"", command: .clear) == nil)
        #expect(TerminalControl.appleScript(app: .terminal, tty: "../etc", command: .clear) == nil)
    }

    @Test func unsupportedAppHasNoScript() {
        #expect(TerminalControl.appleScript(app: .unsupported, tty: "ttys001", command: .clear) == nil)
    }

    @Test func buttonsAreDisabledWhileClaudeIsBusyWithReasons() {
        #expect(TerminalControl.availability(app: .terminal, tty: "ttys001", status: "idle") == .available)
        #expect(TerminalControl.availability(app: .terminal, tty: "ttys001", status: "busy") == .unavailable("Claude is working. Wait until it is idle."))
        #expect(TerminalControl.availability(app: .unsupported, tty: "ttys001", status: "idle") == .unavailable("Only Terminal and iTerm2 can be controlled."))
        #expect(TerminalControl.availability(app: .terminal, tty: nil, status: "idle") == .unavailable("No terminal found for this session."))
    }
}
