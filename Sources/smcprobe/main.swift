import Foundation
import SMCKit

let smc = try SMC()
let args = CommandLine.arguments.dropFirst()
if let prefix = args.first {
    for k in try smc.allKeys() where k.hasPrefix(prefix) {
        if let v = try? smc.read(k) {
            print(k, v.type, v.bytes.map { String(format: "%02x", $0) }.joined(), v.doubleValue.map { String(format: "%.2f", $0) } ?? "-")
        }
    }
} else {
    print("keys:", try smc.keyCount())
}
