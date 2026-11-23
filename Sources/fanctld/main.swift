/*
 * fanctld — демон плавного управления вентиляторами и аварийной защиты.
 * Запускается через LaunchDaemon или вручную от root: sudo fanctld
 *
 * Режимы:
 *   auto      — SMC сам управляет (по умолчанию, безопасно)
 *   manual    — целевые обороты заданы клиентом, плавное нарастание (slew)
 *   emergency — критическая температура: принудительно максимум
 *
 * Протокол: unix-сокет, JSON построчно.
 *   {"cmd":"status"} | {"cmd":"set","rpm":3000} | {"cmd":"auto"}
 *   {"cmd":"thresholds","warn":85,"critical":95}
 *
 * При выходе (SIGINT/SIGTERM) всегда возвращает вентиляторы в auto.
 */
import Foundation
import CSMC
import Darwin

// MARK: - Конфигурация

struct Config {
    var socketPath = "/var/run/fanctl.sock"
    var warnTemp = 85.0
    var criticalTemp = 95.0
    var hysteresis = 3.0
    var slewPerTick = 300.0        // максимум RPM за тик — плавность
    var intervalMs = 500
    var logPath: String? = nil

    static func parse() -> Config {
        var c = Config()
        let args = Array(CommandLine.arguments.dropFirst())
        var i = 0
        func value(_ name: String) -> String? {
            guard i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        while i < args.count {
            switch args[i] {
            case "--socket": if let v = value("--socket") { c.socketPath = v; i += 1 }
            case "--warn": if let v = value("--warn"), let d = Double(v) { c.warnTemp = d; i += 1 }
            case "--critical": if let v = value("--critical"), let d = Double(v) { c.criticalTemp = d; i += 1 }
            case "--slew": if let v = value("--slew"), let d = Double(v) { c.slewPerTick = d; i += 1 }
            case "--interval": if let v = value("--interval"), let d = Double(v) { c.intervalMs = Int(d); i += 1 }
            case "--log": if let v = value("--log") { c.logPath = v; i += 1 }
            case "--help", "-h":
                print("""
                Использование: sudo fanctld [опции]
                  --socket PATH      путь к сокету (по умолчанию /var/run/fanctl.sock)
                  --warn C           порог предупреждения, °C (85)
                  --critical C       порог аварии, °C (95)
                  --slew RPM         максимум изменения оборотов за тик (300)
                  --interval MS      период цикла, мс (500)
                  --log PATH         писать CSV-лог (время, tmax, обороты, режим)
                """)
                exit(0)
            default:
                FileHandle.standardError.write(Data("неизвестный аргумент \(args[i])\n".utf8))
                exit(2)
            }
            i += 1
        }
        guard c.warnTemp > 30, c.criticalTemp > c.warnTemp, c.criticalTemp < 120,
              c.slewPerTick > 0, c.slewPerTick.isFinite,
              (50...10_000).contains(c.intervalMs) else {
            FileHandle.standardError.write(Data("недопустимые пороги, slew или interval\n".utf8))
            exit(2)
        }
        return c
    }
}

// MARK: - Состояние

enum Mode: String {
    case auto
    case manual
    case emergency
}

final class Daemon {
    let cfg: Config
    private var conn: OpaquePointer?
    private var tempKeys: [String] = []
    private(set) var mode: Mode = .auto
    private var userTarget: Double = 0
    private var appliedTarget: [Double] = []   // текущая команда (для slew)
    private var fans: [smc_fan_t] = []
    private var warnTemp: Double
    private var criticalTemp: Double
    private var logHandle: FileHandle?
    private var tickCount: UInt64 = 0
    private var targetWriteFailed: [Bool] = []
    private var lastMaxTemp = 0.0
    private var lastMaxTempKey = "?"
    private var validTempCount = 0
    private var failedTempCount = 0
    private var temperatureReadFailures = 0
    private var fanReadFailures = 0
    private var sensorFault = false
    private var fanFault = false
    private var controlFault = false
    private var lastError: String?
    private var tickHadWriteError = false

    init(cfg: Config) {
        self.cfg = cfg
        self.warnTemp = cfg.warnTemp
        self.criticalTemp = cfg.criticalTemp
    }

    // MARK: запуск

    func start() -> Int32 {
        setvbuf(stdout, nil, Int32(_IOLBF), 0)   // логи видны в /tmp/fanctld.log сразу
        guard geteuid() == 0 else {
            FileHandle.standardError.write(Data("""
            fanctld: требуются права root. Запускайте:
                sudo fanctld
            """.utf8))
            return 1
        }

        guard let c = smc_open() else {
            FileHandle.standardError.write(Data("fanctld: SMC недоступен: \(String(cString: smc_last_error()))\n".utf8))
            return 1
        }
        conn = c

        // Уже запущен?
        if connectAndSend(dict: ["cmd": "status"]) != nil {
            FileHandle.standardError.write(Data("fanctld: уже запущен (\(cfg.socketPath))\n".utf8))
            return 1
        }
        if cfg.socketPath == "/var/run/fanctl.sock",
           connectAndSend(dict: ["cmd": "status"], socketPath: "/tmp/fanctl.sock") != nil {
            FileHandle.standardError.write(Data("fanctld: запущена старая версия (/tmp/fanctl.sock); сначала остановите её\n".utf8))
            return 1
        }
        unlink(cfg.socketPath)

        discoverTempKeys()
        guard !tempKeys.isEmpty else {
            FileHandle.standardError.write(Data("fanctld: температурные датчики не обнаружены\n".utf8))
            return 1
        }
        guard refreshFans(), !fans.isEmpty else {
            FileHandle.standardError.write(Data("fanctld: вентиляторы не обнаружены: \(String(cString: smc_last_error()))\n".utf8))
            return 1
        }
        appliedTarget = fans.map { $0.actual }
        targetWriteFailed = fans.map { _ in false }

        // Страховка: если прошлый экземпляр упал в режиме manual (kill -9 и т.п.),
        // при старте возвращаем управление SMC.
        var recovered = false
        for (i, f) in fans.enumerated() where f.mode_forced == 1 {
            guard writeForced(i, forced: false) else { return 1 }
            recovered = true
        }
        if recovered {
            print("fanctld: обнаружен принудительный режим после перезапуска — возврат в auto")
        }

        openLog()
        installSignalHandlers()

        print("fanctld: вентиляторов — \(fans.count), датчиков — \(tempKeys.count)")
        for f in fans {
            print(String(format: "  Fan%d: %.0f–%.0f RPM (сейчас %.0f, mode=%d)",
                         f.index, f.min, f.max, f.actual, f.mode_forced))
        }
        print(String(format: "  пороги: warn %.0f°C, critical %.0f°C, slew %.0f RPM/тик, интервал %d мс",
                     warnTemp, criticalTemp, cfg.slewPerTick, cfg.intervalMs))
        print("  сокет: \(cfg.socketPath)")

        guard startSocketServer() else {
            FileHandle.standardError.write(Data("fanctld: не удалось создать сокет \(cfg.socketPath)\n".utf8))
            return 1
        }

        runLoop()
        return shutdown() ? 0 : 2
    }

    private func discoverTempKeys() {
        var total: UInt32 = 0
        guard smc_key_count(conn, &total) == 0 else { return }
        var keys: [String] = []
        let keyPtr = UnsafeMutablePointer<Int8>.allocate(capacity: 5)
        defer { keyPtr.deallocate() }
        for i in 0..<total {
            guard smc_key_at(conn, i, keyPtr) == 0 else { continue }
            guard UInt8(bitPattern: keyPtr[0]) == UInt8(ascii: "T") else { continue }
            let bytes = (0..<4).map { UInt8(bitPattern: keyPtr[$0]) }
            guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) else { continue }
            let key = String(bytes: bytes, encoding: .ascii) ?? ""
            guard !key.isEmpty else { continue }
            var v = 0.0
            guard smc_read_double(conn, key, &v) == 0 else { continue }
            guard v >= 5 && v <= 120 else { continue }   // отсев Tz*/Ta* = 0
            keys.append(key)
        }
        tempKeys = keys
    }

    private func refreshFans() -> Bool {
        let cap: Int32 = 8
        let buf = UnsafeMutablePointer<smc_fan_t>.allocate(capacity: Int(cap))
        defer { buf.deallocate() }
        var count: Int32 = 0
        guard smc_read_fans(conn, buf, cap, &count) == 0 else { return false }
        let newFans = (0..<Int(count)).map { buf[$0] }
        guard newFans.allSatisfy({ fan in
            fan.actual.isFinite && fan.target.isFinite && fan.min.isFinite && fan.max.isFinite &&
            fan.actual >= 0 && fan.min >= 0 && fan.max > fan.min
        }) else {
            setError("SMC вернул некорректные параметры вентиляторов")
            return false
        }
        if newFans.count != appliedTarget.count {
            appliedTarget = newFans.map { $0.actual > 0 ? $0.actual : 0 }
            targetWriteFailed = newFans.map { _ in false }
        }
        fans = newFans
        fanReadFailures = 0
        fanFault = false
        return true
    }

    // MARK: основной цикл

    private func runLoop() {
        while !exitState.value {
            tick()
            pollSocket(timeoutMs: cfg.intervalMs)
        }
    }

    private func tick() {
        tickCount &+= 1
        tickHadWriteError = false
        if !refreshFans() {
            fanReadFailures += 1
            if fanReadFailures >= 3 { fanFault = true }
            setError("чтение вентиляторов: \(String(cString: smc_last_error()))")
        }
        guard !fans.isEmpty else { return }
        if tickCount % 600 == 0 { discoverTempKeys() }

        let reading = readTemperatures()
        lastMaxTemp = reading.maxTemp
        lastMaxTempKey = reading.maxKey
        validTempCount = reading.valid
        failedTempCount = reading.failed
        if reading.valid == 0 {
            temperatureReadFailures += 1
            if temperatureReadFailures >= 3 { sensorFault = true }
            setError("нет валидных показаний температуры (\(reading.failed) ошибок)")
        } else {
            temperatureReadFailures = 0
            sensorFault = false
            if reading.failed > 0 {
                setError("недоступны температурные датчики: \(reading.failed) из \(reading.failed + reading.valid)")
            }
        }

        if sensorFault || fanFault || controlFault || reading.maxTemp >= criticalTemp {
            mode = .emergency
        } else if mode == .emergency && reading.valid > 0 && reading.maxTemp < criticalTemp - cfg.hysteresis {
            mode = (userTarget > 0 ? .manual : .auto)
        }

        switch mode {
        case .auto:
            for (i, f) in fans.enumerated() where f.mode_forced == 1 {
                if writeForced(i, forced: false) { appliedTarget[i] = 0 }
            }
        case .manual, .emergency:
            for (i, f) in fans.enumerated() where f.mode_forced != 1 {
                _ = writeForced(i, forced: true)
            }
            for (i, f) in fans.enumerated() {
                let target: Double
                if mode == .emergency {
                    target = f.max
                } else {
                    var floor = f.min
                    if reading.maxTemp >= warnTemp {
                        let span = f.max - f.min
                        let fraction = min(1.0, (reading.maxTemp - warnTemp) / 10.0)
                        floor = max(floor, f.min + span * (0.6 + 0.4 * fraction))
                    }
                    target = max(floor, min(userTarget, f.max))
                }
                let step = mode == .emergency ? max(cfg.slewPerTick, 1500) : cfg.slewPerTick
                var next = appliedTarget[i]
                if next <= 0 { next = f.actual > 0 ? f.actual : target }
                if target > next { next = min(target, next + step) }
                else if target < next { next = max(target, next - step) }
                next = max(f.min, min(next, f.max))
                appliedTarget[i] = next

                if abs(next - f.target) >= 10 || f.mode_forced != 1 || targetWriteFailed[i] {
                    targetWriteFailed[i] = !writeTarget(i, rpm: next.rounded())
                }
            }
        }

        if tickHadWriteError {
            controlFault = true
        } else {
            controlFault = false
            if !sensorFault && !fanFault && failedTempCount == 0 { lastError = nil }
        }

        if tickCount % 20 == 0 {
            let fmt = String(format: "%.1f", reading.maxTemp)
            print("[\(timestamp())] tmax=\(fmt)°C (\(reading.maxKey)) mode=\(mode.rawValue) " +
                  "sensors=\(reading.valid)/\(reading.valid + reading.failed) " +
                  fans.map { String(format: "F%d=%.0f", $0.index, $0.actual) }.joined(separator: " "))
        }
        log(maxTemp: reading.maxTemp, maxKey: reading.maxKey)
    }

    private func readTemperatures() -> (maxTemp: Double, maxKey: String, valid: Int, failed: Int) {
        var maxTemp = 0.0
        var maxKey = "?"
        var valid = 0
        var failed = 0
        for key in tempKeys {
            var value = 0.0
            guard smc_read_double(conn, key, &value) == 0,
                  value.isFinite, (5...120).contains(value) else {
                failed += 1
                continue
            }
            valid += 1
            if value > maxTemp { maxTemp = value; maxKey = key }
        }
        return (maxTemp, maxKey, valid, failed)
    }

    private func writeForced(_ index: Int, forced: Bool) -> Bool {
        guard smc_fan_set_forced(conn, Int32(index), forced ? 1 : 0) != 0 else { return true }
        tickHadWriteError = true
        setError("запись F\(index)Md: \(String(cString: smc_last_error()))")
        return false
    }

    private func writeTarget(_ index: Int, rpm: Double) -> Bool {
        guard smc_fan_set_target(conn, Int32(index), rpm) != 0 else { return true }
        tickHadWriteError = true
        setError("запись F\(index)Tg: \(String(cString: smc_last_error()))")
        return false
    }

    private func setError(_ message: String) {
        if lastError != message || tickCount % 20 == 0 {
            print("[\(timestamp())] ОШИБКА: \(message)")
        }
        lastError = message
    }

    private func log(maxTemp: Double, maxKey: String) {
        guard let h = logHandle else { return }
        if tickCount == 1 {
            let head = "time,tmax_c,tmax_key,mode," +
                fans.map { "fan\($0.index)_rpm,fan\($0.index)_target" }.joined(separator: ",") + "\n"
            h.write(Data(head.utf8))
        }
        var line = "\(timestamp()),\(String(format: "%.1f", maxTemp)),\(maxKey),\(mode.rawValue)"
        for f in fans { line += String(format: ",%.0f,%.0f", f.actual, f.target) }
        line += "\n"
        h.write(Data(line.utf8))
    }

    private func openLog() {
        guard let path = cfg.logPath else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) { fm.createFile(atPath: path, contents: nil) }
        logHandle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path))
        logHandle?.seekToEndOfFile()
    }

    // MARK: завершение (всегда возвращаем auto)

    func shutdown() -> Bool {
        print("\nfanctld: возврат вентиляторов в auto…")
        tickHadWriteError = false
        for i in 0..<fans.count {
            _ = writeTarget(i, rpm: 0)
            _ = writeForced(i, forced: false)
        }
        closeSocketServer()
        logHandle?.closeFile()
        if let c = conn { smc_close(c); conn = nil }
        let succeeded = !tickHadWriteError
        print(succeeded ? "fanctld: остановлен" : "fanctld: остановлен с ошибками возврата в auto")
        return succeeded
    }

    private func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }

    // MARK: - Сокет

    private var serverFd: Int32 = -1
    private var clients: [Int32: Data] = [:]
    private var clientActivity: [Int32: Date] = [:]

    private func startSocketServer() -> Bool {
        serverFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFd >= 0 else { return false }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = cfg.socketPath
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in path.utf8.enumerated() { buf[i] = b }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindRes = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(serverFd, $0, len) }
        }
        guard bindRes == 0 else { close(serverFd); serverFd = -1; return false }
        guard let adminGroup = getgrnam("admin") else { close(serverFd); serverFd = -1; return false }
        guard chown(path, 0, adminGroup.pointee.gr_gid) == 0, chmod(path, 0o660) == 0,
              listen(serverFd, 8) == 0 else {
            close(serverFd); serverFd = -1; unlink(path); return false
        }
        _ = fcntl(serverFd, F_SETFL, O_NONBLOCK)
        return true
    }

    private func closeSocketServer() {
        if serverFd >= 0 { close(serverFd); serverFd = -1 }
        for fd in clients.keys { close(fd) }
        clients.removeAll()
        clientActivity.removeAll()
        unlink(cfg.socketPath)
    }

    private func closeClient(_ fd: Int32) {
        close(fd)
        clients.removeValue(forKey: fd)
        clientActivity.removeValue(forKey: fd)
    }

    private func pollSocket(timeoutMs: Int) {
        guard serverFd >= 0 else { return }
        let fds = [serverFd] + Array(clients.keys)
        var descriptors = fds.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
        let result = poll(&descriptors, nfds_t(descriptors.count), Int32(timeoutMs))

        for fd in clients.keys where Date().timeIntervalSince(clientActivity[fd] ?? .distantPast) > 2 {
            closeClient(fd)
        }
        guard result > 0 else { return }

        if descriptors[0].revents & Int16(POLLIN) != 0 {
            while clients.count < 8 {
                let client = accept(serverFd, nil, nil)
                guard client >= 0 else { break }
                _ = fcntl(client, F_SETFL, O_NONBLOCK)
                clients[client] = Data()
                clientActivity[client] = Date()
            }
        }

        for i in 1..<descriptors.count {
            let fd = descriptors[i].fd
            guard clients[fd] != nil, descriptors[i].revents & Int16(POLLIN) != 0 else { continue }
            readClient(fd)
        }
    }

    private func readClient(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while var data = clients[fd] {
            let n = read(fd, &buffer, buffer.count)
            if n > 0 {
                data.append(contentsOf: buffer[0..<n])
                clients[fd] = data
                clientActivity[fd] = Date()
                if data.contains(UInt8(ascii: "\n")) {
                    processClient(fd, data: data)
                    return
                }
                if data.count > 65_536 {
                    closeClient(fd)
                    return
                }
                continue
            }
            if n == 0 { closeClient(fd); return }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            closeClient(fd)
            return
        }
    }

    private func processClient(_ client: Int32, data: Data) {
        defer { closeClient(client) }
        guard let line = String(data: data, encoding: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let cmd = obj["cmd"] as? String else {
            sendJSON(client, ["ok": 0, "error": "bad request"])
            return
        }

        switch cmd {
        case "ping":
            sendJSON(client, ["ok": 1])
        case "status":
            sendJSON(client, statusPayload())
        case "set":
            if let rpm = obj["rpm"] as? Double, rpm.isFinite, rpm > 0, rpm <= 100_000 {
                userTarget = rpm
                if mode == .auto { mode = .manual }
                sendJSON(client, ["ok": 1, "mode": mode.rawValue, "target": rpm])
            } else {
                sendJSON(client, ["ok": 0, "error": "RPM должны быть в диапазоне 1...100000; для auto используйте команду auto"])
            }
        case "auto":
            mode = .auto
            userTarget = 0
            sendJSON(client, ["ok": 1, "mode": "auto"])
        case "quit":
            sendJSON(client, ["ok": 1])
            exitState.request()
        case "thresholds":
            if let w = obj["warn"] as? Double, let c = obj["critical"] as? Double,
               w.isFinite, c.isFinite, c > w && w > 30 && c < 120 {
                warnTemp = w
                criticalTemp = c
                sendJSON(client, ["ok": 1, "warn": w, "critical": c])
            } else {
                sendJSON(client, ["ok": 0, "error": "недопустимые пороги"])
            }
        default:
            sendJSON(client, ["ok": 0, "error": "неизвестная команда"])
        }
    }

    private func statusPayload() -> [String: Any] {
        var payload: [String: Any] = [
            "ok": 1,
            "pid": getpid(),
            "mode": mode.rawValue,
            "userTarget": userTarget,
            "warn": warnTemp,
            "critical": criticalTemp,
            "maxTemp": (lastMaxTemp * 10).rounded() / 10,
            "maxTempKey": lastMaxTempKey,
            "sensorFault": sensorFault,
            "fanFault": fanFault,
            "controlFault": controlFault,
            "validTempCount": validTempCount,
            "failedTempCount": failedTempCount,
            "slew": cfg.slewPerTick,
            "intervalMs": cfg.intervalMs,
            "fans": fans.map { f -> [String: Any] in
                [
                    "index": f.index,
                    "actual": (f.actual).rounded(),
                    "target": (f.target).rounded(),
                    "min": (f.min).rounded(),
                    "max": (f.max).rounded(),
                    "mode": f.mode_forced,
                ]
            },
        ]
        if let lastError { payload["error"] = lastError }
        return payload
    }

    private func sendJSON(_ fd: Int32, _ obj: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(0x0a)
        data.withUnsafeBytes { _ = send(fd, $0.baseAddress, $0.count, MSG_NOSIGNAL) }
    }

    private func connectAndSend(dict: [String: Any], socketPath: String? = nil) -> [String: Any]? {
        let path = socketPath ?? cfg.socketPath
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in path.utf8.enumerated() where i < buf.count { buf[i] = b }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let res = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        guard res == 0 else { return nil }
        guard var data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        data.append(0x0a)
        data.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
        var buf = [UInt8](repeating: 0, count: 8192)
        let n = read(fd, &buf, buf.count)
        guard n > 0, let obj = try? JSONSerialization.jsonObject(with: Data(buf[0..<n])) as? [String: Any]
        else { return nil }
        return obj
    }

    // MARK: сигналы

    private func installSignalHandlers() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        for sig in [SIGINT, SIGTERM] {
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            src.setEventHandler { exitState.request() }
            src.resume()
            signalSources.append(src)
        }
    }

    private var signalSources: [DispatchSourceSignal] = []
}

final class ExitState {
    private let lock = NSLock()
    private var requested = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    func request() {
        lock.lock()
        requested = true
        lock.unlock()
    }
}

let exitState = ExitState()

// MARK: - main

let config = Config.parse()
let daemon = Daemon(cfg: config)
let code = daemon.start()
exit(code)
