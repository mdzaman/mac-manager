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

    static func checkHardware(inputs: HealthInputs) -> [HealthFinding] {
        var findings: [HealthFinding] = []

        // Battery — absent on desktops, in which case the section is skipped.
        let power = Shell.run("/usr/sbin/system_profiler", ["SPPowerDataType"]).out
        if let capacityText = value(after: "Maximum Capacity:", in: power),
           let capacity = Int(capacityText.replacingOccurrences(of: "%", with: "")) {
            let condition = value(after: "Condition:", in: power) ?? "Unknown"
            let cycles = value(after: "Cycle Count:", in: power) ?? "?"
            let healthy = capacity >= 80 && condition == "Normal"
            findings.append(HealthFinding(
                id: "battery", category: .hardware,
                severity: healthy ? .ok : (capacity < 70 || condition != "Normal" ? .warning : .info),
                title: healthy ? "Battery is healthy" : "Battery is wearing out",
                summary: "\(capacity)% of original capacity · \(cycles) charge cycles · condition \(condition)",
                why: "Batteries lose capacity with use. Apple considers a battery worn below 80% of its original capacity, and most MacBook batteries are rated for 1,000 cycles.",
                steps: healthy
                    ? ["Nothing to do. Keeping Optimised Battery Charging on slows further wear."]
                    : ["Press “Open Battery settings” and check Battery Health.", "Turn on Optimised Battery Charging if it is off.", "If the condition reads Service Recommended, book a battery replacement with Apple."],
                fixes: healthy ? [] : [HealthFix(label: "Open Battery settings", icon: "battery.75", confirmation: nil,
                                                action: .openURL("x-apple.systempreferences:com.apple.Battery-Settings.extension"))]))
        }

        let disk = Shell.run("/usr/sbin/diskutil", ["info", "/"]).out
        if let smart = value(after: "SMART Status:", in: disk) {
            let verified = smart == "Verified"
            if !verified && smart != "Not Supported" {
                findings.append(HealthFinding(
                    id: "smart", category: .hardware, severity: .critical,
                    title: "The startup disk is reporting a hardware problem",
                    summary: "SMART status: \(smart)",
                    why: "SMART is the drive's own self-diagnosis. Anything other than Verified means the drive expects to fail, and drives that say so usually do.",
                    steps: ["Back up everything important now — use the Backup tab.", "Do not wait for symptoms.", "Contact Apple or a repair provider about replacing the drive."],
                    fixes: [HealthFix(label: "Go to Backup", icon: "externaldrive", confirmation: nil, action: .navigate(.backup))]))
            } else if verified {
                findings.append(HealthFinding(
                    id: "smart", category: .hardware, severity: .ok,
                    title: "Startup disk hardware is healthy",
                    summary: "SMART status: Verified",
                    why: "The drive's own self-diagnosis reports no problems.",
                    steps: ["Nothing to do."]))
            }
        }

        let free = inputs.volume.totalBytes > 0
            ? Double(inputs.volume.availableBytes) / Double(inputs.volume.totalBytes) : 1
        if inputs.volume.totalBytes > 0 && free < 0.20 {
            findings.append(HealthFinding(
                id: "disk-space", category: .hardware, severity: free < 0.10 ? .critical : .warning,
                title: free < 0.10 ? "The disk is almost full" : "Disk space is running low",
                summary: "\(Fmt.bytes(inputs.volume.availableBytes)) free of \(Fmt.bytes(inputs.volume.totalBytes))",
                why: "macOS needs free space for swap, updates and temporary files. Below about 10% free, apps slow down, updates fail and files can be lost when a save cannot complete.",
                steps: ["Press “Reclaim caches” to clear what rebuilds itself.", "Open Storage to see the largest folders.", "Open Growth to see what was added recently, and Duplicates for identical copies."],
                fixes: [
                    HealthFix(label: "Reclaim caches", icon: "sparkles",
                              confirmation: "The contents of every safe cache folder will be moved to the Trash. Protected folders are skipped.",
                              action: .reclaimCaches),
                    HealthFix(label: "Open Storage", icon: "internaldrive", confirmation: nil, action: .navigate(.storage)),
                ]))
        }

        if inputs.memory.pressureLevel != .normal || inputs.memory.swapUsedBytes > 4_000_000_000 {
            let pressured = inputs.memory.pressureLevel != .normal
            findings.append(HealthFinding(
                id: "memory", category: .hardware, severity: pressured ? .warning : .info,
                title: pressured ? "Memory is under pressure" : "Heavy swap use",
                summary: "\(Fmt.bytes(inputs.memory.usedBytes)) in use of \(Fmt.bytes(inputs.memory.totalBytes)) · \(Fmt.bytes(inputs.memory.swapUsedBytes)) swapped to disk",
                why: "When memory runs short, macOS moves it to disk. That keeps things running but makes everything slower and wears the SSD.",
                steps: ["Open Memory to see which apps hold the most.", "Quit the largest ones you are not using — browsers with many tabs are the usual cause.", "If this is constant, restarting clears swap."],
                fixes: [HealthFix(label: "Open Memory", icon: "memorychip", confirmation: nil, action: .navigate(.memory))]))
        }

        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical:
            findings.append(HealthFinding(
                id: "thermal", category: .hardware, severity: .warning,
                title: "The Mac is running hot",
                summary: "macOS is throttling performance to cool down.",
                why: "Under thermal pressure the system slows the processor. It usually means something is using the CPU heavily, or the vents are blocked.",
                steps: ["Open Memory, sort by CPU, and quit whatever is at the top.", "Move the Mac off soft surfaces so air can flow."],
                fixes: [HealthFix(label: "Open Memory", icon: "memorychip", confirmation: nil, action: .navigate(.memory))]))
        default:
            break
        }

        // kern.boottime prints "{ sec = 1794651233, usec = ... }".
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
                    steps: ["Save your work.", "Choose Apple menu › Restart."]))
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
                let domain = item.isSystem ? "system" : "gui/\(uid)"
                lines.append("launchctl bootout \(domain)/\(shellQuote(label)) 2>/dev/null || true")
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
