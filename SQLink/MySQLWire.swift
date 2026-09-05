import Foundation
import CommonCrypto

// MARK: - Client capability flags
enum ClientCap: UInt32 {
    case longPassword      = 0x00000001
    case foundRows         = 0x00000002
    case longFlag          = 0x00000004
    case connectWithDB     = 0x00000008
    case protocol41        = 0x00000200
    case ssl               = 0x00000800
    case secureConnection  = 0x00008000
    case multiResults      = 0x00020000
    case pluginAuth        = 0x00080000
}
func cap(_ c: ClientCap) -> UInt32 { c.rawValue }

// MARK: - Hashing
func sha1(_ bytes: [UInt8]) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
    CC_SHA1(bytes, CC_LONG(bytes.count), &out)
    return out
}
func sha256(_ bytes: [UInt8]) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    CC_SHA256(bytes, CC_LONG(bytes.count), &out)
    return out
}

// MARK: - mysql_native_password auth response
func mysqlNativePassword(password: [UInt8], scramble: [UInt8]) -> [UInt8] {
    let stage1 = sha1(password)
    let stage2 = sha1(stage1)
    var combined = scramble
    combined.append(contentsOf: stage2)
    let stage3 = sha1(combined)
    var result = [UInt8](repeating: 0, count: 20)
    for i in 0..<20 { result[i] = stage1[i] ^ stage3[i] }
    return result
}

// MARK: - Length-encoded helpers
func lenEncInt(_ n: UInt64) -> [UInt8] {
    if n < 251 { return [UInt8(n)] }
    if n < 0x10000 {
        return [0xFC, UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF)]
    }
    if n < 0x1000000 {
        return [0xFD, UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), UInt8((n >> 16) & 0xFF)]
    }
    var b = [UInt8](repeating: 0, count: 9)
    b[0] = 0xFE
    for k in 0..<8 { b[1 + k] = UInt8((n >> (8 * k)) & 0xFF) }
    return b
}
func lenEncData(_ data: [UInt8]) -> [UInt8] {
    var out = lenEncInt(UInt64(data.count))
    out.append(contentsOf: data)
    return out
}

/// Read a length-encoded value starting at `start`. Returns (length, isNull, nextIndex).
func readLenEncValue(_ data: [UInt8], _ start: Int) -> (length: UInt64, isNull: Bool, next: Int) {
    let b = data[start]
    if b == 0xFB { return (0, true, start + 1) }
    if b < 0xFB {
        return (UInt64(b), false, start + 1)
    }
    if b == 0xFC {
        let len = UInt64(data[start + 1]) | UInt64(data[start + 2]) << 8
        return (len, false, start + 3)
    }
    if b == 0xFD {
        let len = UInt64(data[start + 1]) | UInt64(data[start + 2]) << 8 | UInt64(data[start + 3]) << 16
        return (len, false, start + 4)
    }
    var len: UInt64 = 0
    for k in 0..<8 { len |= UInt64(data[start + 1 + k]) << (8 * k) }
    return (len, false, start + 9)
}
func readLenEncInt(_ data: [UInt8], _ start: Int) -> (UInt64, Int) {
    let r = readLenEncValue(data, start)
    return (r.length, r.next)
}
func readLenEncStr(_ data: [UInt8], _ i: inout Int) -> String? {
    let r = readLenEncValue(data, i)
    i = r.next
    if r.isNull { return nil }
    let end = i + Int(r.length)
    guard end <= data.count else { return nil }
    let bytes = Array(data[i..<end])
    i = end
    return String(bytes: bytes, encoding: .utf8)
}
/// Read a NUL-terminated string starting at `start`. Returns (string, nextIndex).
func readCString(_ data: [UInt8], _ start: Int) -> (String, Int) {
    var i = start
    while i < data.count, data[i] != 0 { i += 1 }
    let s = String(bytes: data[start..<i], encoding: .utf8) ?? ""
    return (s, i + 1)
}
