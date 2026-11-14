import Foundation

/// What the other services already know, handed over so the health check does
/// not measure the same things twice.
struct HealthInputs {
    var ports: [PortEntry] = []
    var memory = MemorySnapshot()
    var volume = VolumeInfo()
    var reclaimableBytes: Int64 = 0
    var trashBytes: Int64 = 0
    var lastBackup: Date?
    var hasFullDiskAccess = true
    /// Largest memory users, already grouped by app.
    var topMemory: [ProcessGroup] = []
    /// Largest measured storage folders, name and bytes.
    var topStorage: [(name: String, bytes: Int64)] = []
}

/// A startup item read from a launchd property list.
struct LaunchItem {
    let path: String
    let label: String
    let program: String?
    let arguments: [String]
    let runAtLoad: Bool
    let keepAlive: Bool
    let isSystem: Bool

    var fileName: String { return (path as NSString).lastPathComponent }

    /// "com.epson" from "com.epson.esua.launcher" — enough to group by vendor.
    var vendorKey: String {
        let parts = label.components(separatedBy: ".")
        return parts.count >= 2 ? parts[0] + "." + parts[1] : label
    }

    var programMissing: Bool {
        guard let program = program, program.hasPrefix("/") else { return false }
        return !FileManager.default.fileExists(atPath: program)
    }

    var quarantineItem: QuarantineItem {
        return QuarantineItem(path: path, label: label, isSystem: isSystem)
    }
}

/// Diagnoses hardware, software, startup, port and security problems, and
/// explains each one: what was found, why it matters, how to fix it by hand,
/// and a button that does it wherever that is safe.
///
/// Every check reads; none of them changes anything. Changes happen only from
/// a fix button, after a confirmation that says exactly what will be done.
final class HealthScanner: ObservableObject {

    @Published private(set) var findings: [HealthFinding] = []
    @Published private(set) var isRunning = false
    @Published private(set) var stage = ""
    @Published private(set) var lastRun: Date?
    @Published private(set) var lastFixMessage: String?

    private let work = DispatchQueue(label: "com.macmanager.health", qos: .userInitiated)

    var worst: HealthSeverity { return findings.map { $0.severity }.max() ?? .ok }

    func count(_ severity: HealthSeverity) -> Int {
        return findings.filter { $0.severity == severity }.count
    }

    // MARK: - Running

    func run(inputs: HealthInputs) {
        if isRunning { return }
        isRunning = true
        lastFixMessage = nil

        work.async {
            var all: [HealthFinding] = []
            func step(_ name: String, _ check: () -> [HealthFinding]) {
                DispatchQueue.main.async { self.stage = name }
                all.append(contentsOf: check())
            }

            let items = HealthScanner.launchItems()

            step("Checking for known threats…") { HealthScanner.checkThreats(items: items) }
            step("Checking protections…") { HealthScanner.checkProtections(inputs: inputs) }
            step("Checking hardware…") { HealthScanner.checkHardware(inputs: inputs) }
            step("Checking software…") { HealthScanner.checkSoftware(inputs: inputs) }
            step("Checking startup items…") { HealthScanner.checkStartup(items: items) }
            step("Checking ports…") { HealthScanner.checkPorts(inputs: inputs) }
            step("Checking what can be cleaned…") { HealthScanner.checkCleanup(inputs: inputs) }

            let sorted = all.sorted { lhs, rhs in
                if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
                return lhs.title < rhs.title
            }

            DispatchQueue.main.async {
                self.findings = sorted
                self.isRunning = false
                self.stage = ""
                self.lastRun = Date()
            }
        }
    }

    // MARK: - Startup items

    static let launchDirectories: [(path: String, isSystem: Bool)] = [
        (NSHomeDirectory() + "/Library/LaunchAgents", false),
        ("/Library/LaunchAgents", true),
        ("/Library/LaunchDaemons", true),
    ]

    static func launchItems(in directories: [(path: String, isSystem: Bool)] = launchDirectories) -> [LaunchItem] {
        var items: [LaunchItem] = []
        for directory in directories {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names.sorted() where name.hasSuffix(".plist") {
                let path = directory.path + "/" + name
                // Some system plists are unreadable without admin rights; they
                // are skipped rather than guessed at.
                guard let dict = NSDictionary(contentsOfFile: path) as? [String: Any] else { continue }

                let arguments = dict["ProgramArguments"] as? [String] ?? []
                let program = (dict["Program"] as? String) ?? arguments.first
                let keepAlive = (dict["KeepAlive"] as? Bool) ?? (dict["KeepAlive"] != nil)

                items.append(LaunchItem(
                    path: path,
                    label: (dict["Label"] as? String) ?? name.replacingOccurrences(of: ".plist", with: ""),
                    program: program,
                    arguments: arguments,
                    runAtLoad: (dict["RunAtLoad"] as? Bool) ?? false,
                    keepAlive: keepAlive,
                    isSystem: directory.isSystem))
            }
        }
        return items
    }

    // MARK: - Threats

    /// Persistence used by malware families whose indicators are published.
    /// Matching on the launchd label alone, because the label is what the
    /// installer writes and it does not vary between victims.
    private static let knownBadLabels: [String: String] = [
        "com.finder.helper": "Atomic macOS Stealer (AMOS) backdoor",
    ]

    private static let interpreters: Set<String> = [
        "/bin/sh", "/bin/bash", "/bin/zsh", "/usr/bin/python3", "/usr/bin/osascript",
        "/usr/bin/perl", "/usr/bin/ruby",
    ]

    /// True when a path has a dot-prefixed component under a home folder, or
    /// lives somewhere temporary — places legitimate software does not launch
    /// from at boot.
    static func isHiddenOrTemporary(_ path: String) -> Bool {
        if path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/") || path.hasPrefix("/var/tmp/") {
            return true
        }
        guard path.hasPrefix("/Users/") else { return false }
        let components = path.components(separatedBy: "/").dropFirst(3)
        return components.contains { $0.hasPrefix(".") }
    }

    static func checkThreats(items: [LaunchItem]) -> [HealthFinding] {
        var findings: [HealthFinding] = []
        let home = NSHomeDirectory()

        for item in items {
            let scriptTargets = item.arguments.dropFirst().filter { $0.hasPrefix("/") }
            let runsInterpreter = item.program.map { interpreters.contains($0) } ?? false
            let hiddenTargets = scriptTargets.filter { isHiddenOrTemporary($0) }
            let programHidden = item.program.map { isHiddenOrTemporary($0) } ?? false

            if let family = knownBadLabels[item.label] {
                // Everything the published analyses name, where it exists.
                var files = [item.path]
                for name in [".agent", ".helper", ".mainhelper", ".pass", ".username", ".id"] {
                    let candidate = home + "/" + name
                    if FileManager.default.fileExists(atPath: candidate) { files.append(candidate) }
                }
                let payloadPresent = FileManager.default.fileExists(atPath: home + "/.helper")
                    || FileManager.default.fileExists(atPath: home + "/.mainhelper")

                var quarantine = [item.quarantineItem]
                for file in files.dropFirst() {
                    quarantine.append(QuarantineItem(path: file, label: nil, isSystem: false))
                }

                findings.append(HealthFinding(
                    id: "threat-" + item.label,
                    category: .security,
                    severity: .critical,
                    title: "Malware persistence found: \(family)",
                    summary: payloadPresent
                        ? "A root startup job is running a hidden backdoor from your home folder."
                        : "A root startup job installed by this malware is still running. Its payload file is no longer present, but the job, its script and its stored credentials are.",
                    why: "The startup job “\(item.label)” matches the published indicators for this malware. It was installed with your administrator password, runs as root at every boot, and restarts itself. This family steals saved passwords, browser sessions, crypto wallets and files, and stores your Mac login password in a hidden file. Treat every password and session that was on this Mac as exposed.",
                    steps: [
                        "Press “Quarantine now”. It stops the job and moves every file below into a quarantine folder, so nothing is destroyed and it can be examined later. macOS asks for your password once.",
                        "Change your Mac login password straight away, from a different device if you can — the old one was stored by the malware.",
                        "Change the passwords for email, banking, Apple ID, GitHub and anything saved in a browser, starting with email. Do it from a device you trust.",
                        "Sign out all other sessions on those accounts and turn on two-factor authentication.",
                        "Rotate keys that lived on this Mac: SSH keys, AWS and cloud credentials, API tokens, and move any crypto wallet funds to a new wallet created elsewhere.",
                        "Run a full scan with a reputable anti-malware tool, and once your passwords are changed, delete the quarantine folder.",
                    ],
                    command: "sudo launchctl bootout system/\(item.label); sudo mv \(shellQuote(item.path)) ~/Desktop/",
                    evidence: files,
                    fixes: [
                        HealthFix(label: "Quarantine now", icon: "lock.shield.fill",
                                  confirmation: "This stops the startup job “\(item.label)” and moves \(files.count) files into a quarantine folder. Nothing is deleted. macOS will ask for your password.",
                                  action: .quarantine(quarantine), destructive: true),
                        HealthFix(label: "Change Mac password", icon: "key.fill", confirmation: nil,
                                  action: .openURL("x-apple.systempreferences:com.apple.Users-Groups-Settings.extension")),
                    ]))
                continue
            }

            if (runsInterpreter && !hiddenTargets.isEmpty) || programHidden {
                let target = hiddenTargets.first ?? item.program ?? "an unknown program"
                findings.append(HealthFinding(
                    id: "suspicious-" + item.label,
                    category: .security,
                    severity: .warning,
                    title: "Unusual startup item: \(item.label)",
                    summary: "It launches \(target), a hidden or temporary location.",
                    why: "Legitimate software launches from /Applications or /Library, not from dot-files in a home folder or from a temporary directory. Hiding a startup script this way is a common malware technique, though developer tools occasionally do it too. Only you can tell whether you put it there.",
                    steps: [
                        "Press “Show the file” and look at what it is and when it was created.",
                        "If you do not recognise it, press “Disable” — the file is moved to quarantine, not deleted, so it can be put back.",
                        "If you do recognise it, leave it alone.",
                    ],
                    evidence: [item.path, target],
                    fixes: [
                        HealthFix(label: "Show the file", icon: "folder", confirmation: nil,
                                  action: .reveal(item.path)),
                        HealthFix(label: "Disable", icon: "xmark.shield",
                                  confirmation: "This stops “\(item.label)” and moves its startup file to quarantine. Nothing is deleted.",
                                  action: .quarantine([item.quarantineItem]), destructive: true),
                    ]))
            }
        }
        return findings
    }

    // MARK: - Protections

    static func checkProtections(inputs: HealthInputs) -> [HealthFinding] {
        var findings: [HealthFinding] = []

        let firewall = Shell.run("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"]).out
        let exposed = inputs.ports.filter { $0.isExposed }
        if firewall.contains("disabled") {
            findings.append(HealthFinding(
                id: "firewall-off",
                category: .security,
                severity: exposed.isEmpty ? .info : .warning,
                title: "Firewall is off",
                summary: exposed.isEmpty
                    ? "Nothing is listening on the network right now, so the exposure is low."
                    : "\(exposed.count) ports are reachable from your network with no firewall in front of them.",
                why: "The macOS firewall decides which apps may accept incoming connections. With it off, any program listening on all interfaces can be reached by other devices on the same Wi-Fi — which matters most on shared or public networks.",
                steps: [
                    "Press “Open Firewall settings”.",
                    "Switch Firewall on.",
                    "Optional: open Options and turn on stealth mode, so the Mac does not answer network probes.",
                ],
                command: "sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on",
                evidence: exposed.prefix(6).map { "port \($0.port) — \($0.processName)" },
                fixes: [HealthFix(label: "Open Firewall settings", icon: "flame", confirmation: nil,
                                  action: .openURL("x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall"))]))
        }

        let fileVault = Shell.run("/usr/bin/fdesetup", ["status"]).out
        if fileVault.contains("Off") {
            findings.append(HealthFinding(
                id: "filevault-off", category: .security, severity: .warning,
                title: "Disk encryption (FileVault) is off",
                summary: "Anyone with physical access to this Mac could read its disk.",
                why: "FileVault encrypts the startup disk so its contents are unreadable without your password. Without it, a lost or stolen Mac gives up everything on it.",
                steps: ["Press “Open FileVault settings”.", "Turn FileVault on and store the recovery key somewhere that is not this Mac."],
                fixes: [HealthFix(label: "Open FileVault settings", icon: "lock", confirmation: nil,
                                  action: .openURL("x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?FileVault"))]))
        }

        let sip = Shell.run("/usr/bin/csrutil", ["status"]).out
        if sip.contains("disabled") {
            findings.append(HealthFinding(
                id: "sip-off", category: .security, severity: .critical,
                title: "System Integrity Protection is disabled",
                summary: "macOS system files are not protected against modification.",
                why: "SIP stops even root from altering the operating system. It is only ever disabled deliberately, and leaving it off removes the main barrier between malware and the system itself.",
                steps: ["Restart and hold the power button to enter Recovery.", "Open Utilities › Terminal.", "Run: csrutil enable", "Restart."],
                command: "csrutil enable   # from Recovery"))
        }

        let gatekeeper = Shell.run("/usr/sbin/spctl", ["--status"])
        if (gatekeeper.out + gatekeeper.err).contains("disabled") {
            findings.append(HealthFinding(
                id: "gatekeeper-off", category: .security, severity: .warning,
                title: "Gatekeeper is disabled",
                summary: "Apps are not checked for a valid signature before they run.",
                why: "Gatekeeper blocks software that is unsigned or has been tampered with. Most Mac malware relies on persuading the user to switch it off or bypass it.",
                steps: ["Open Terminal.", "Run the command below and enter your password."],
                command: "sudo spctl --master-enable"))
        }

        if !inputs.hasFullDiskAccess {
            findings.append(HealthFinding(
                id: "fda-missing", category: .security, severity: .info,
                title: "Mac Manager cannot see protected folders",
                summary: "Photos, Mail, Safari data and some caches are invisible to scans and backups.",
                why: "macOS keeps these behind Full Disk Access, which only you can grant. Until then the storage figures are incomplete and backups leave those folders out.",
                steps: ["Press “Open Full Disk Access”.", "Press + and add Mac Manager.", "Switch it on, then quit and reopen Mac Manager."],
                fixes: [HealthFix(label: "Open Full Disk Access", icon: "lock.open", confirmation: nil,
                                  action: .openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"))]))
        }

        return findings
    }

    // MARK: - Hardware

    struct BusyProcess { let pid: Int32; let name: String; let path: String; let cpu: Double }

    /// The processes using the most CPU right now. The usual answer to "why is
    /// it hot", "why is the battery draining" and "why is it slow".
    static func topCPU(limit: Int = 4) -> [BusyProcess] {
        let output = Shell.run("/bin/ps", ["-Ao", "pid,pcpu,comm", "-r"]).out
        var found: [BusyProcess] = []
        for (index, line) in output.components(separatedBy: .newlines).enumerated() {
            if index == 0 { continue }
            let fields = line.whitespaceFields
            guard fields.count >= 3, let pid = Int32(fields[0]), let cpu = Double(fields[1]) else { continue }
            if cpu < 5 { break }
            let path = fields[2...].joined(separator: " ")
            found.append(BusyProcess(pid: pid, name: (path as NSString).lastPathComponent, path: path, cpu: cpu))
            if found.count >= limit { break }
        }
        return found
    }

    /// Processes that are part of macOS itself. They are named as causes but
    /// never offered a Quit button — quitting them fixes nothing.
    static func isSystemProcess(_ path: String) -> Bool {
        return path.hasPrefix("/System/") || path.hasPrefix("/usr/") || path.hasPrefix("/sbin/")
            || path.contains("kernel_task")
    }

    struct SleepBlocker { let pid: Int32; let name: String; let reason: String }

    /// Apps holding a power assertion that stops the Mac sleeping when idle.
    static func sleepBlockers() -> [SleepBlocker] {
        let output = Shell.run("/usr/bin/pmset", ["-g", "assertions"]).out
        var found: [SleepBlocker] = []
        for line in output.components(separatedBy: .newlines) {
            guard line.contains("NoIdleSleepAssertion") || line.contains("PreventUserIdleSystemSleep")
                    || line.contains("PreventSystemSleep") else { continue }
            // "   pid 9105(Claude): [0x...] 00:03:20 NoIdleSleepAssertion named: "Electron""
            guard let pidRange = line.range(of: "pid "), let open = line.firstIndex(of: "("),
                  let close = line.firstIndex(of: ")"), open < close else { continue }
            let pid = Int32(line[pidRange.upperBound ..< open].trimmingCharacters(in: .whitespaces)) ?? 0
            let name = String(line[line.index(after: open) ..< close])
            // powerd holding the display awake is normal use, not a culprit.
            if name == "powerd" || name == "coreaudiod" || pid == 0 { continue }
            // System daemons take short assertions for things like Handoff;
            // only apps are worth naming as the reason a Mac will not sleep.
            let path = Shell.run("/bin/ps", ["-p", "\(pid)", "-o", "comm="]).out
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if path.isEmpty || isSystemProcess(path) { continue }
            var reason = ""
            if let named = line.range(of: "named: ") {
                reason = line[named.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            }
            if !found.contains(where: { $0.pid == pid }) {
                found.append(SleepBlocker(pid: pid, name: name, reason: reason))
            }
        }
        return found
    }

    static func recentReports(matching test: (String) -> Bool, days: Int) -> [String] {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        var found: [String] = []
        for directory in ["/Library/Logs/DiagnosticReports", NSHomeDirectory() + "/Library/Logs/DiagnosticReports"] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            for name in names where !name.hasPrefix(".") && test(name) {
                let path = directory + "/" + name
                if let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                   modified >= cutoff {
                    found.append(path)
                }
            }
        }
        return found.sorted()
    }

    struct SystemExtension { let name: String; let bundleID: String; let state: String }

    /// Third-party drivers. They run with deep system access, so they are the
    /// first suspects when the kernel panics or sleep and shutdown misbehave.
    static func systemExtensions() -> [SystemExtension] {
        let output = Shell.run("/usr/bin/systemextensionsctl", ["list"]).out
        var found: [SystemExtension] = []
        for line in output.components(separatedBy: .newlines) {
            let columns = line.components(separatedBy: "\t")
            guard columns.count >= 6, columns[2].count == 10 else { continue }
            let bundle = columns[3].components(separatedBy: " ").first ?? columns[3]
            let state = columns[5].trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            found.append(SystemExtension(name: columns[4], bundleID: bundle, state: state))
        }
        return found
    }

    static func checkHardware(inputs: HealthInputs) -> [HealthFinding] {
        var findings: [HealthFinding] = []
        let busy = topCPU()
        let busyLines = busy.map { "\($0.name) — \(Int($0.cpu))% CPU" }
        let quittable = busy.filter { !isSystemProcess($0.path) && $0.cpu >= 20 && !$0.name.contains("MacManager") }

        func quitFixes(_ processes: [BusyProcess]) -> [HealthFix] {
            return processes.prefix(2).map { process in
                HealthFix(label: "Quit \(process.name.prefix(22))", icon: "xmark.circle",
                          confirmation: "\(process.name) (PID \(process.pid)) will be asked to quit. Unsaved work in it may be lost.",
                          action: .quitProcesses([process.pid]), destructive: true)
            }
        }

        // ---- Battery: wear -------------------------------------------------
        let power = Shell.run("/usr/sbin/system_profiler", ["SPPowerDataType"]).out
        let hasBattery = power.contains("Maximum Capacity:")
        if let capacityText = value(after: "Maximum Capacity:", in: power),
           let capacity = Int(capacityText.replacingOccurrences(of: "%", with: "")) {
            let condition = value(after: "Condition:", in: power) ?? "Unknown"
            let cycles = Int(value(after: "Cycle Count:", in: power) ?? "") ?? 0
            let healthy = capacity >= 80 && condition == "Normal"
            var cause: [String] = []
            if !healthy {
                cause.append("Capacity has fallen to \(capacity)% of the original after \(cycles) charge cycles.")
                if cycles > 800 { cause.append("The cycle count is close to the 1,000 the battery is rated for — this is ordinary wear.") }
                else if capacity < 80 { cause.append("That is more wear than \(cycles) cycles normally causes, which points to heat or long periods at full charge.") }
                if condition != "Normal" { cause.append("macOS itself reports the condition as “\(condition)”.") }
            }
            findings.append(HealthFinding(
                id: "battery", category: .hardware,
                severity: healthy ? .ok : (capacity < 70 || condition != "Normal" ? .warning : .info),
                title: healthy ? "Battery is healthy" : "Battery is wearing out",
                summary: "\(capacity)% of original capacity · \(cycles) charge cycles · condition \(condition)",
                why: "Batteries lose capacity with use. Apple considers a battery worn below 80% of its original capacity, and most MacBook batteries are rated for 1,000 cycles.",
                steps: healthy
                    ? ["Nothing to do. Keeping Optimised Battery Charging on slows further wear."]
                    : ["Press “Open Battery settings” and check Battery Health.", "Turn on Optimised Battery Charging if it is off.", "If the condition reads Service Recommended, book a battery replacement with Apple — it is the only real fix for a worn battery."],
                rootCause: cause,
                fixes: healthy ? [] : [HealthFix(label: "Open Battery settings", icon: "battery.75", confirmation: nil,
                                                action: .openURL("x-apple.systempreferences:com.apple.Battery-Settings.extension"))]))
        }

        // ---- Battery: drain right now ---------------------------------------
        // "-InternalBattery-0 (id=...)	42%; discharging; 1:24 remaining present: true"
        let batt = Shell.run("/usr/bin/pmset", ["-g", "batt"]).out
        let blockers = sleepBlockers()
        if hasBattery, batt.contains("discharging"),
           let percentRange = batt.range(of: "[0-9]+%", options: .regularExpression),
           let percent = Double(batt[percentRange].dropLast()),
           let timeRange = batt.range(of: "[0-9]+:[0-9]{2} remaining", options: .regularExpression) {
            let clock = batt[timeRange].replacingOccurrences(of: " remaining", with: "").components(separatedBy: ":")
            let minutes = (Double(clock[0]) ?? 0) * 60 + (Double(clock.count > 1 ? clock[1] : "0") ?? 0)
            // What a full charge would last at the present rate of use.
            let fullChargeHours = percent > 5 ? (minutes / (percent / 100)) / 60 : 99
            if fullChargeHours < 5 && minutes > 0 {
                var cause = busyLines.prefix(3).map { "Using power now: \($0)" }
                cause.append(contentsOf: blockers.map { "\($0.name) is stopping the Mac from sleeping when idle" + ($0.reason.isEmpty ? "." : " (“\($0.reason)”).") })
                if cause.isEmpty { cause = ["No single process stands out; the drain is spread across normal activity and screen brightness."] }
                findings.append(HealthFinding(
                    id: "battery-drain", category: .hardware, severity: fullChargeHours < 3 ? .warning : .info,
                    title: "Battery is draining quickly",
                    summary: String(format: "%.0f%% left, about %d:%02d at this rate — a full charge would last roughly %.1f hours.",
                                    percent, Int(minutes) / 60, Int(minutes) % 60, fullChargeHours),
                    why: "At the current rate of use a full charge lasts well under what this Mac is capable of. That is almost always software working hard in the background rather than a battery fault.",
                    steps: ["Quit the processes named under the root cause if you are not using them.", "Lower the screen brightness — the display is the largest single consumer.", "Open Battery settings and turn on Low Power Mode on battery."],
                    rootCause: cause,
                    fixes: quitFixes(quittable) + [HealthFix(label: "Open Battery settings", icon: "battery.25", confirmation: nil,
                                                              action: .openURL("x-apple.systempreferences:com.apple.Battery-Settings.extension"))]))
            }
        }

        // Battery temperature is reported in hundredths of a degree Celsius.
        if hasBattery {
            let io = Shell.sh("/usr/sbin/ioreg -rn AppleSmartBattery | /usr/bin/grep '\"Temperature\" ='")
            if let equals = io.range(of: "= "), let raw = Double(io[equals.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)) {
                let celsius = raw / 100
                if celsius >= 40 {
                    findings.append(HealthFinding(
                        id: "battery-heat", category: .hardware, severity: celsius >= 45 ? .warning : .info,
                        title: String(format: "Battery is hot: %.0f°C", celsius),
                        summary: "Heat is what ages a battery fastest.",
                        why: "Lithium batteries degrade quickly above about 35°C and macOS will pause charging above 45°C to protect the cells.",
                        steps: ["Quit the heavy processes named under the root cause.", "Move the Mac to a hard, flat surface and out of direct sun.", "If it is charging, unplug until it cools."],
                        rootCause: busyLines.isEmpty ? ["Nothing is using much CPU, so the heat is environmental — the surface, the room, or charging."] : busyLines.prefix(3).map { "Generating heat: \($0)" },
                        fixes: quitFixes(quittable)))
                }
            }
        }

        // ---- Thermal throttling ----------------------------------------------
        let therm = Shell.run("/usr/bin/pmset", ["-g", "therm"]).out
        var speedLimit = 100
        if let range = therm.range(of: "CPU_Speed_Limit"), let equals = therm[range.upperBound...].range(of: "= ") {
            speedLimit = Int(therm[equals.upperBound...].prefix { $0.isNumber }) ?? 100
        }
        let thermalState = ProcessInfo.processInfo.thermalState
        if speedLimit < 100 || thermalState == .serious || thermalState == .critical {
            findings.append(HealthFinding(
                id: "thermal", category: .hardware, severity: .warning,
                title: "The Mac is overheating and has slowed itself down",
                summary: speedLimit < 100 ? "The processor is limited to \(speedLimit)% of its speed." : "macOS reports serious thermal pressure.",
                why: "When it runs too hot, macOS deliberately slows the processor to cool down. Everything feels sluggish until the cause stops.",
                steps: ["Quit the processes named under the root cause.", "Make sure the vents at the back and sides are not blocked, and the Mac is on a hard surface.", "If this happens with nothing demanding running, the fans or vents may be clogged with dust — that needs a service visit."],
                rootCause: busyLines.isEmpty ? ["No process is using much CPU. Heat without load points to blocked airflow or a failing fan."] : busyLines.map { "Generating heat: \($0)" },
                fixes: quitFixes(quittable)))
        }

        // ---- Disk hardware -----------------------------------------------------
        let disk = Shell.run("/usr/sbin/diskutil", ["info", "/"]).out
        if let smart = value(after: "SMART Status:", in: disk) {
            if smart == "Verified" {
                findings.append(HealthFinding(
                    id: "smart", category: .hardware, severity: .ok,
                    title: "Startup disk hardware is healthy",
                    summary: "SMART status: Verified",
                    why: "The drive's own self-diagnosis reports no problems.",
                    steps: ["Nothing to do."]))
            } else if smart != "Not Supported" {
                findings.append(HealthFinding(
                    id: "smart", category: .hardware, severity: .critical,
                    title: "The startup disk is reporting a hardware problem",
                    summary: "SMART status: \(smart)",
                    why: "SMART is the drive's own self-diagnosis. Anything other than Verified means the drive expects to fail, and drives that say so usually do.",
                    steps: ["Back up everything important now — use the Backup tab.", "Do not wait for symptoms.", "The drive is soldered to the logic board on this Mac, so the repair is a board replacement by Apple."],
                    rootCause: ["The drive itself reported “\(smart)”. This is a physical fault, not something software can repair."],
                    fixes: [HealthFix(label: "Go to Backup", icon: "externaldrive", confirmation: nil, action: .navigate(.backup))]))
            }
        }

        // ---- Disk space ----------------------------------------------------------
        let free = inputs.volume.totalBytes > 0
            ? Double(inputs.volume.availableBytes) / Double(inputs.volume.totalBytes) : 1
        if inputs.volume.totalBytes > 0 && free < 0.20 {
            let snapshots = Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"]).out
                .nonEmptyLines.filter { $0.contains("com.apple.TimeMachine") }.count
            var cause = inputs.topStorage.prefix(4).map { "\($0.name) holds \(Fmt.bytes($0.bytes))" }
            if snapshots > 0 { cause.append("\(snapshots) local Time Machine snapshots are also holding space that macOS frees on demand.") }
            if inputs.trashBytes > 500_000_000 { cause.append("The Trash is holding \(Fmt.bytes(inputs.trashBytes)) that is not free until it is emptied.") }
            findings.append(HealthFinding(
                id: "disk-space", category: .hardware, severity: free < 0.10 ? .critical : .warning,
                title: free < 0.10 ? "The disk is almost full" : "Disk space is running low",
                summary: "\(Fmt.bytes(inputs.volume.availableBytes)) free of \(Fmt.bytes(inputs.volume.totalBytes))",
                why: "macOS needs free space for swap, updates and temporary files. Below about 10% free, apps slow down, updates fail and files can be lost when a save cannot complete. A nearly full SSD also wears faster.",
                steps: ["Press “Reclaim caches” to clear what rebuilds itself.", "Open Storage — the folders named under the root cause are where the space is.", "Open Growth to see what was added recently, and Duplicates for identical copies.", "Empty the Trash when you are sure of its contents."],
                rootCause: cause,
                fixes: [
                    HealthFix(label: "Reclaim caches", icon: "sparkles",
                              confirmation: "The contents of every safe cache folder will be moved to the Trash. Protected folders are skipped.",
                              action: .reclaimCaches),
                    HealthFix(label: "Open Storage", icon: "internaldrive", confirmation: nil, action: .navigate(.storage)),
                ]))
        }

        // ---- Memory ----------------------------------------------------------------
        if inputs.memory.pressureLevel != .normal || inputs.memory.swapUsedBytes > 4_000_000_000 {
            let pressured = inputs.memory.pressureLevel != .normal
            let hogs = inputs.topMemory.prefix(4)
            var cause = hogs.map { "\($0.name) holds \(Fmt.bytes($0.memoryBytes))" + ($0.members.count > 1 ? " across \($0.members.count) processes" : "") }
            cause.append("\(Fmt.bytes(inputs.memory.compressedBytes)) is compressed and \(Fmt.bytes(inputs.memory.swapUsedBytes)) has been pushed to disk — the Mac needs more memory than the \(Fmt.gb(inputs.memory.totalBytes)) installed.")
            let quitHogs = hogs.filter { $0.iconPath != nil && !$0.name.contains("Mac Manager") }.prefix(2).map { group in
                HealthFix(label: "Quit \(group.name.prefix(22))", icon: "xmark.circle",
                          confirmation: "\(group.name) will be asked to quit, freeing about \(Fmt.bytes(group.memoryBytes)). Unsaved work in it may be lost.",
                          action: .quitProcesses(group.pids), destructive: true)
            }
            findings.append(HealthFinding(
                id: "memory", category: .hardware, severity: pressured ? .warning : .info,
                title: pressured ? "Memory is under pressure" : "Heavy swap use",
                summary: "\(Fmt.bytes(inputs.memory.usedBytes)) in use of \(Fmt.bytes(inputs.memory.totalBytes)) · \(Fmt.bytes(inputs.memory.swapUsedBytes)) swapped to disk",
                why: "When memory runs short, macOS compresses it and then moves it to disk. That keeps things running but makes everything slower and adds wear to the SSD. Memory cannot be upgraded on this Mac, so the fix is using less of it.",
                steps: ["Quit the largest apps named under the root cause that you are not using.", "In browsers, close tabs — each one is a separate process.", "Restarting clears swap entirely if this has built up over days."],
                rootCause: cause,
                fixes: Array(quitHogs) + [HealthFix(label: "Open Memory", icon: "memorychip", confirmation: nil, action: .navigate(.memory))]))
        }

        // ---- Processor load -----------------------------------------------------------
        let load = Shell.sysctl("vm.loadavg").components(separatedBy: " ").compactMap { Double($0) }
        let cores = Double(Shell.sysctlInt("hw.ncpu"))
        if load.count >= 2, cores > 0, load[1] > cores {
            findings.append(HealthFinding(
                id: "cpu-load", category: .hardware, severity: .warning,
                title: "The processor is overloaded",
                summary: String(format: "Load average %.1f over five minutes on %.0f cores.", load[1], cores),
                why: "A load above the number of cores means more work is queued than the processor can run. Everything waits its turn, so the whole Mac feels slow.",
                steps: ["Quit the processes named under the root cause if they are not doing something you want.", "If the same process returns after quitting, check the Startup tab — it may be set to relaunch."],
                rootCause: busyLines.isEmpty ? ["The load was sustained earlier and has since eased."] : busyLines,
                fixes: quitFixes(quittable)))
        }

        // ---- Kernel panics ---------------------------------------------------------------
        let panics = recentReports(matching: { $0.hasSuffix(".panic") || $0.hasPrefix("Kernel-") || $0.hasPrefix("panic-") }, days: 30)
        let extensions = systemExtensions()
        if !panics.isEmpty {
            var cause = extensions.map { "Third-party driver installed: \($0.name) (\($0.bundleID))" }
            if cause.isEmpty { cause = ["No third-party drivers are installed, so the cause is more likely hardware — run Apple Diagnostics."] }
            else { cause.insert("Most kernel panics on Macs trace to a third-party driver or a peripheral. These are the candidates:", at: 0) }
            findings.append(HealthFinding(
                id: "panics", category: .hardware, severity: panics.count >= 3 ? .critical : .warning,
                title: "The Mac crashed completely \(panics.count) time\(panics.count == 1 ? "" : "s") this month",
                summary: "A kernel panic is the whole system stopping, not one app.",
                why: "Panics come from the lowest level of the system: a driver, a faulty peripheral, or failing hardware. Repeated ones lose work and can damage files.",
                steps: ["Update or remove the third-party drivers named under the root cause, one at a time, and see whether the panics stop.", "Unplug hubs, docks and adapters and reconnect them one by one.", "Run Apple Diagnostics: shut down, hold the power button until startup options appear, then press Command-D.", "If panics continue with nothing attached and no third-party drivers, the fault is hardware and needs Apple."],
                rootCause: cause,
                evidence: panics.map { ($0 as NSString).lastPathComponent },
                fixes: [HealthFix(label: "Show panic reports", icon: "folder", confirmation: nil,
                                  action: .reveal("/Library/Logs/DiagnosticReports"))]))
        }

        // ---- Shutdown stalls ----------------------------------------------------------------
        let stalls = recentReports(matching: { $0.hasPrefix("shutdown_stall") }, days: 30)
        if stalls.count >= 2 {
            findings.append(HealthFinding(
                id: "shutdown-stalls", category: .hardware, severity: .info,
                title: "Shutting down stalled \(stalls.count) times this month",
                summary: "Something refused to quit when the Mac was shutting down or restarting.",
                why: "macOS waits for every process to exit before powering off. When one hangs, shutdown stalls until the system gives up and forces it — which is how unsaved state gets lost.",
                steps: ["Open the Startup tab and look at the items marked Always running — those are relaunched whenever they exit and are the usual culprits.", "Disable the ones you do not need.", "If it keeps happening, the report names the process: open one in Console to read it."],
                rootCause: ["Each stall produced a report at the times listed below. Background services set to keep themselves alive are the common cause, because they restart while the system is trying to stop them."],
                evidence: stalls.map { ($0 as NSString).lastPathComponent },
                fixes: [
                    HealthFix(label: "Open Startup", icon: "power", confirmation: nil, action: .navigate(.startup)),
                    HealthFix(label: "Show reports", icon: "folder", confirmation: nil, action: .reveal("/Library/Logs/DiagnosticReports")),
                ]))
        }

        // ---- Drivers waiting for approval -------------------------------------------------------
        let waiting = extensions.filter { $0.state.contains("waiting") }
        if !waiting.isEmpty {
            findings.append(HealthFinding(
                id: "extensions-waiting", category: .hardware, severity: .info,
                title: "\(waiting.count) driver\(waiting.count == 1 ? " is" : "s are") installed but not approved",
                summary: waiting.map { $0.name }.joined(separator: ", "),
                why: "A system extension that is waiting for approval is not running, so whatever hardware or feature it supports will not work — and macOS will keep prompting about it.",
                steps: ["Press “Open Login Items & Extensions”.", "Either allow the extension if you use that device, or uninstall the app it came with."],
                rootCause: waiting.map { "\($0.name) (\($0.bundleID)) is in the state “\($0.state)”." },
                fixes: [HealthFix(label: "Open Login Items & Extensions", icon: "puzzlepiece", confirmation: nil,
                                  action: .openURL("x-apple.systempreferences:com.apple.LoginItems-Settings.extension"))]))
        }

        // ---- Wi-Fi signal ----------------------------------------------------------------------------
        let airport = Shell.run("/usr/sbin/system_profiler", ["SPAirPortDataType"]).out
        if let signalText = value(after: "Signal / Noise:", in: airport) {
            // "-57 dBm / -95 dBm"
            let numbers = signalText.components(separatedBy: CharacterSet(charactersIn: "0123456789-").inverted)
                .compactMap { Int($0) }
            if numbers.count >= 2 {
                let signal = numbers[0], noise = numbers[1]
                if signal < -70 {
                    findings.append(HealthFinding(
                        id: "wifi", category: .hardware, severity: signal < -80 ? .warning : .info,
                        title: "Wi-Fi signal is weak",
                        summary: "\(signal) dBm with \(noise) dBm of noise.",
                        why: "Below about −70 dBm the connection slows and drops. It looks like a slow Mac or slow internet, and is neither.",
                        steps: ["Move closer to the router, or move the router higher and into the open.", "Switch to the 5 GHz or 6 GHz network if the router offers one.", "If the signal is weak right next to the router, the Mac's antenna or the router is at fault."],
                        rootCause: ["Signal \(signal) dBm, noise \(noise) dBm — a margin of \(signal - noise) dB. Healthy is −65 dBm or better.",
                                    (value(after: "Channel:", in: airport)).map { "Connected on channel \($0)." } ?? "Channel unknown."]))
                }
            }
        }

        // ---- Uptime -----------------------------------------------------------------------------------
        let boot = Shell.sysctl("kern.boottime")
        if let range = boot.range(of: "sec = "),
           let seconds = Double(boot[range.upperBound...].prefix { $0.isNumber }) {
            let days = Int((Date().timeIntervalSince1970 - seconds) / 86_400)
            if days >= 14 {
                findings.append(HealthFinding(
                    id: "uptime", category: .hardware, severity: .info,
                    title: "Not restarted for \(days) days",
                    summary: "A restart clears swap, stuck processes and pending updates.",
                    why: "Long uptimes let memory leaks and stale background processes accumulate. Many updates also wait for a restart to finish installing.",
                    steps: ["Save your work.", "Choose Apple menu › Restart."],
                    rootCause: ["The Mac last started \(days) days ago."]))
            }
        }

        return findings
    }

    // MARK: - Software

    static func checkSoftware(inputs: HealthInputs) -> [HealthFinding] {
        var findings: [HealthFinding] = []

        // Pending macOS updates, as recorded by the system's own last check.
        if let prefs = NSDictionary(contentsOfFile: "/Library/Preferences/com.apple.SoftwareUpdate.plist"),
           let updates = prefs["RecommendedUpdates"] as? [[String: Any]], !updates.isEmpty {
            let names = updates.compactMap { $0["Display Name"] as? String }
            findings.append(HealthFinding(
                id: "updates", category: .software, severity: .warning,
                title: "\(updates.count) macOS update\(updates.count == 1 ? "" : "s") waiting",
                summary: names.prefix(3).joined(separator: ", "),
                why: "Updates carry security fixes. Most real-world attacks on Macs use flaws that already had an update available.",
                steps: ["Press “Open Software Update”.", "Install what is offered. Allow time for a restart."],
                command: "softwareupdate --list",
                evidence: names,
                fixes: [HealthFix(label: "Open Software Update", icon: "arrow.down.circle", confirmation: nil,
                                  action: .openURL("x-apple.systempreferences:com.apple.Software-Update-Settings.extension"))]))
        }

        // Apps that crashed repeatedly this week.
        let crashes = recentCrashes(days: 7)
        let repeatOffenders = crashes.filter { $0.count >= 3 }
        if !repeatOffenders.isEmpty {
            findings.append(HealthFinding(
                id: "crashes", category: .software, severity: .warning,
                title: "\(repeatOffenders.count) app\(repeatOffenders.count == 1 ? " keeps" : "s keep") crashing",
                summary: repeatOffenders.prefix(4).map { "\($0.name) ×\($0.count)" }.joined(separator: ", "),
                why: "An app that crashes several times in a week usually has a damaged install, a bad plugin or an available update that fixes it.",
                steps: ["Update the app first — most repeat crashes are already fixed in a newer version.", "If it still crashes, remove it from the Applications tab (which also clears its support files) and install it fresh.", "Press “Show crash reports” to see the reports themselves."],
                evidence: repeatOffenders.map { "\($0.name): \($0.count) reports in 7 days" },
                fixes: [
                    HealthFix(label: "Show crash reports", icon: "folder", confirmation: nil,
                              action: .reveal(NSHomeDirectory() + "/Library/Logs/DiagnosticReports")),
                    HealthFix(label: "Open Applications", icon: "square.grid.2x2", confirmation: nil, action: .navigate(.apps)),
                ]))
        }

        // A process pinned near a full core for a long time.
        let runaways = runawayProcesses()
        for process in runaways {
            findings.append(HealthFinding(
                id: "runaway-\(process.pid)", category: .software, severity: .warning,
                title: "\(process.name) is using \(Int(process.cpu))% CPU",
                summary: "It has been running for \(process.elapsed) at that level.",
                why: "A process stuck at high CPU drains the battery, heats the Mac and slows everything else. Sometimes it is real work; often it is a hang.",
                steps: ["If you are not waiting on it, press “Quit process”. It is asked to close, so it can save first.", "If it comes straight back, look for it under Startup items."],
                command: "kill \(process.pid)",
                evidence: ["PID \(process.pid) — \(process.path)"],
                fixes: [HealthFix(label: "Quit process", icon: "xmark.circle",
                                  confirmation: "\(process.name) (PID \(process.pid)) will be asked to quit. Unsaved work in it may be lost.",
                                  action: .quitProcesses([process.pid]), destructive: true)]))
        }

        // Backups: either Time Machine or this app's own.
        let timeMachine = Shell.run("/usr/bin/tmutil", ["destinationinfo"])
        let hasTimeMachine = !(timeMachine.out + timeMachine.err).contains("No destinations")
        let recentOwnBackup = inputs.lastBackup.map { Date().timeIntervalSince($0) < 14 * 86_400 } ?? false
        if !hasTimeMachine && !recentOwnBackup {
            findings.append(HealthFinding(
                id: "no-backup", category: .software, severity: .warning,
                title: inputs.lastBackup == nil ? "This Mac has no backup" : "The last backup is more than two weeks old",
                summary: inputs.lastBackup.map { "Last backed up \(Fmt.relative($0).lowercased())." }
                    ?? "Time Machine is not set up and no Mac Manager backup has run.",
                why: "Without a backup, a failed drive, a theft or a mistaken deletion is permanent. It is the one problem here that cannot be fixed afterwards.",
                steps: ["Connect an external drive.", "Press “Go to Backup”, choose folders, preview, then back up.", "Or set up Time Machine for a whole-system backup."],
                fixes: [
                    HealthFix(label: "Go to Backup", icon: "externaldrive", confirmation: nil, action: .navigate(.backup)),
                    HealthFix(label: "Time Machine settings", icon: "clock.arrow.circlepath", confirmation: nil,
                              action: .openURL("x-apple.systempreferences:com.apple.Time-Machine-Settings.extension")),
                ]))
        }

        return findings
    }

    struct CrashCount { let name: String; let count: Int }

    /// Crash and hang reports for user-facing apps, grouped by app. System
    /// telemetry files share the folder and are not crashes, so they are
    /// filtered out by name.
    static func recentCrashes(days: Int, directory: String = NSHomeDirectory() + "/Library/Logs/DiagnosticReports") -> [CrashCount] {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let noise = ["ResetCounter", "disk writes", "proactive_event_tracker", "SFA-", "JetsamEvent",
                     "cpu_resource", "Analytics", "xp_amp", "log-"]
        var counts: [String: Int] = [:]

        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        for name in names {
            let ext = (name as NSString).pathExtension
            guard ["ips", "crash", "hang", "spin"].contains(ext) else { continue }
            if noise.contains(where: { name.contains($0) }) { continue }

            let path = directory + "/" + name
            guard let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                  modified >= cutoff else { continue }

            // "Microsoft Outlook-2026-11-12-101500.ips" -> "Microsoft Outlook"
            var app = name
            if let range = app.range(of: "[-_][0-9]{4}-[0-9]{2}-[0-9]{2}", options: .regularExpression) {
                app = String(app[app.startIndex ..< range.lowerBound])
            }
            counts[app, default: 0] += 1
        }

        return counts.map { CrashCount(name: $0.key, count: $0.value) }.sorted { $0.count > $1.count }
    }

    struct Runaway { let pid: Int32; let name: String; let path: String; let cpu: Double; let elapsed: String }

    /// Processes above 85% of a core that have been running at least ten
    /// minutes. The window server and kernel are excluded: they are busy when
    /// the machine is busy, and quitting them is not a fix.
    static func runawayProcesses() -> [Runaway] {
        let output = Shell.run("/bin/ps", ["-Ao", "pid,pcpu,etime,comm", "-r"]).out
        let ignored = ["WindowServer", "kernel_task", "MacManager", "mds_stores", "mdworker"]
        var found: [Runaway] = []

        for (index, line) in output.components(separatedBy: .newlines).enumerated() {
            if index == 0 { continue }
            let fields = line.whitespaceFields
            guard fields.count >= 4, let pid = Int32(fields[0]), let cpu = Double(fields[1]) else { continue }
            if cpu < 85 { break }  // sorted by CPU, so nothing further qualifies

            let path = fields[3...].joined(separator: " ")
            let name = (path as NSString).lastPathComponent
            if ignored.contains(where: { name.contains($0) }) { continue }
            if elapsedSeconds(fields[2]) < 600 { continue }

            found.append(Runaway(pid: pid, name: name, path: path, cpu: cpu, elapsed: fields[2]))
        }
        return Array(found.prefix(3))
    }

    /// ps prints elapsed time as [[dd-]hh:]mm:ss.
    static func elapsedSeconds(_ text: String) -> Int {
        var days = 0
        var rest = text
        if let dash = text.firstIndex(of: "-") {
            days = Int(text[text.startIndex ..< dash]) ?? 0
            rest = String(text[text.index(after: dash)...])
        }
        let parts = rest.components(separatedBy: ":").compactMap { Int($0) }
        var seconds = 0
        for part in parts { seconds = seconds * 60 + part }
        return days * 86_400 + seconds
    }

    // MARK: - Startup

    static func checkStartup(items: [LaunchItem]) -> [HealthFinding] {
        var findings: [HealthFinding] = []

        // Left behind by uninstalled apps: launchd keeps trying to start a
        // program that is no longer there.
        let broken = items.filter { $0.programMissing && knownBadLabels[$0.label] == nil }
        let byVendor = Dictionary(grouping: broken, by: { $0.vendorKey })

        for (vendor, group) in byVendor.sorted(by: { $0.value.count > $1.value.count }) {
            let needsAdmin = group.contains { $0.isSystem }
            findings.append(HealthFinding(
                id: "broken-" + vendor,
                category: .startup,
                severity: .warning,
                title: "\(group.count) leftover startup item\(group.count == 1 ? "" : "s") from \(vendor)",
                summary: "\(group.count == 1 ? "It points" : "They point") to a program that is no longer installed.",
                why: "When an app is removed by dragging it to the Trash, its startup entries stay behind. macOS keeps trying to launch a program that does not exist — at every login, and for items marked keep-alive, every few seconds. It costs a little performance and clutters the logs.",
                steps: [
                    "Press “Disable”. Each job is stopped and its file moved to quarantine, not deleted." + (needsAdmin ? " macOS asks for your password once because these apply to every user." : ""),
                    "If something stops working afterwards, the files are in the quarantine folder and can be moved back.",
                ],
                command: group.map { ($0.isSystem ? "sudo " : "") + "rm \(shellQuote($0.path))" }.joined(separator: "\n"),
                evidence: group.map { "\($0.fileName)  →  \($0.program ?? "?")" },
                fixes: [HealthFix(label: "Disable", icon: "power",
                                  confirmation: "\(group.count) startup file\(group.count == 1 ? "" : "s") from \(vendor) will be stopped and moved to quarantine. Nothing is deleted." + (needsAdmin ? " macOS will ask for your password." : ""),
                                  action: .quarantine(group.map { $0.quarantineItem }), destructive: true)]))
        }

        let atLogin = items.filter { $0.runAtLoad && !$0.programMissing }
        if atLogin.count > 12 {
            let vendors = Dictionary(grouping: atLogin, by: { $0.vendorKey })
                .map { "\($0.key) (\($0.value.count))" }.sorted()
            findings.append(HealthFinding(
                id: "startup-load", category: .startup, severity: .info,
                title: "\(atLogin.count) background items start with this Mac",
                summary: "Each one adds to startup time and memory use.",
                why: "Updaters and helpers install themselves to run at login. Individually they are small; together they are a common reason a Mac feels slow just after starting.",
                steps: ["Press “Open Login Items”.", "Under “Allow in the Background”, switch off anything you do not need running all the time.", "Updaters are generally safe to switch off — the app will still update when you open it."],
                evidence: vendors,
                fixes: [HealthFix(label: "Open Login Items", icon: "list.bullet", confirmation: nil,
                                  action: .openURL("x-apple.systempreferences:com.apple.LoginItems-Settings.extension"))]))
        }

        return findings
    }

    // MARK: - Ports

    static func checkPorts(inputs: HealthInputs) -> [HealthFinding] {
        let exposed = inputs.ports.filter { $0.isExposed }
        if exposed.isEmpty {
            return [HealthFinding(
                id: "ports-ok", category: .network, severity: .ok,
                title: "No ports are reachable from your network",
                summary: "\(inputs.ports.count) listening, all limited to this Mac.",
                why: "Ports bound to localhost can only be reached by programs on this Mac.",
                steps: ["Nothing to do."])]
        }

        return [HealthFinding(
            id: "ports-exposed", category: .network, severity: .info,
            title: "\(exposed.count) port\(exposed.count == 1 ? " is" : "s are") reachable from your network",
            summary: exposed.prefix(4).map { "\($0.port) (\($0.processName))" }.joined(separator: ", "),
            why: "A port bound to all interfaces accepts connections from any device on the same network. That is intended for things like AirPlay and file sharing, and unintended for a development server you forgot was running.",
            steps: ["Press “Open Ports” to see each one and which program owns it.", "Quit any you do not recognise or need.", "AirPlay Receiver (ports 5000 and 7000) can be switched off in System Settings › General › AirDrop & Handoff."],
            command: "lsof -nP -iTCP -sTCP:LISTEN",
            evidence: exposed.map { "port \($0.port) — \($0.processName) (PID \($0.pid))" },
            fixes: [HealthFix(label: "Open Ports", icon: "network", confirmation: nil, action: .navigate(.ports))])]
    }

    // MARK: - Cleanup

    static func checkCleanup(inputs: HealthInputs) -> [HealthFinding] {
        var findings: [HealthFinding] = []

        if inputs.reclaimableBytes > 500_000_000 {
            findings.append(HealthFinding(
                id: "caches", category: .cleanup, severity: .info,
                title: "\(Fmt.bytes(inputs.reclaimableBytes)) of caches can be cleared",
                summary: "Caches and build leftovers that rebuild themselves.",
                why: "These folders are regenerated on demand. Clearing them costs a slower first launch and nothing else.",
                steps: ["Press “Reclaim caches”. Everything goes to the Trash.", "Empty the Trash to get the space back."],
                fixes: [HealthFix(label: "Reclaim caches", icon: "sparkles",
                                  confirmation: "The contents of every safe cache folder will be moved to the Trash. Protected folders are skipped.",
                                  action: .reclaimCaches)]))
        }

        if inputs.trashBytes > 1_000_000_000 {
            findings.append(HealthFinding(
                id: "trash", category: .cleanup, severity: .info,
                title: "The Trash is holding \(Fmt.bytes(inputs.trashBytes))",
                summary: "That space is not free until the Trash is emptied.",
                why: "Deleted files stay on disk until the Trash is emptied. Mac Manager never empties it for you, because that is the one step that cannot be undone.",
                steps: ["Press “Open Trash” and check nothing in it is needed.", "Choose Finder › Empty Trash."],
                fixes: [HealthFix(label: "Open Trash", icon: "trash", confirmation: nil,
                                  action: .reveal(NSHomeDirectory() + "/.Trash"))]))
        }

        // Old diagnostic reports have no use once the problem has passed.
        let reportsDirectory = NSHomeDirectory() + "/Library/Logs/DiagnosticReports"
        let old = oldFiles(in: reportsDirectory, olderThanDays: 30)
        if old.count >= 20 {
            findings.append(HealthFinding(
                id: "old-reports", category: .cleanup, severity: .info,
                title: "\(old.count) diagnostic reports are over a month old",
                summary: "They describe problems that have long since passed.",
                why: "macOS writes a report for every crash and hang and never removes them. Old ones are only clutter.",
                steps: ["Press “Clear old reports”. They go to the Trash."],
                fixes: [HealthFix(label: "Clear old reports", icon: "trash",
                                  confirmation: "\(old.count) diagnostic reports older than 30 days will be moved to the Trash.",
                                  action: .trash(old))]))
        }

        return findings
    }

    static func oldFiles(in directory: String, olderThanDays days: Int) -> [String] {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        var result: [String] = []
        for name in names {
            let path = directory + "/" + name
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                  modified < cutoff else { continue }
            result.append(path)
        }
        return result
    }

    // MARK: - Fixes

    static var quarantineRoot: String {
        return StateStore.directory.path + "/Quarantine"
    }

    /// The shell commands that stop each job and move its file aside.
    ///
    /// Files are moved, never deleted, and renamed to their full original path
    /// so that two files with the same name cannot collide and each one records
    /// where it came from.
    static func quarantineScript(items: [QuarantineItem], destination: String,
                                 user: String = NSUserName(), uid: uid_t = getuid()) -> String {
        var lines = ["mkdir -p \(shellQuote(destination))"]
        for item in items {
            if let label = item.label {
                // Agents in /Library run in the user's session and daemons in
                // the system one, so an item there is stopped in both.
                lines.append("launchctl bootout gui/\(uid)/\(shellQuote(label)) 2>/dev/null || true")
                if item.isSystem {
                    lines.append("launchctl bootout system/\(shellQuote(label)) 2>/dev/null || true")
                }
            }
            let flattened = item.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .replacingOccurrences(of: "/", with: "__")
            lines.append("if [ -e \(shellQuote(item.path)) ]; then mv -f \(shellQuote(item.path)) \(shellQuote(destination + "/" + flattened)); fi")
        }
        // Root-owned files would otherwise be undeletable by their owner.
        lines.append("chown -R \(shellQuote(user)) \(shellQuote(destination)) 2>/dev/null || true")
        return lines.joined(separator: "; ")
    }

    /// True when any file sits somewhere the current user cannot modify.
    static func needsAdministrator(_ items: [QuarantineItem]) -> Bool {
        return items.contains { item in
            item.isSystem || !FileManager.default.isWritableFile(
                atPath: (item.path as NSString).deletingLastPathComponent)
        }
    }

    /// Runs a quarantine. With system items this goes through the standard
    /// macOS administrator prompt; the password is typed into Apple's dialog
    /// and never passes through this app.
    func quarantine(_ items: [QuarantineItem], completion: @escaping (String) -> Void) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        let destination = HealthScanner.quarantineRoot + "/" + formatter.string(from: Date())
        let script = HealthScanner.quarantineScript(items: items, destination: destination)
        let admin = HealthScanner.needsAdministrator(items)

        work.async {
            let result: Shell.Result
            if admin {
                let escaped = script.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                result = Shell.osascript("do shell script \"\(escaped)\" with prompt \"Mac Manager needs your password to disable startup items.\" with administrator privileges")
            } else {
                result = Shell.run("/bin/sh", ["-c", script])
            }

            let remaining = items.filter { FileManager.default.fileExists(atPath: $0.path) }
            DispatchQueue.main.async {
                let message: String
                if remaining.isEmpty {
                    message = "Moved \(items.count) item\(items.count == 1 ? "" : "s") to quarantine. Nothing was deleted."
                } else if result.err.contains("User canceled") || result.err.contains("-128") {
                    message = "Cancelled — nothing was changed."
                } else {
                    message = "\(items.count - remaining.count) of \(items.count) moved. \(remaining.count) could not be moved."
                }
                self.lastFixMessage = message
                completion(message)
            }
        }
    }

    func note(_ message: String) { lastFixMessage = message }

    /// Runs a shell script, through the standard macOS administrator prompt
    /// when asked. The password goes to Apple's dialog, never to this app.
    static func runScript(_ script: String, admin: Bool, prompt: String) -> Shell.Result {
        if !admin { return Shell.run("/bin/sh", ["-c", script]) }
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let safePrompt = prompt.replacingOccurrences(of: "\"", with: "'")
        return Shell.osascript("do shell script \"\(escaped)\" with prompt \"\(safePrompt)\" with administrator privileges")
    }

    // MARK: - Helpers

    static func shellQuote(_ text: String) -> String {
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The trimmed text following a label on its line, e.g. "SMART Status:".
    static func value(after label: String, in text: String) -> String? {
        for line in text.components(separatedBy: .newlines) {
            if let range = line.range(of: label) {
                return line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
