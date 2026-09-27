import Foundation

/// 標準の自動制御を基本とし、高温時だけファンを引き上げるコントローラ
public final class FanController {
    public enum Mode: String { case auto, boost, disabled, error }

    private let smc: SMC
    public private(set) var config: FanConfig
    private let fanCount: Int
    private let fanMin: [Double]
    private let fanMax: [Double]
    private var sensorKeys: [String] = []

    public private(set) var mode: Mode = .auto
    private var smoothedTemp: Double?
    /// 解除判定用の温度履歴（直近 releaseDelay 秒）（センサー値のスパイクに左右されないよう平均で判断する）
    private var history: [(date: Date, temp: Double)] = []
    private var hotSamples = 0
    private var boostSince = Date.distantPast
    private var floorRPM: [Double] = []
    private var lastTarget: [Double] = []
    private let log: (String) -> Void

    public init(smc: SMC, config: FanConfig, log: @escaping (String) -> Void) throws {
        self.smc = smc
        self.config = config
        self.log = log
        fanCount = Int(try smc.readDouble("FNum"))
        fanMin = try (0..<fanCount).map { try smc.readDouble("F\($0)Mn") }
        fanMax = try (0..<fanCount).map { try smc.readDouble("F\($0)Mx") }
        try discoverSensors()
    }

    private func discoverSensors() throws {
        let prefixes = config.sensorPrefixes
        sensorKeys = try smc.allKeys().filter { key in
            guard prefixes.contains(where: { key.hasPrefix($0) }),
                  let v = try? smc.read(key), v.type == "flt ", let t = v.doubleValue else { return false }
            return t > 10 && t < 115
        }
        log("fans=\(fanCount) min=\(fanMin) max=\(fanMax) sensors=\(sensorKeys.count)")
    }

    public func update(config newConfig: FanConfig) {
        guard newConfig != config else { return }
        let prefixesChanged = newConfig.sensorPrefixes != config.sensorPrefixes
        config = newConfig
        log("config updated: \(newConfig)")
        if prefixesChanged { try? discoverSensors() }
    }

    /// 最も高い温度とそのセンサー名
    public func hottest() -> (key: String, temp: Double) {
        var best = ("-", 0.0)
        for key in sensorKeys {
            // 異常値（センサー未接続など）は除外
            if let t = try? smc.readDouble(key), t > 10, t < 115, t > best.1 { best = (key, t) }
        }
        return best
    }

    /// 1周期分の制御。現在の状態を返す
    @discardableResult
    public func tick() -> FanStatus {
        let (sensor, raw) = hottest()
        // 瞬間的なスパイクで振れないよう軽く平滑化
        let temp = smoothedTemp.map { $0 * 0.5 + raw * 0.5 } ?? raw
        smoothedTemp = temp
        let now = Date()
        history.append((now, raw))
        history.removeAll { now.timeIntervalSince($0.date) > max(config.releaseDelay, 10) }
        let avgTemp = history.map(\.temp).reduce(0, +) / Double(history.count)
        var message: String?

        do {
            if !config.enabled {
                if mode == .boost || mode == .error { try releaseToSystem() }
                mode = .disabled
            } else {
                if mode == .disabled || mode == .error { mode = .auto }
                switch mode {
                case .auto:
                    hotSamples = raw >= config.boostStartTemp ? hotSamples + 1 : 0
                    // 2サンプル連続で閾値超えならブースト
                    if hotSamples >= 2 { try enterBoost(temp: temp) }
                case .boost:
                    // ブースト開始から releaseDelay 秒以上経ち、その間の平均が解除温度を下回ったら返却
                    if now.timeIntervalSince(boostSince) >= config.releaseDelay && avgTemp < config.releaseTemp {
                        try releaseToSystem()
                        mode = .auto
                        log(String(format: "release to system control (avg %.1f°C)", avgTemp))
                    } else {
                        try applyBoost(temp: temp)
                    }
                default: break
                }
            }
        } catch {
            message = "\(error)"
            log("error: \(error)")
            try? releaseToSystem()
            mode = .error
        }

        let fans = (0..<fanCount).map { i in
            FanStatus.Fan(actual: (try? smc.readDouble("F\(i)Ac")) ?? 0,
                          target: (try? smc.readDouble("F\(i)Tg")) ?? 0,
                          min: fanMin[i], max: fanMax[i])
        }
        return FanStatus(timestamp: now, mode: mode.rawValue, maxTemp: raw, avgTemp: avgTemp, hottestSensor: sensor, fans: fans, message: message)
    }

    private func enterBoost(temp: Double) throws {
        // 切替時点でシステムが回していた回転数を下限にする（標準制御より弱くしない）
        floorRPM = (0..<fanCount).map { (try? smc.readDouble("F\($0)Ac")) ?? fanMin[$0] }
        lastTarget = floorRPM
        boostSince = Date()
        mode = .boost
        log(String(format: "boost start (%.1f°C) floor=%@", temp, floorRPM.map { String(Int($0)) }.joined(separator: ",")))
        try applyBoost(temp: temp)
    }

    private func applyBoost(temp: Double) throws {
        let span = max(config.fullSpeedTemp - config.boostStartTemp, 0.1)
        let ratio = min(max((temp - config.boostStartTemp) / span, 0), 1)
        try unlock()
        for i in 0..<fanCount {
            // 開始温度で最低回転、全開温度で設定上限。ただし標準制御の回転数（floor）は下回らない
            let cap = min(max(fanMax[i] * config.boostMaxPercent / 100, fanMin[i]), fanMax[i])
            let curve = fanMin[i] + (cap - fanMin[i]) * ratio
            var target = max(curve, floorRPM[i])
            // 上げるのは即座に、下げるのはゆっくり（1周期あたり最大200rpm）
            if target < lastTarget[i] { target = max(target, lastTarget[i] - 200) }
            target = min(target, fanMax[i])
            lastTarget[i] = target
            if (try? smc.readDouble("F\(i)Md")) != 1 { try setManual(fan: i) }
            try smc.writeFloat("F\(i)Tg", Float(target))
        }
    }

    /// Apple Silicon では Ftst=1 にすると thermalmonitord がファン制御を手放す
    private func unlock() throws {
        if (try? smc.readDouble("Ftst")) != 1 { try smc.writeUInt8("Ftst", 1) }
    }

    private func setManual(fan i: Int) throws {
        // Ftst 直後は拒否されることがあるので少しリトライ
        var lastError: Error?
        for _ in 0..<20 {
            do {
                try smc.writeUInt8("F\(i)Md", 1)
                return
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        throw lastError!
    }

    /// macOS 標準の自動制御に戻す
    public func releaseToSystem() throws {
        for i in 0..<fanCount { try? smc.writeUInt8("F\(i)Md", 0) }
        try smc.writeUInt8("Ftst", 0)
        hotSamples = 0
    }
}
