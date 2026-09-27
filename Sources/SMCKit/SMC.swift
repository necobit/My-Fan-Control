import Foundation
import IOKit

// AppleSMC ユーザクライアントとやり取りする構造体（カーネル側と同じレイアウト、計80バイト）
struct SMCKeyData {
    struct Version { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
    struct PLimitData { var version: UInt16 = 0, length: UInt16 = 0; var cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0 }
    struct KeyInfo { var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var dataAttributes: UInt8 = 0 }

    var key: UInt32 = 0
    var vers = Version()
    var pLimitData = PLimitData()
    var keyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

public enum SMCError: Error, CustomStringConvertible {
    case serviceNotFound
    case openFailed(kern_return_t)
    case callFailed(String, kern_return_t)
    case smcResult(String, UInt8)
    case badData(String)

    public var description: String {
        switch self {
        case .serviceNotFound: return "AppleSMC service not found"
        case .openFailed(let r): return "IOServiceOpen failed: \(String(format: "0x%x", r))"
        case .callFailed(let k, let r): return "SMC call failed for \(k): \(String(format: "0x%x", r))"
        case .smcResult(let k, let r): return "SMC returned error \(r) for \(k)"
        case .badData(let k): return "unexpected data for \(k)"
        }
    }
}

public struct SMCValue {
    public let key: String
    public let type: String
    public let bytes: [UInt8]

    /// 型に応じて数値へ変換（未対応型は nil）
    public var doubleValue: Double? {
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case "ui8 ": return bytes.first.map(Double.init)
        case "ui16": return bytes.count >= 2 ? Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) : nil
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            return Double(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        case "sp78": return bytes.count >= 2 ? Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256 : nil
        case "fpe2": return bytes.count >= 2 ? Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4 : nil
        default: return nil
        }
    }
}

func fourCC(_ s: String) -> UInt32 {
    s.utf8.reduce(0) { $0 << 8 | UInt32($1) }
}

func fourCCString(_ v: UInt32) -> String {
    String(bytes: [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)], encoding: .ascii) ?? "????"
}

public final class SMC {
    private var conn: io_connect_t = 0
    private var infoCache: [String: SMCKeyData.KeyInfo] = [:]

    private enum Selector: UInt8 { case readBytes = 5, writeBytes = 6, getKeyFromIndex = 8, getKeyInfo = 9 }

    public init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(service) }
        let r = IOServiceOpen(service, mach_task_self_, 0, &conn)
        guard r == kIOReturnSuccess else { throw SMCError.openFailed(r) }
    }

    deinit { IOServiceClose(conn) }

    private func call(_ input: inout SMCKeyData, key: String) throws -> SMCKeyData {
        var output = SMCKeyData()
        var outSize = MemoryLayout<SMCKeyData>.stride
        let r = IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<SMCKeyData>.stride, &output, &outSize)
        guard r == kIOReturnSuccess else { throw SMCError.callFailed(key, r) }
        guard output.result == 0 else { throw SMCError.smcResult(key, output.result) }
        return output
    }

    private func keyInfo(_ key: String) throws -> SMCKeyData.KeyInfo {
        if let cached = infoCache[key] { return cached }
        var input = SMCKeyData()
        input.key = fourCC(key)
        input.data8 = Selector.getKeyInfo.rawValue
        let info = try call(&input, key: key).keyInfo
        infoCache[key] = info
        return info
    }

    public func read(_ key: String) throws -> SMCValue {
        let info = try keyInfo(key)
        var input = SMCKeyData()
        input.key = fourCC(key)
        input.keyInfo.dataSize = info.dataSize
        input.data8 = Selector.readBytes.rawValue
        var out = try call(&input, key: key)
        let size = Int(min(info.dataSize, 32))
        let bytes = withUnsafeBytes(of: &out.bytes) { Array($0.prefix(size)) }
        return SMCValue(key: key, type: fourCCString(info.dataType), bytes: bytes)
    }

    public func write(_ key: String, bytes: [UInt8]) throws {
        let info = try keyInfo(key)
        guard bytes.count == Int(info.dataSize) else { throw SMCError.badData(key) }
        var input = SMCKeyData()
        input.key = fourCC(key)
        input.keyInfo.dataSize = info.dataSize
        input.data8 = Selector.writeBytes.rawValue
        withUnsafeMutableBytes(of: &input.bytes) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
        }
        _ = try call(&input, key: key)
    }

    public func readDouble(_ key: String) throws -> Double {
        let v = try read(key)
        guard let d = v.doubleValue else { throw SMCError.badData(key) }
        return d
    }

    public func writeUInt8(_ key: String, _ value: UInt8) throws {
        try write(key, bytes: [value])
    }

    public func writeFloat(_ key: String, _ value: Float) throws {
        let b = value.bitPattern
        try write(key, bytes: [UInt8(b & 0xff), UInt8(b >> 8 & 0xff), UInt8(b >> 16 & 0xff), UInt8(b >> 24 & 0xff)])
    }

    public func keyCount() throws -> Int {
        let v = try read("#KEY")
        return Int(v.doubleValue ?? 0)
    }

    public func key(at index: Int) throws -> String {
        var input = SMCKeyData()
        input.data8 = Selector.getKeyFromIndex.rawValue
        input.data32 = UInt32(index)
        return fourCCString(try call(&input, key: "#\(index)").key)
    }

    public func allKeys() throws -> [String] {
        try (0..<keyCount()).compactMap { try? key(at: $0) }
    }
}
