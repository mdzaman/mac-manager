import Foundation

/// Thin, dependency-free wrapper around `Process` for the system commands the
/// app relies on (`lsof`, `ps`, `du`, `vm_stat`, `sysctl`, ...).
enum Shell {

    struct Result {
        let out: String
        let err: String
        let status: Int32
        var ok: Bool { return status == 0 }
    }

    /// Runs an executable and captures its output. Blocking — always call from
    /// a background queue.
    @discardableResult
    static func run(_ launchPath: String, _ args: [String]) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return Result(out: "", err: "\(error)", status: -1)
        }

        // Drain before waiting so a large payload can't fill the pipe buffer
        // and deadlock the child.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return Result(out: String(data: outData, encoding: .utf8) ?? "",
                      err: String(data: errData, encoding: .utf8) ?? "",
                      status: process.terminationStatus)
    }

    /// Convenience for pipelines and globbing. Returns stdout only.
    static func sh(_ command: String) -> String {
        return run("/bin/sh", ["-c", command]).out
    }

    /// Runs AppleScript. Used as the fallback path for privileged file moves,
    /// where Finder puts up its own authentication sheet.
    @discardableResult
    static func osascript(_ script: String) -> Result {
        return run("/usr/bin/osascript", ["-e", script])
    }

    static func sysctl(_ key: String) -> String {
        return run("/usr/sbin/sysctl", ["-n", key]).out
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sysctlInt(_ key: String) -> Int64 {
        return Int64(sysctl(key)) ?? 0
    }
}

extension String {
    /// Splits into non-empty lines with surrounding whitespace removed.
    var nonEmptyLines: [String] {
        return self.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Splits on runs of whitespace — the shape most BSD tools print in.
    var whitespaceFields: [String] {
        return self.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
    }
}
