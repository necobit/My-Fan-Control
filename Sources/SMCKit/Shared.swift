import Foundation

/// デーモンとメニューバーアプリで共有するパス
public enum Paths {
    public static let dir = URL(fileURLWithPath: "/Library/Application Support/MyFanControl")
    public static let config = dir.appendingPathComponent("config.json")
    public static let status = dir.appendingPathComponent("status.json")
}

public struct FanConfig: Codable, Equatable {
    /// false のときは常に macOS 標準制御
    public var enabled: Bool = true
    /// この温度以上でブースト開始（°C）
    public var boostStartTemp: Double = 75
    /// この温度で最大回転（°C）
    public var fullSpeedTemp: Double = 85
    /// 直近 releaseDelay 秒の平均温度がこれ未満なら標準制御に戻す（°C）
    public var releaseTemp: Double = 68
    public var releaseDelay: Double = 30
    /// 監視間隔（秒）
    public var interval: Double = 2
    /// 監視する温度センサーのキー接頭辞（Tp=Pコア, Te=Eコア, Tg=GPU）
    public var sensorPrefixes: [String] = ["Tp", "Te", "Tg"]

    public init() {}

    public init(from decoder: Decoder) throws {
        // 項目が欠けていてもデフォルト値で読めるようにする
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FanConfig()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        boostStartTemp = try c.decodeIfPresent(Double.self, forKey: .boostStartTemp) ?? d.boostStartTemp
        fullSpeedTemp = try c.decodeIfPresent(Double.self, forKey: .fullSpeedTemp) ?? d.fullSpeedTemp
        releaseTemp = try c.decodeIfPresent(Double.self, forKey: .releaseTemp) ?? d.releaseTemp
        releaseDelay = try c.decodeIfPresent(Double.self, forKey: .releaseDelay) ?? d.releaseDelay
        interval = try c.decodeIfPresent(Double.self, forKey: .interval) ?? d.interval
        sensorPrefixes = try c.decodeIfPresent([String].self, forKey: .sensorPrefixes) ?? d.sensorPrefixes
    }

    public static func load() -> FanConfig {
        guard let data = try? Data(contentsOf: Paths.config),
              let cfg = try? JSONDecoder().decode(FanConfig.self, from: data) else { return FanConfig() }
        return cfg
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }
}

public struct FanStatus: Codable {
    public struct Fan: Codable {
        public var actual: Double
        public var target: Double
        public var min: Double
        public var max: Double
    }
    public var timestamp: Date
    /// "auto" | "boost" | "disabled" | "error"
    public var mode: String
    public var maxTemp: Double
    /// 直近 releaseDelay 秒の平均（解除判定に使う値）
    public var avgTemp: Double?
    public var hottestSensor: String
    public var fans: [Fan]
    public var message: String?

    public static func load() -> FanStatus? {
        guard let data = try? Data(contentsOf: Paths.status) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return try? d.decode(FanStatus.self, from: data)
    }
}
