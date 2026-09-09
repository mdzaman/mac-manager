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

    /// Runs a command and delivers stdout one line at a time as it arrives,
    /// rather than collecting everything and returning at the end.
    ///
    /// Needed for anything long enough that the user deserves to see progress —
    /// a backup can run for minutes, and a frozen window with no output is
    /// indistinguishable from a hang.
    ///
    /// Reads to EOF in a loop rather than using `readabilityHandler` with
    /// `terminationHandler`: those two race, and the process can be reported as
    /// finished while output is still buffered in the pipe. Draining to EOF
    /// first guarantees every line is delivered before `completion` runs.
    @discardableResult
    static func stream(_ launchPath: String,
                       _ args: [String],
                       onLine: @escaping (String) -> Void,
                       completion: @escaping (Int32, String) -> Void) -> Process? {
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
            completion(-1, "\(error)")
            return nil
        }

        // stderr is drained on its own queue so a chatty error stream cannot
        // fill its buffer and deadlock the child while we read stdout.
        var errorText = ""
        let errorDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            errorText = String(data: data, encoding: .utf8) ?? ""
            errorDone.signal()
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let handle = outPipe.fileHandleForReading
            var pending = ""

            while true {
                let data = handle.availableData
                if data.isEmpty { break }  // EOF
                guard let text = String(data: data, encoding: .utf8) else { continue }

                pending += text
                var lines = pending.components(separatedBy: "\n")
                // Whatever follows the last newline is an incomplete line.
                pending = lines.removeLast()
                for line in lines where !line.isEmpty { onLine(line) }
            }
            if !pending.isEmpty { onLine(pending) }

            process.waitUntilExit()
            errorDone.wait()
            completion(process.terminationStatus, errorText)
        }

        return process
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
