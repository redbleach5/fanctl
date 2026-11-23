/*
 * fanctl — консольный клиент: мониторинг и управление (через fanctld).
 *
 *   fanctl status          — снимок: вентиляторы, температуры, нагрузка
 *   fanctl watch           — то же, раз в секунду
 *   fanctl temps           — все датчики, по убыванию температуры
 *   fanctl set <rpm>       — ручной режим: целевые обороты (нужен fanctld)
 *   fanctl auto            — вернуть управление SMC (auto)
 *   fanctl start           — запустить fanctld (запросит пароль администратора)
 *   fanctl quit            — остановить fanctld (вернёт вентиляторы в auto)
 *   fanctl read <key>      — прочитать сырой ключ SMC (отладка)
 */
import Foundation
import CSMC
import Sensors

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

func fmt(_ v: Double?, _ suffix: String = "") -> String {
    guard let v = v, v.isFinite, v >= 0 else { return "—" }
    return String(format: "%.1f%@", v, suffix)
}

func formatBytes(_ bytes: UInt64) -> String {
    let gib = Double(bytes) / 1_073_741_824
    if gib >= 1 { return String(format: "%.2f GiB", gib) }
    return String(format: "%.0f MiB", Double(bytes) / 1_048_576)
}

func rpm(_ v: Double) -> String { String(format: "%.0f", v) }

func printMemory(_ s: Snapshot, processLimit: Int) {
    if s.memUsedGB >= 0 {
        let available = s.memAvailablePercent >= 0
            ? String(format: "%.0f%%", s.memAvailablePercent) : "—"
        print(String(format: "  Память: %.1f/%.1f GiB (top: %.1f GiB), доступно %@",
                     s.memUsedGB, s.memTotalGB, s.memTopUsedGB, available as NSString))
        print(String(format: "  App %.1f · Wired %.1f · Сжато %.1f · Кэш %.1f · Свободно %.1f GiB",
                     s.memAppGB, s.memWiredGB, s.memCompressedGB, s.memCachedGB, s.memFreeGB))
    } else {
        print("  Память: —")
    }
    if s.swapUsedGB >= 0 {
        print(String(format: "  Swap: %.2f/%.2f GiB", s.swapUsedGB, s.swapTotalGB))
    }
    if !s.processes.isEmpty {
        print("  Топ процессов по physical footprint:")
        for process in s.processes.prefix(processLimit) {
            print(String(format: "    %6d  %-32.32@  %@", process.pid,
                         process.name as NSString, formatBytes(process.memoryBytes) as NSString))
        }
    }
}

func printStatus(_ s: Snapshot, _ d: DaemonStatus?) {
    let modeStr: String
    if let d = d {
        switch d.mode {
        case "manual": modeStr = "MANUAL (цель \(rpm(d.userTarget)) RPM)"
        case "emergency": modeStr = "⚠ АВАРИЯ (максимум)"
        default: modeStr = "auto (управляет SMC)"
        }
    } else {
        modeStr = "демон не запущен — только чтение"
    }
    print("Режим:     \(modeStr)")
    if let d = d {
        print("Пороги:    warn \(Int(d.warn))°C, critical \(Int(d.critical))°C")
        if let error = d.error { print("Ошибка:    \(error)") }
    }
    print()

    if s.fans.isEmpty {
        print("Вентиляторы недоступны" + (s.fanError.map { ": \($0)" } ?? ""))
    } else {
        for f in s.fans {
            let state = f.forced == 1 ? "manual" : f.forced == 0 ? "auto" : "неизвестно"
            print("  Fan\(f.index)  " + String(format: "%5.0f RPM  (цель %5.0f, %.0f–%.0f, %@)",
                                               f.actual, f.target, f.min, f.max, state))
        }
    }
    print()
    print("  CPU  \(fmt(s.cpu, "°C"))   GPU  \(fmt(s.gpu, "°C"))   SoC  \(fmt(s.soc, "°C"))")
    print("  SSD  \(fmt(s.ssd, "°C"))   АКБ  \(fmt(s.battery, "°C"))   MAX  \(fmt(s.maxTemp, "°C")) (\(s.maxTempKey))")
    if s.tempReadFailures > 0 { print("  Недоступно температурных датчиков: \(s.tempReadFailures)") }
    let cpuLoad = s.cpuPercent >= 0 ? String(format: "%.0f%%", s.cpuPercent) : "—"
    let gpuLoad = s.gpuPercent >= 0 ? String(format: "%.0f%%", s.gpuPercent) : "—"
    print("  Загрузка: CPU \(cpuLoad)  GPU \(gpuLoad)")
    printMemory(s, processLimit: 5)
}

func dieNotRunning() -> Never {
    fail("""
    fanctld не запущен — управление недоступно.
    Запуск:  sudo fanctld        (или: fanctl start)
    Остановка: fanctl quit
    """)
}

func daemonFailure(_ error: Error) -> Never {
    if let error = error as? DaemonError, case .remote(let message) = error { fail(message) }
    if let error = error as? DaemonError, case .badResponse = error {
        fail("Некорректный ответ fanctld")
    }
    dieNotRunning()
}

// MARK: - main

let args = Array(CommandLine.arguments.dropFirst())
let cmd = args.first ?? "status"

switch cmd {
case "help", "-h", "--help":
    print("""
    fanctl — мониторинг и управление вентиляторами MacBook (Apple Silicon)

      status            снимок состояния
      watch             обновление каждую секунду (Ctrl-C)
      temps             все температурные датчики
      processes         память и топ-16 процессов по physical footprint
      set <rpm>         задать обороты (ручной режим)
      auto              вернуть auto-режим
      start             запустить fanctld (пароль администратора)
      quit              остановить fanctld (вентиляторы в auto)
      read <key>        прочитать ключ SMC, напр. F0Ac
    """)

case "status", "watch":
    guard let store = SensorStore() else { fail("SMC недоступен") }
    let watch = cmd == "watch"
    repeat {
        let s = store.snapshot()
        let d = DaemonClient.status()
        if watch { print("\u{1b}[2J\u{1b}[H") }
        printStatus(s, d)
        if !watch { break }
        sleep(1)
    } while true

case "temps":
    guard let store = SensorStore() else { fail("SMC недоступен") }
    let s = store.snapshot()
    print("Все датчики (SMC + HID), по убыванию:")
    for sensor in s.topSensors {
        let label = sensor.label.padding(toLength: 24, withPad: " ", startingAt: 0)
        print("  \(label) " + String(format: "%5.1f", sensor.value) + " °C")
    }

case "processes", "memory":
    guard let store = SensorStore() else { fail("SMC недоступен") }
    printMemory(store.snapshot(), processLimit: 16)

case "set":
    guard args.count >= 2, let v = Double(args[1]), v.isFinite, v > 0, v <= 100_000 else {
        fail("uso: fanctl set <1...100000>; для штатного режима используйте fanctl auto")
    }
    do { try DaemonClient.set(rpm: v) ; print("цель: \(rpm(v)) RPM") }
    catch { daemonFailure(error) }

case "auto":
    do { try DaemonClient.auto(); print("вентиляторы переведены в auto") }
    catch { daemonFailure(error) }

case "start":
    if DaemonClient.isRunning() { print("fanctld уже запущен"); break }
    do {
        try DaemonClient.startWithAdminPassword()
        print("fanctld запущен")
    } catch {
        fail("не удалось запустить fanctld (отменён пароль или не найден бинарник)")
    }

case "quit":
    do { try DaemonClient.quit(); print("fanctld останавливается, вентиляторы в auto") }
    catch { daemonFailure(error) }

case "read":
    guard args.count >= 2 else { fail("uso: fanctl read <key>") }
    guard let c = smc_open() else { fail("SMC недоступен") }
    defer { smc_close(c) }
    let key = String(args[1].padding(toLength: 4, withPad: " ", startingAt: 0))
    var v = 0.0
    if smc_read_double(c, key, &v) == 0 {
        print(String(format: "%@ = %.4f", key, v))
    } else {
        fail("ключ '\(args[1])' не прочитан: \(String(cString: smc_last_error()))")
    }

default:
    fail("неизвестная команда '\(cmd)'. См. fanctl help")
}
