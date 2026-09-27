import Foundation
import SMCKit

// root で動く常駐デーモン。LaunchDaemon から起動される。
// 引数: なし=常駐 / release=標準制御に戻して終了 / status=1回だけ状態表示

setvbuf(stdout, nil, _IOLBF, 0)

func log(_ s: String) {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    print("[\(f.string(from: Date()))] \(s)")
}

let smc: SMC
do { smc = try SMC() } catch { log("\(error)"); exit(1) }
let command = CommandLine.arguments.dropFirst().first

if command == "release" {
    do {
        let c = try FanController(smc: smc, config: FanConfig(), log: log)
        try c.releaseToSystem()
        log("released to system control")
        exit(0)
    } catch { log("\(error)"); exit(1) }
}

if command == "status" {
    let c = try FanController(smc: smc, config: FanConfig(), log: log)
    let h = c.hottest()
    print(String(format: "hottest: %@ %.1f°C", h.key, h.temp))
    for i in 0..<Int(try smc.readDouble("FNum")) {
        print(String(format: "fan%d: %.0f rpm (target %.0f, mode %.0f)", i,
                     try smc.readDouble("F\(i)Ac"), try smc.readDouble("F\(i)Tg"), try smc.readDouble("F\(i)Md")))
    }
    print(String(format: "Ftst: %.0f", try smc.readDouble("Ftst")))
    exit(0)
}

guard getuid() == 0 else { log("must run as root"); exit(1) }

// 設定ディレクトリ: admin グループが書き込めるようにしてメニューバーアプリから設定変更可能にする
let fm = FileManager.default
try? fm.createDirectory(at: Paths.dir, withIntermediateDirectories: true)
chmod(Paths.dir.path, 0o775)
chown(Paths.dir.path, 0, 80) // gid 80 = admin
if !fm.fileExists(atPath: Paths.config.path) {
    try? FanConfig().encoded().write(to: Paths.config)
}
chmod(Paths.config.path, 0o664)
chown(Paths.config.path, 0, 80)

let controller: FanController
do { controller = try FanController(smc: smc, config: FanConfig.load(), log: log) } catch { log("\(error)"); exit(1) }

// 終了時は必ず標準制御へ戻す
func shutdown(_ sig: Int32) -> Never {
    try? controller.releaseToSystem()
    log("signal \(sig): released to system control, exiting")
    exit(0)
}
var sources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, SIG_IGN)
    let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    s.setEventHandler { shutdown(sig) }
    s.resume()
    sources.append(s)
}

// 起動時に一旦標準制御へ（前回の異常終了で手動モードが残っている場合の保険）
try? controller.releaseToSystem()
log("started")

let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .secondsSince1970
var configDate: Date?

func loop() {
    // 設定ファイルが更新されていたら再読み込み
    let mdate = (try? fm.attributesOfItem(atPath: Paths.config.path))?[.modificationDate] as? Date
    if mdate != configDate {
        configDate = mdate
        controller.update(config: FanConfig.load())
    }
    let status = controller.tick()
    if let data = try? encoder.encode(status) {
        try? data.write(to: Paths.status, options: .atomic)
        chmod(Paths.status.path, 0o644)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + max(controller.config.interval, 0.5), execute: loop)
}
DispatchQueue.main.async(execute: loop)
dispatchMain()
