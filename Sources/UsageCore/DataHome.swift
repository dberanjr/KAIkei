import Foundation

/// Where `.claude/` and `.claude.json` are read from. `KAIKEI_HOME` points the app at another directory, which is how
/// `scripts/screenshots.sh` renders the README pictures from invented data instead of a real account.
public enum DataHome {
    public static var url: URL {
        if let override = ProcessInfo.processInfo.environment["KAIKEI_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}
