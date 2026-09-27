import SwiftUI
import SMCKit

@MainActor
final class Model: ObservableObject {
    @Published var status: FanStatus?
    @Published var config = FanConfig.load()
    @Published var saveError: String?
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() { status = FanStatus.load() }

    /// デーモンが古いステータスしか書いていない＝停止中
    var daemonAlive: Bool {
        guard let s = status else { return false }
        return Date().timeIntervalSince(s.timestamp) < max(config.interval * 3, 10)
    }

    func save() {
        // 所有者を保つため atomic ではなく上書き
        do {
            try config.encoded().write(to: Paths.config)
            saveError = nil
        } catch {
            saveError = "設定を保存できません: \(error.localizedDescription)"
        }
    }
}

struct MenuView: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $model.config.enabled) {
                Text("ブースト制御").font(.headline)
            }
            .toggleStyle(.switch)

            Divider()

            if let s = model.status, model.daemonAlive {
                HStack {
                    Text(modeLabel(s.mode)).font(.headline)
                    Spacer()
                    Text(String(format: "%.1f°C", s.maxTemp)).font(.headline.monospacedDigit())
                }
                Text("最高温度センサー: \(s.hottestSensor)" + (s.avgTemp.map { String(format: "　平均: %.1f°C", $0) } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(s.fans.enumerated()), id: \.offset) { i, f in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: "ファン%d: %.0f rpm", i + 1, f.actual)).monospacedDigit()
                        ProgressView(value: min(max((f.actual - f.min) / max(f.max - f.min, 1), 0), 1))
                    }
                }
                if let m = s.message { Text(m).font(.caption).foregroundStyle(.red) }
            } else {
                Text("デーモンが動いていません").font(.headline).foregroundStyle(.red)
                Text("install.sh を実行してください").font(.caption)
            }

            Divider()

            // オフの間はしきい値を触れないようにする
            Group {
                tempSlider("ブースト開始", value: $model.config.boostStartTemp, range: 50...100)
                tempSlider("全開", value: $model.config.fullSpeedTemp, range: 55...105)
                tempSlider("標準制御に戻す", value: $model.config.releaseTemp, range: 40...95)
                rpmSlider()
            }
            .disabled(!model.config.enabled)
            .opacity(model.config.enabled ? 1 : 0.4)
            if let e = model.saveError { Text(e).font(.caption).foregroundStyle(.red) }

            Divider()
            Button("終了") { NSApp.terminate(nil) }
        }
        .padding(14)
        .frame(width: 300)
        .onChange(of: model.config) { _, newValue in
            // 整合性を保つ: 解除 < 開始 < 全開
            var c = newValue
            c.fullSpeedTemp = max(c.fullSpeedTemp, c.boostStartTemp + 1)
            c.releaseTemp = min(c.releaseTemp, c.boostStartTemp - 1)
            if c != newValue { model.config = c } else { model.save() }
        }
    }

    func modeLabel(_ mode: String) -> String {
        switch mode {
        case "boost": return "🔥 ブースト中"
        case "auto": return "✅ 標準制御"
        case "disabled": return "⏸ 無効（標準制御）"
        default: return "⚠️ エラー"
        }
    }

    /// ブースト時の最大回転数（% で保存し、rpm も併記）
    func rpmSlider() -> some View {
        let maxRPM = model.status?.fans.map(\.max).max()
        let pct = model.config.boostMaxPercent
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("ブースト最大回転数")
                Spacer()
                Text("\(Int(pct))%" + (maxRPM.map { " (\(Int($0 * pct / 100)) rpm)" } ?? "")).monospacedDigit()
            }
            Slider(value: $model.config.boostMaxPercent, in: 30...100, step: 5)
            Text("標準制御の回転数より下がることはありません").font(.caption2).foregroundStyle(.secondary)
        }
    }

    func tempSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue))°C").monospacedDigit()
            }
            Slider(value: value, in: range, step: 1)
        }
    }
}

struct MyFanControlApp: App {
    @StateObject private var model = Model()

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            let s = model.status
            let boosting = s?.mode == "boost" && model.daemonAlive
            HStack(spacing: 2) {
                Image(systemName: boosting ? "fan.fill" : "fan")
                if let s, model.daemonAlive { Text("\(Int(s.maxTemp))°") }
            }
        }
        .menuBarExtraStyle(.window)
    }
}

MyFanControlApp.main()
