import Foundation

/// Runs the status line command that was installed before KAIkei's, so it keeps working. It gets Claude Code's JSON on stdin,
/// runs under a time limit, and is killed when it overruns: a slow script of someone else's must not blank the status line.
public enum ChildCommand {
    public static func run(_ command: String, input: Data, timeout: TimeInterval) -> String? {
        // Writing to a command that exits without reading its stdin would otherwise kill this process.
        signal(SIGPIPE, SIG_IGN)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        guard (try? process.run()) != nil else { return nil }

        // Both pipes are serviced on their own threads: a large input and a large output can otherwise wait on each other.
        let queue = DispatchQueue(label: "kaikei.child", attributes: .concurrent)
        queue.async {
            try? stdin.fileHandleForWriting.write(contentsOf: input)
            try? stdin.fileHandleForWriting.close()
        }
        let lock = NSLock()
        var output = Data()
        let drained = DispatchSemaphore(value: 0)
        queue.async {
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); output = data; lock.unlock()
            drained.signal()
        }

        let deadline = DispatchTime.now() + timeout
        if finished.wait(timeout: deadline) == .timedOut {
            process.terminate()
            return nil
        }
        // The command is done; its output is ready unless something it started still holds the pipe open.
        if drained.wait(timeout: deadline) == .timedOut { return nil }
        lock.lock(); defer { lock.unlock() }
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
}
