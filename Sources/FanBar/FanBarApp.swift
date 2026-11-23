/*
 * FanBar — меню-бар приложение для мониторинга и ручного управления
 * вентиляторами MacBook (Apple Silicon).
 *
 * Мониторинг работает без демона (чтение SMC/HID без root).
 * Управление — через fanctld (sudo), аварийная защита живёт в демоне.
 */
import SwiftUI
import AppKit
import Sensors
import CSMC

// MARK: - Модель

struct Sample: Sendable {
    let date: Date
    let temp: Double
    let rpm: Double
}

@MainActor
final class AppModel: ObservableObject {
    @Published var snapshot: Snapshot?
    @Published var daemon: DaemonStatus?
    @Published var daemonRunning = false
    @Published var history: [Sample] = []
    @Published var targetRpm: Double = 2500
    @Published var busy = false
    @Published var lastError: String?

    private var store: SensorStore?
    private var timer: Timer?
    private let maxHistory = 1200

    init() {
        store = SensorStore()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = 0.2
        refresh()
    }

    func refresh() {
        guard !busy else { return }
        busy = true
        let store = self.store
        Task.detached(priority: .utility) {
            let s = store?.snapshot()
            let d = DaemonClient.status()
            await MainActor.run {
                self.apply(snapshot: s, daemon: d)
                self.busy = false
            }
        }
    }

    private func apply(snapshot s: Snapshot?, daemon d: DaemonStatus?) {
        if let s {
            self.snapshot = s
            if s.maxTemp >= 0 {
                let rpm = s.fans.first?.actual ?? 0
                history.append(Sample(date: Date(), temp: s.maxTemp, rpm: rpm))
                let cutoff = Date().addingTimeInterval(-600)
                history.removeAll { $0.date < cutoff }
                if history.count > maxHistory { history.removeFirst(history.count - maxHistory) }
            }
        }
        self.daemon = d
        self.daemonRunning = d != nil
        if let d {
            self.targetRpm = d.userTarget > 0 ? d.userTarget : targetRpm
            if let error = d.error { self.lastError = error }
        }
    }

    // MARK: управление

    var controlAvailable: Bool { daemonRunning }

    var mode: String { daemon?.mode ?? "—" }

    func setRpm(_ rpm: Double) {
        targetRpm = rpm
        do {
            try DaemonClient.set(rpm: rpm)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func setAuto() {
        do {
            try DaemonClient.auto()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func startDaemon() {
        Task.detached(priority: .userInitiated) {
            do {
                try DaemonClient.startWithAdminPassword()
                await MainActor.run { self.lastError = nil; self.refresh() }
            } catch DaemonError.cancelled {
                await MainActor.run { self.lastError = "Ввод пароля отменён" }
            } catch {
                await MainActor.run { self.lastError = "Не удалось запустить fanctld — см. /tmp/fanctld.log" }
            }
        }
    }

    func stopDaemon() {
        do {
            try DaemonClient.quit()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    /// Выход из меню-бар приложения (Cmd+Q или кнопка «Выход» в панели).
    func quit() {
        NSApp.terminate(self)
    }

    func setThreshold(warn: Double, critical: Double) {
        do {
            _ = try DaemonClient.request(["cmd": "thresholds", "warn": warn, "critical": critical])
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    // MARK: производные

    var cpuTemp: Double? { snapshot?.cpu }
    var gpuTemp: Double? { snapshot?.gpu }
    var ssdTemp: Double? { snapshot?.ssd }
    var batteryTemp: Double? { snapshot?.battery }
    var maxTemp: Double { snapshot?.maxTemp ?? -1 }
    var maxTempKey: String { snapshot?.maxTempKey ?? "" }
    var fanMinimum: Double { snapshot?.fans.map(\.min).min() ?? 1200 }
    var fanMaximum: Double { snapshot?.fans.map(\.max).max() ?? 6000 }

    func tempColor(_ t: Double, warn: Double? = nil) -> Color {
        guard t >= 0 else { return .secondary }
        let threshold = warn ?? daemon?.warn ?? 85
        if t >= threshold { return .red }
        if t >= threshold - 15 { return .orange }
        return .green
    }

    /// Цвет для строки меню-бара: красный — авария, оранжевый — горячо, зелёный — нормально.
    var menuBarColor: Color {
        if daemon?.mode == "emergency" { return .red }
        return tempColor(maxTemp)
    }
}

// MARK: - Приложение

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // без иконки в Dock
        buildMenu()
    }

    /// Меню приложения: без него у LSUIElement-приложения нет пункта
    /// выхода (Cmd+Q / меню «FanBar»), и закрыть его невозможно.
    private func buildMenu() {
        let menu = NSMenu(title: "FanBar")
        let quitItem = NSMenuItem(title: "Quit FanBar", action: #selector(AppDelegate.quit(_:)), keyEquivalent: "q")
        quitItem.target = NSApp.delegate
        menu.addItem(quitItem)
        NSApp.mainMenu = menu
    }

    @objc func quit(_ sender: Any?) {
        NSApp.terminate(self)
    }
}

@main
struct FanBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView().environmentObject(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "fan.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(model.menuBarColor)
            Text(model.maxTemp >= 0 ? "\(Int(model.maxTemp.rounded()))°" : "—")
                .font(.system(size: 12, weight: .semibold))
        }
        .help(model.maxTemp >= 0 ? "Макс. температура: \(String(format: "%.0f°C", model.maxTemp))" : "Температура недоступна")
        .contextMenu {
            Button("Обновить") { model.refresh() }
            Divider()
            Button("Выход") { model.quit() }
        }
    }
}

struct SectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.subheadline.weight(.semibold))
        }
    }
}

// MARK: - Панель

struct PanelView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GlassEffectContainer {
            VStack(alignment: .leading, spacing: 12) {
                header
                Divider()
                tempsSection
                fansSection
                loadSection
                chartSection
                Divider()
                footer
            }
            .padding(14)
            .frame(width: 400)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
            .onAppear { model.refresh() }
        }
    }

    private var header: some View {
        HStack {
            Text("FanBar").font(.headline)
            Spacer()
            if model.daemonRunning {
                HStack(spacing: 5) {
                    Circle().fill(model.mode == "emergency" || model.daemon?.sensorFault == true ||
                                  model.daemon?.fanFault == true || model.daemon?.controlFault == true
                                  ? Color.red : Color.green)
                        .frame(width: 7, height: 7)
                    Text(model.daemon?.sensorFault == true || model.daemon?.fanFault == true ||
                         model.daemon?.controlFault == true ? "ошибка демона"
                         : model.mode == "manual" ? "ручной режим"
                         : model.mode == "emergency" ? "авария" : "демон запущен")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Стоп") { model.stopDaemon() }
                    .buttonStyle(.glass)
                    .font(.caption)
            } else {
                HStack(spacing: 5) {
                    Circle().fill(Color.gray.opacity(0.5)).frame(width: 7, height: 7)
                    Text("только мониторинг").font(.caption).foregroundStyle(.secondary)
                }
                Button("Запустить") { model.startDaemon() }
                    .buttonStyle(.glass)
                    .font(.caption)
            }
        }
    }

    private var tempsSection: some View {
        VStack(spacing: 8) {
            SectionHeader(title: "Температуры", icon: "thermometer")
            VStack(spacing: 6) {
                TempRow(label: "CPU", value: model.cpuTemp, color: model.tempColor(model.cpuTemp ?? 0))
                TempRow(label: "GPU", value: model.gpuTemp, color: model.tempColor(model.gpuTemp ?? 0))
                HStack(spacing: 8) {
                    TempRow(label: "SSD", value: model.ssdTemp,
                            color: model.tempColor(model.ssdTemp ?? 0, warn: 70))
                    TempRow(label: "АКБ", value: model.batteryTemp,
                            color: model.tempColor(model.batteryTemp ?? 0, warn: 45))
                }
                HStack {
                    Text("Максимум").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(model.maxTemp >= 0 ? String(format: "%.1f °C", model.maxTemp) : "—")
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .foregroundStyle(model.tempColor(model.maxTemp))
                    Text("(\(model.maxTempKey))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                if let failures = model.snapshot?.tempReadFailures, failures > 0 {
                    Text("Недоступно датчиков: \(failures)")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
        }
    }

    private var fansSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "fan")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Вентиляторы").font(.subheadline.weight(.semibold))
                Spacer()
                if model.daemonRunning {
                    Button("Auto") { model.setAuto() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
            }

            if let fans = model.snapshot?.fans, !fans.isEmpty {
                ForEach(fans, id: \.index) { f in
                    FanRow(fan: f)
                }
                if !model.daemonRunning, fans.contains(where: { $0.forced == 1 }) {
                    Text("⚠ Вентиляторы в принудительном режиме, но демон не запущен — запустите fanctld")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            } else {
                Text(model.snapshot?.fanError.map { "Ошибка вентиляторов: \($0)" } ?? "Вентиляторы не найдены")
                    .font(.caption).foregroundStyle(.orange)
            }

            if model.daemonRunning {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Цель").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.0f RPM", model.targetRpm))
                            .font(.system(.caption, design: .monospaced))
                    }
                    Slider(
                        value: Binding(
                            get: { model.targetRpm },
                            set: { model.targetRpm = $0 }
                        ),
                        in: model.fanMinimum...model.fanMaximum,
                        step: 50,
                        onEditingChanged: { editing in
                            if !editing { model.setRpm(model.targetRpm) }
                        }
                    )
                    .disabled(!model.controlAvailable)
                    HStack(spacing: 6) {
                        PresetButton(title: "Тихо", rpm: max(model.fanMinimum, 1500), model: model)
                        PresetButton(title: "Баланс", rpm: min(2600, model.fanMaximum), model: model)
                        PresetButton(title: "Максимум", rpm: model.fanMaximum, model: model)
                    }
                }
            } else {
                Text("Управление требует демона: sudo fanctld")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let err = model.lastError {
                Text(err).font(.caption2).foregroundStyle(.orange)
            }
        }
    }

    private var loadSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Нагрузка и память", icon: "gauge")
            HStack(spacing: 14) {
                if let s = model.snapshot {
                    if s.cpuPercent >= 0 {
                        Metric(label: "CPU", value: String(format: "%.0f%%", s.cpuPercent))
                    }
                    if s.gpuPercent >= 0 {
                        Metric(label: "GPU", value: String(format: "%.0f%%", s.gpuPercent))
                    }
                    if s.memUsedGB >= 0 {
                        Metric(label: "RAM", value: String(format: "%.1f/%.0f GiB", s.memUsedGB, s.memTotalGB))
                    }
                    if s.memAvailablePercent >= 0 {
                        Metric(label: "Доступно", value: String(format: "%.0f%%", s.memAvailablePercent))
                    }
                }
                Spacer()
            }
            .font(.caption)
            if let s = model.snapshot, s.memUsedGB >= 0 {
                Text(String(format: "App %.1f · Wired %.1f · Сжато %.1f GiB",
                            s.memAppGB, s.memWiredGB, s.memCompressedGB))
                Text(String(format: "Кэш %.1f · Свободно %.1f · top Used %.1f GiB",
                            s.memCachedGB, s.memFreeGB, s.memTopUsedGB))
                if s.swapUsedGB >= 0 {
                    Text(String(format: "Swap %.2f/%.2f GiB", s.swapUsedGB, s.swapTotalGB))
                }
            }
            if let processes = model.snapshot?.processes, !processes.isEmpty {
                Text("Процессы, physical footprint")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(processes.prefix(5)) { process in
                    ProcessMemoryRow(process: process)
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "chart.line")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Последние 10 минут").font(.caption).foregroundStyle(.secondary)
                Spacer()
                LegendDot(color: .red, text: "t°")
                LegendDot(color: .blue, text: "RPM")
            }
            ChartView(history: model.history)
                .frame(height: 74)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
        }
    }

    private var footer: some View {
        HStack {
            if let d = model.daemon {
                Text("пороги: \(Int(d.warn))° / \(Int(d.critical))°")
                    .font(.caption2).foregroundStyle(.tertiary)
                Stepper(value: Binding(get: { d.warn },
                                       set: { model.setThreshold(warn: $0, critical: d.critical) }),
                        in: 75...92, step: 1) {
                    EmptyView()
                }
                .labelsHidden()
                .controlSize(.small)
                Stepper(value: Binding(get: { d.critical },
                                       set: { model.setThreshold(warn: d.warn, critical: $0) }),
                        in: 85...110, step: 1) {
                    EmptyView()
                }
                .labelsHidden()
                .controlSize(.small)
            }
            Button("Выход") { model.quit() }
                .buttonStyle(.glass)
                .font(.caption2)
            Spacer()
            Button("Обновить") { model.refresh() }
                .buttonStyle(.glass)
                .font(.caption2)
        }
    }
}

// MARK: - Элементы

struct TempRow: View {
    let label: String
    let value: Double?
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .frame(width: 38, alignment: .leading)
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(color)
                        .frame(width: barWidth(total: geo.size.width))
                }
            }
            .frame(height: 7)
            Text(value.map { String(format: "%.1f°", $0) } ?? "—")
                .font(.system(.caption, design: .monospaced))
                .frame(width: 52, alignment: .trailing)
        }
    }

    private func barWidth(total: CGFloat) -> CGFloat {
        guard let v = value else { return 0 }
        let frac = min(max(v / 110.0, 0), 1)
        return max(4, total * frac)
    }
}

struct FanRow: View {
    let fan: FanReading

    var body: some View {
        HStack(spacing: 8) {
            Text("Fan\(fan.index)")
                .font(.caption)
                .frame(width: 38, alignment: .leading)
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(fan.forced == 1 ? Color.blue : fan.forced == 0 ? Color.gray.opacity(0.6) : Color.orange)
                        .frame(width: width(total: geo.size.width))
                }
            }
            .frame(height: 7)
            Text(String(format: "%.0f", fan.actual))
                .font(.system(.caption, design: .monospaced))
                .frame(width: 44, alignment: .trailing)
            Text("RPM")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func width(total: CGFloat) -> CGFloat {
        guard fan.max > 0 else { return 0 }
        let frac = min(max(fan.actual / fan.max, 0), 1)
        return max(4, total * frac)
    }
}

struct PresetButton: View {
    let title: String
    let rpm: Double
    @ObservedObject var model: AppModel

    var body: some View {
        Button(title) { model.setRpm(rpm) }
            .buttonStyle(.glass)
            .controlSize(.small)
            .disabled(!model.controlAvailable)
    }
}

struct Metric: View {
    let label: String
    let value: String
    var body: some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }
}

struct ProcessMemoryRow: View {
    let process: ProcessMemory

    var body: some View {
        HStack(spacing: 6) {
            Text("\(process.pid)")
                .foregroundStyle(.tertiary)
                .frame(width: 48, alignment: .trailing)
            Text(process.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text(formatBytes(process.memoryBytes))
                .monospacedDigit()
        }
        .help(process.path)
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let gib = Double(bytes) / 1_073_741_824
        if gib >= 1 { return String(format: "%.2f GiB", gib) }
        return String(format: "%.0f MiB", Double(bytes) / 1_048_576)
    }
}

struct LegendDot: View {
    let color: Color
    let text: String
    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - График

struct ChartView: View {
    let history: [Sample]

    var body: some View {
        Canvas { ctx, size in
            guard history.count > 1 else { return }
            let tempScale: Double = 110
            let rpmScale: Double = 6500
            let endDate = history.last?.date ?? Date()
            let startDate = endDate.addingTimeInterval(-600)

            // сетка
            for frac in [0.25, 0.5, 0.75] {
                let y = size.height * CGFloat(frac)
                var grid = Path()
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(grid, with: .color(.primary.opacity(0.06)), lineWidth: 1)
            }

            func line(_ value: (Sample) -> Double, _ scale: Double, color: Color) {
                var p = Path()
                for (i, sample) in history.enumerated() {
                    let elapsed = sample.date.timeIntervalSince(startDate)
                    let x = size.width * CGFloat(min(max(elapsed / 600, 0), 1))
                    let frac = min(max(value(sample) / scale, 0), 1)
                    let y = size.height * (1 - CGFloat(frac))
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                    else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
                ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }

            line({ $0.rpm }, rpmScale, color: .blue)
            line({ $0.temp }, tempScale, color: .red)

            // текущие значения
            if let last = history.last {
                let yT = size.height * (1 - CGFloat(min(last.temp / tempScale, 1)))
                let dot = Path(ellipseIn: CGRect(x: size.width - 5, y: yT - 2.5, width: 5, height: 5))
                ctx.fill(dot, with: .color(.red))
            }
        }
    }
}
