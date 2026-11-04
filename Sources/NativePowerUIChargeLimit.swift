#if !APPSTORE
import Foundation

/// macOS 26.4+/27 manual charge limit (MCL), discovered by inspecting AlDente
/// 1.39.4's PowerUI backend. This uses the system's PowerUISmartChargeClient
/// rather than an SMC adapter cut. It is a PRIVATE API: always probe and read
/// back the resulting limit; never silently claim support below 80%.
enum NativePowerUIChargeLimit {
    struct Status: Sendable, Equatable {
        let supported: Bool
        let enabled: Bool
        let limit: Int
    }

    static let supportedLimits: Set<Int> = [80, 85, 90, 95, 100]

    static func readStatus() async -> Status? {
        guard let output = await execute("status") else { return nil }
        let fields = output.split(separator: "|", omittingEmptySubsequences: false)
        guard fields.count == 4, fields[0] == "ok",
              (fields[1] == "0" || fields[1] == "1"),
              (fields[2] == "0" || fields[2] == "1"),
              let limit = Int(fields[3]), (0...100).contains(limit) else { return nil }
        return Status(supported: fields[1] == "1",
                      enabled: fields[2] == "1", limit: limit)
    }

    static func supports(_ limit: Int) -> Bool { supportedLimits.contains(limit) }

    /// Turn on the firmware-managed limit and confirm both enable state and value.
    /// Apple may temporarily override it for battery calibration; that is not an
    /// excuse to fall back to CHIE cycling.
    static func setLimit(_ limit: Int) async -> Bool {
        guard supports(limit), await execute("set", limit: limit) == "ok",
              let result = await readStatus() else { return false }
        return result.supported && result.enabled && result.limit == limit
    }

    /// Release only a limit owned by MacWake; callers restore any pre-existing
    /// native setting using restore(_:) instead of blindly setting 100%.
    static func release() async -> Bool {
        guard await execute("disable") == "ok",
              let result = await readStatus() else { return false }
        return !result.enabled
    }

    static func restore(_ original: Status) async -> Bool {
        if original.enabled { return await setLimit(original.limit) }
        return await release()
    }

    /// Best effort for app termination; the native limit persists in powerd
    /// independently of MacWake and must not outlive this session accidentally.
    @discardableResult
    static func restoreSynchronously(_ original: Status) -> Bool {
        if original.enabled {
            return executeSynchronously("set", limit: original.limit) == "ok"
        }
        return executeSynchronously("disable", limit: nil) == "ok"
    }

    private static func execute(_ operation: String, limit: Int? = nil) async -> String? {
        await Task.detached(priority: .utility) {
            executeSynchronously(operation, limit: limit)
        }.value
    }

    /// osascript's JavaScript bridge provides a stable ObjC dispatch surface for
    /// selectors discovered in the installed PowerUI.framework. No credentials,
    /// AppleScript GUI automation, sudo, or third-party processes are involved.
    private static func executeSynchronously(_ operation: String, limit: Int?) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", script, operation, String(limit ?? 100)]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + 12, execute: watchdog
        )
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let script = #"""
    ObjC.import("Foundation");
    function run(argv) {
        const bundle = $.NSBundle.bundleWithPath("/System/Library/PrivateFrameworks/PowerUI.framework");
        if (!bundle || !bundle.load) return "error|framework";
        const klass = $.NSClassFromString("PowerUISmartChargeClient");
        if (!klass || klass.isNil()) return "error|class";
        const client = klass.alloc.initWithClientName($("MacWake"));
        if (!client || client.isNil()) return "error|client";
        const action = argv[0];
        const supported = !!client.isMCLSupported;
        const readEnabled = () => Number(client.isMCLCurrentlyEnabled(Ref()));
        const readLimit = () => Number(client.getMCLLimitWithError(Ref()));
        if (action === "status") {
            const state = readEnabled();
            if (state !== 0 && state !== 1) return "error|state";
            return ["ok", supported ? 1 : 0, state, readLimit()].join("|");
        }
        if (!supported) return "error|unsupported";
        if (action === "set") {
            const target = Number(argv[1]);
            if (![80, 85, 90, 95, 100].includes(target)) return "error|range";
            const current = readEnabled();
            if (current !== 0 && current !== 1) return "error|state";
            if (current === 0 && !client.enableMCL(Ref())) return "error|enable";
            if (!client.setMCLLimitError(target, Ref())) return "error|set";
            return readEnabled() === 1 && readLimit() === target ? "ok" : "error|readback";
        }
        if (action === "disable") {
            if (!client.disableMCL(Ref())) return "error|disable";
            return readEnabled() === 0 ? "ok" : "error|readback";
        }
        return "error|action";
    }
    """#
}
#else
import Foundation

/// The App Store sandbox never launches osascript or uses private PowerUI.
enum NativePowerUIChargeLimit {
    struct Status: Sendable, Equatable {
        let supported: Bool
        let enabled: Bool
        let limit: Int
    }
    static func supports(_ limit: Int) -> Bool { false }
    static func readStatus() async -> Status? { nil }
    static func setLimit(_ limit: Int) async -> Bool { false }
    static func restore(_ original: Status) async -> Bool { false }
    @discardableResult
    static func restoreSynchronously(_ original: Status) -> Bool { false }
}
#endif
