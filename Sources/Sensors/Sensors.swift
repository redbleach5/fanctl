/*
 * Sensors.swift — общий модуль чтения сенсоров и общения с fanctld.
 * Используется и CLI (fanctl), и меню-бар приложением (FanBar).
 */
import Foundation
import CSMC

// MARK: - Модели

public struct TempReading: Identifiable, Sendable {
    public let id: String        // SMC-ключ или HID-имя
    public let label: String
    public let value: Double
}

public struct FanReading: Sendable {
    public let index: Int
    public let actual: Double
    public let target: Double
    public let min: Double
    public let max: Double
    public let forced: Int       // 1 = manual, 0 = auto, -1 = неизвестно
}

public struct ProcessMemory: Identifiable, Sendable {
    public let pid: Int32
    public let name: String
    public let path: String
    public let memoryBytes: UInt64

    public var id: Int32 { pid }
    public var memoryGB: Double { Double(memoryBytes) / 1_073_741_824 }
}

public struct Snapshot: Sendable {
    public var fans: [FanReading]
    public var fanError: String?
    public var tempReadFailures: Int
    public var cpu: Double?       // максимум по Tp*
    public var gpu: Double?       // максимум по Tg*
    public var soc: Double?       // максимум по TC*
    public var ssd: Double?       // HID NAND
    public var battery: Double?   // HID gas gauge
    public var maxTemp: Double
    public var maxTempKey: String
    public var cpuPercent: Double
    public var gpuPercent: Double
    public var memUsedGB: Double
    public var memTopUsedGB: Double
    public var memAppGB: Double
    public var memWiredGB: Double
    public var memCompressedGB: Double
    public var memCachedGB: Double
    public var memFreeGB: Double
    public var memAvailablePercent: Double
    public var memTotalGB: Double
    public var swapUsedGB: Double
    public var swapTotalGB: Double
    public var processes: [ProcessMemory]
    public var topSensors: [TempReading]   // hottest первые
}

// MARK: - Датчики

public final class SensorStore: @unchecked Sendable {
    private var conn: OpaquePointer?
    private var tempKeys: [String] = []
    private var lastDiscovery = Date.distantPast
    private var lastProcessUpdate = Date.distantPast
    private var cachedProcesses: [ProcessMemory] = []

    public init?() {
        guard let c = smc_open() else { return nil }
        conn = c
        discoverKeys()
        var metrics = sys_metrics_t()
        _ = metrics_sample(&metrics)
    }

    deinit {
        if let c = conn { smc_close(c) }
    }

    private func discoverKeys() {
        tempKeys = []
        lastDiscovery = Date()
        var total: UInt32 = 0
        guard smc_key_count(conn, &total) == 0 else { return }
        let keyPtr = UnsafeMutablePointer<Int8>.allocate(capacity: 5)
        defer { keyPtr.deallocate() }
        for i in 0..<total {
            guard smc_key_at(conn, i, keyPtr) == 0 else { continue }
            let b0 = UInt8(bitPattern: keyPtr[0])
            guard b0 == UInt8(ascii: "T") else { continue }
            let bytes = (0..<4).map { UInt8(bitPattern: keyPtr[$0]) }
            guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) else { continue }
            let key = String(bytes: bytes, encoding: .ascii) ?? ""
            var v = 0.0
            guard smc_read_double(conn, key, &v) == 0, v.isFinite, v >= 5, v <= 120 else { continue }
            tempKeys.append(key)
        }
    }

    public func snapshot() -> Snapshot {
        var s = Snapshot(fans: [], fanError: nil, tempReadFailures: 0,
                         cpu: nil, gpu: nil, soc: nil, ssd: nil, battery: nil,
                         maxTemp: -1, maxTempKey: "?", cpuPercent: -1, gpuPercent: -1,
                         memUsedGB: -1, memTopUsedGB: -1, memAppGB: -1, memWiredGB: -1,
                         memCompressedGB: -1, memCachedGB: -1, memFreeGB: -1,
                         memAvailablePercent: -1, memTotalGB: 0, swapUsedGB: -1,
                         swapTotalGB: -1, processes: [], topSensors: [])

        // Вентиляторы
        var buf = [smc_fan_t](repeating: smc_fan_t(), count: 8)
        var count: Int32 = 0
        if smc_read_fans(conn, &buf, 8, &count) == 0 {
            s.fans = (0..<Int(count)).map { i in
                let f = buf[i]
                return FanReading(index: Int(f.index), actual: f.actual, target: f.target,
                                  min: f.min, max: f.max, forced: Int(f.mode_forced))
            }
        } else {
            s.fanError = String(cString: smc_last_error())
        }

        if Date().timeIntervalSince(lastDiscovery) >= 60 { discoverKeys() }
        var readings: [TempReading] = []
        readings.reserveCapacity(tempKeys.count + 64)
        var maxTemp = -Double.infinity, maxKey = "?"
        var cpu = -Double.infinity, gpu = -Double.infinity, soc = -Double.infinity
        for key in tempKeys {
            var value = 0.0
            guard smc_read_double(conn, key, &value) == 0,
                  value.isFinite, value >= 5, value <= 120 else {
                s.tempReadFailures += 1
                continue
            }
            readings.append(TempReading(id: key, label: key, value: value))
            if key.hasPrefix("Tp") { cpu = max(cpu, value) }
            if key.hasPrefix("Tg") { gpu = max(gpu, value) }
            if key.hasPrefix("TC") { soc = max(soc, value) }
            if value > maxTemp { maxTemp = value; maxKey = key }
        }
        if cpu > -Double.infinity { s.cpu = cpu }
        if gpu > -Double.infinity { s.gpu = gpu }
        if soc > -Double.infinity { s.soc = soc }

        var hid = [hid_temp_t](repeating: hid_temp_t(), count: 128)
        let hidCount = Int(hid_read_temps(&hid, 128))
        var ssd = -Double.infinity, battery = -Double.infinity
        for i in 0..<hidCount {
            let name = withUnsafeBytes(of: hid[i].name) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            let value = hid[i].celsius
            guard value.isFinite else { continue }
            readings.append(TempReading(id: "HID:\(i):\(name)", label: name, value: value))
            if name.lowercased().contains("nand"), value > ssd { ssd = value }
            if name.lowercased().contains("battery"), value > battery { battery = value }
            if value > maxTemp { maxTemp = value; maxKey = name }
        }
        if ssd > -Double.infinity { s.ssd = ssd }
        if battery > -Double.infinity { s.battery = battery }
        if maxTemp > -Double.infinity { s.maxTemp = maxTemp; s.maxTempKey = maxKey }
        s.topSensors = readings.sorted { $0.value > $1.value }

        // Система
        var m = sys_metrics_t()
        if metrics_sample(&m) == 0 {
            s.cpuPercent = m.cpu_percent
            s.gpuPercent = m.gpu_percent
            s.memUsedGB = m.mem_used_gb
            s.memTopUsedGB = m.mem_top_used_gb
            s.memAppGB = m.mem_app_gb
            s.memWiredGB = m.mem_wired_gb
            s.memCompressedGB = m.mem_compressed_gb
            s.memCachedGB = m.mem_cached_gb
            s.memFreeGB = m.mem_free_gb
            s.memAvailablePercent = m.mem_available_percent
            s.memTotalGB = m.mem_total_gb
            s.swapUsedGB = m.swap_used_gb
            s.swapTotalGB = m.swap_total_gb
        }
        if Date().timeIntervalSince(lastProcessUpdate) >= 5 {
            cachedProcesses = readTopProcesses()
            lastProcessUpdate = Date()
        }
        s.processes = cachedProcesses
        return s
    }

    private func readTopProcesses() -> [ProcessMemory] {
        var buffer = [process_memory_t](repeating: process_memory_t(), count: 16)
        let count = Int(metrics_top_processes(&buffer, 16))
        guard count > 0 else { return [] }
        return (0..<count).map { i in
            let process = buffer[i]
            let name = withUnsafeBytes(of: process.name) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            let path = withUnsafeBytes(of: process.path) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            return ProcessMemory(pid: process.pid, name: name, path: path,
                                 memoryBytes: process.memory_bytes)
        }
    }
}

// MARK: - Клиент демона

public enum DaemonError: LocalizedError {
    case notRunning
    case badResponse
    case cancelled
    case remote(String)

    public var errorDescription: String? {
        switch self {
        case .notRunning: return "Демон не запущен"
        case .badResponse: return "Некорректный ответ демона"
        case .cancelled: return "Ввод пароля отменён"
        case .remote(let message): return message
        }
    }
}

public struct DaemonStatus: Sendable {
    public var mode: String
    public var userTarget: Double
    public var warn: Double
    public var critical: Double
    public var maxTemp: Double
    public var maxTempKey: String
    public var pid: Int
    public var sensorFault: Bool
    public var fanFault: Bool
    public var controlFault: Bool
    public var validTempCount: Int
    public var failedTempCount: Int
    public var error: String?
}

public enum DaemonClient {
    public static let socketPath = "/var/run/fanctl.sock"

    public static func request(_ dict: [String: Any],
                               socketPath: String = socketPath,
                               timeoutMs: Int = 1500) throws -> [String: Any] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DaemonError.notRunning }
        defer { close(fd) }

        var tv = timeval(tv_sec: timeoutMs / 1000, tv_usec: Int32((timeoutMs % 1000) * 1000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        guard socketPath.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw DaemonError.notRunning
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in socketPath.utf8.enumerated() { buf[i] = b }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let res = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        guard res == 0 else { throw DaemonError.notRunning }

        guard var data = try? JSONSerialization.data(withJSONObject: dict) else {
            throw DaemonError.badResponse
        }
        data.append(0x0a)
        let written = data.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, MSG_NOSIGNAL) }
        guard written == data.count else { throw DaemonError.badResponse }

        var response = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while response.count < 65_536 {
            let n = read(fd, &buf, buf.count)
            guard n > 0 else { break }
            response.append(contentsOf: buf[0..<n])
            if response.contains(UInt8(ascii: "\n")) { break }
        }
        guard let obj = try? JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            throw DaemonError.badResponse
        }
        guard obj["ok"] as? Int == 1 || obj["ok"] as? Bool == true else {
            throw DaemonError.remote(obj["error"] as? String ?? "Команда отклонена демоном")
        }
        return obj
    }

    public static func isRunning() -> Bool {
        (try? request(["cmd": "ping"])) != nil
    }

    public static func status() -> DaemonStatus? {
        guard let o = try? request(["cmd": "status"]) else { return nil }
        return DaemonStatus(
            mode: o["mode"] as? String ?? "auto",
            userTarget: (o["userTarget"] as? Double) ?? 0,
            warn: (o["warn"] as? Double) ?? 85,
            critical: (o["critical"] as? Double) ?? 95,
            maxTemp: (o["maxTemp"] as? Double) ?? 0,
            maxTempKey: o["maxTempKey"] as? String ?? "?",
            pid: (o["pid"] as? Int) ?? 0,
            sensorFault: (o["sensorFault"] as? Bool) ?? false,
            fanFault: (o["fanFault"] as? Bool) ?? false,
            controlFault: (o["controlFault"] as? Bool) ?? false,
            validTempCount: (o["validTempCount"] as? Int) ?? 0,
            failedTempCount: (o["failedTempCount"] as? Int) ?? 0,
            error: o["error"] as? String
        )
    }

    public static func set(rpm: Double) throws {
        _ = try request(["cmd": "set", "rpm": rpm])
    }

    public static func auto() throws {
        _ = try request(["cmd": "auto"])
    }

    public static func quit() throws {
        _ = try request(["cmd": "quit"])
    }

    /// Путь к бинарнику fanctld: внутри .app, рядом с исполняемым файлом или в /usr/local/bin.
    public static func daemonBinaryPath() -> String? {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let dir = exe.deletingLastPathComponent()
        var candidates: [String] = []
        if let bundled = Bundle.main.path(forResource: "fanctld", ofType: nil) {
            candidates.append(bundled)
        }
        candidates.append(contentsOf: [
            dir.appendingPathComponent("fanctld").path,
            "/usr/local/bin/fanctld",
        ])
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        return nil
    }

    /// Запуск демона с запросом пароля администратора (диалог macOS).
    public static func startWithAdminPassword() throws {
        let launchDaemonPath = "/Library/LaunchDaemons/local.fanbar.fanctld.plist"
        let script: String
        if FileManager.default.fileExists(atPath: launchDaemonPath) {
            script = "launchctl bootstrap system \(launchDaemonPath) 2>/dev/null || true; " +
                "launchctl kickstart -k system/local.fanbar.fanctld"
        } else {
            guard let bin = daemonBinaryPath() else { throw DaemonError.notRunning }
            let quoted = "'\(bin.replacingOccurrences(of: "'", with: "'\\''"))'"
            script = "(\(quoted) </dev/null >/tmp/fanctld.log 2>&1 &)"
        }
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let osa = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")
        var err: NSDictionary?
        osa?.executeAndReturnError(&err)
        if let err {
            // код -128 = пользователь отменил ввод пароля
            let code = (err[NSAppleScript.errorNumber] as? Int) ?? 0
            if code == -128 { throw DaemonError.cancelled }
            FileHandle.standardError.write(Data("fanctld start failed: \(err)\n".utf8))
            throw DaemonError.badResponse
        }
        // ждём появления сокета
        for _ in 0..<30 {
            if isRunning() { return }
            usleep(100_000)
        }
        throw DaemonError.notRunning
    }
}
