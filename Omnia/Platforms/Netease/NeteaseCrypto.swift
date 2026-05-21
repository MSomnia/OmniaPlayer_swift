import Foundation
import CommonCrypto

public struct NeteaseCrypto {

    private static let weapiIV      = Data("0102030405060708".utf8)
    private static let weapiPreset  = Data("0CoJUm6Qyw8W8jud".utf8)
    private static let base62       = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    private static let eapiKey      = Data("e82ckenh8dichen8".utf8)
    private static let linuxapiKey  = Data("rFgB&h#%2?^eDg:Q".utf8)

    // Netease RSA public key (2048-bit modulus, exponent 65537)
    private static let rsaModulusHex =
        "00e0b509f6259df8642dbc35662901477df22677ec152b5ff68ace615bb7" +
        "3c57fae0e1dd5fc56ea925cba6b5aef56b3fd2a0b92d77c81e7d0e1ce3e" +
        "7cfe89d32f3d1c5c9527b2b70c4c3acb2c7b2e5a4ce51c10dd5d9ca70f3" +
        "0aa1f55de33a51c8d7cebd43f69d1b3fa20a5060db91b10c74f82d4d76c" +
        "df9cd3ef9e8a9c3b0843d4b2d4c1c7b5c4f7d43671ec6af2e76a83b47c5" +
        "00ed2f2abc5b4bd05c6c5c44ffa8b41218e6e2f5ef3e5d52ee1c85e09ef" +
        "6dac84e2bb20cac2ffe3bb8d62e47f487be3b80cbf258d51e6e75be51f3" +
        "53c6ca4e893e0ad96a35"

    // MARK: - Public API

    /// Encrypt params using weapi scheme (double AES-CBC + RSA).
    /// Returns {"params": base64, "encSecKey": hex}.
    public static func weapiEncrypt(_ params: [String: Any]) throws -> [String: String] {
        let data = try JSONSerialization.data(withJSONObject: params, options: [.sortedKeys])

        // Random 16-char base62 secret key
        var randomBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &randomBytes)
        let secretBytes = randomBytes.map { b -> UInt8 in
            let ch = base62[Int(b) % 62]
            return ch.asciiValue!
        }
        let secretKey = Data(secretBytes)

        // First pass: encrypt data with preset key
        let pass1 = try aesCBCEncrypt(data: data, key: weapiPreset, iv: weapiIV)
        // Second pass: encrypt base64(pass1) with secret key
        let pass2 = try aesCBCEncrypt(data: pass1.base64EncodedData(), key: secretKey, iv: weapiIV)
        let paramsB64 = pass2.base64EncodedString()

        // RSA encrypt the secret key
        let encSecKey = rsaEncrypt(secretKey)

        return ["params": paramsB64, "encSecKey": encSecKey]
    }

    /// Encrypt params using eapi scheme (MD5 signature + AES-128-ECB).
    /// Returns {"params": HEX}.
    public static func eapiEncrypt(url: String, params: [String: Any]) throws -> [String: String] {
        let paramsJson = String(data: try JSONSerialization.data(withJSONObject: params), encoding: .utf8) ?? "{}"
        let message = "nobody\(url)use\(paramsJson)md5forencrypt"
        let md5 = md5Hex(Data(message.utf8))
        let payload = "\(url)-36cd479b6b5-\(paramsJson)-36cd479b6b5-\(md5)"
        let encrypted = try aesECBEncrypt(data: Data(payload.utf8), key: eapiKey)
        return ["params": encrypted.map { String(format: "%02X", $0) }.joined()]
    }

    /// Encrypt params using linuxapi scheme (AES-128-ECB, different key).
    /// Returns {"eparams": HEX}.
    public static func linuxapiEncrypt(_ params: [String: Any]) throws -> [String: String] {
        let data = try JSONSerialization.data(withJSONObject: params)
        let encrypted = try aesECBEncrypt(data: data, key: linuxapiKey)
        return ["eparams": encrypted.map { String(format: "%02X", $0) }.joined()]
    }

    // MARK: - AES helpers

    static func aesCBCEncrypt(data: Data, key: Data, iv: Data) throws -> Data {
        let bufSize = data.count + kCCBlockSizeAES128
        var outBuf = [UInt8](repeating: 0, count: bufSize)
        var outLen = 0
        let status = data.withUnsafeBytes { dp in
            key.withUnsafeBytes { kp in
                iv.withUnsafeBytes { ip in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        kp.baseAddress, key.count,
                        ip.baseAddress,
                        dp.baseAddress, data.count,
                        &outBuf, bufSize,
                        &outLen
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw NeteaseCryptoError.aesFailed(Int(status)) }
        return Data(outBuf.prefix(outLen))
    }

    private static func aesECBEncrypt(data: Data, key: Data) throws -> Data {
        let bufSize = data.count + kCCBlockSizeAES128
        var outBuf = [UInt8](repeating: 0, count: bufSize)
        var outLen = 0
        let status = data.withUnsafeBytes { dp in
            key.withUnsafeBytes { kp in
                CCCrypt(
                    CCOperation(kCCEncrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
                    kp.baseAddress, key.count,
                    nil,
                    dp.baseAddress, data.count,
                    &outBuf, bufSize,
                    &outLen
                )
            }
        }
        guard status == kCCSuccess else { throw NeteaseCryptoError.aesFailed(Int(status)) }
        return Data(outBuf.prefix(outLen))
    }

    // MARK: - RSA (custom BigUInt modular exponentiation)

    /// Implements Python: `pow(int.from_bytes(data[::-1], "big"), 65537, modulus)`
    private static func rsaEncrypt(_ data: Data) -> String {
        let n = BigUInt(bigEndianBytes: Data(data.reversed()))
        let modulus = BigUInt(hexString: rsaModulusHex)
        let result = BigUInt.modpow65537(base: n, modulus: modulus)
        return result.hexString(width: 256)
    }

    // MARK: - MD5

    static func md5Hex(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_MD5($0.baseAddress, CC_LONG(data.count), &digest) }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public enum NeteaseCryptoError: Error {
    case aesFailed(Int)
}

// MARK: - BigUInt (2048-bit capable, for RSA modpow)

/// Arbitrary-precision unsigned integer stored as little-endian UInt32 limbs.
private struct BigUInt {
    var limbs: [UInt32]  // limbs[0] = least significant

    init(limbs: [UInt32]) {
        self.limbs = BigUInt.trim(limbs)
    }

    /// Initialize from big-endian byte array.
    init(bigEndianBytes bytes: Data) {
        var b = [UInt8](bytes)
        while b.count % 4 != 0 { b.insert(0, at: 0) }
        var ls = [UInt32](repeating: 0, count: b.count / 4)
        for i in 0..<ls.count {
            let base = b.count - 4 - i * 4
            ls[i] = (UInt32(b[base]) << 24) | (UInt32(b[base+1]) << 16)
                  | (UInt32(b[base+2]) << 8)  | UInt32(b[base+3])
        }
        limbs = BigUInt.trim(ls)
    }

    /// Initialize from hex string (big-endian representation).
    init(hexString hex: String) {
        var h = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        if h.count % 2 != 0 { h = "0" + h }
        var bytes = [UInt8]()
        bytes.reserveCapacity(h.count / 2)
        var idx = h.startIndex
        while idx < h.endIndex {
            let end = h.index(idx, offsetBy: 2)
            bytes.append(UInt8(h[idx..<end], radix: 16) ?? 0)
            idx = end
        }
        self.init(bigEndianBytes: Data(bytes))
    }

    private static func trim(_ ls: [UInt32]) -> [UInt32] {
        var ls = ls
        while ls.count > 1 && ls.last == 0 { ls.removeLast() }
        return ls.isEmpty ? [0] : ls
    }

    // MARK: Bit length

    func bitLength() -> Int {
        for i in stride(from: limbs.count - 1, through: 0, by: -1) {
            if limbs[i] != 0 { return i * 32 + (32 - limbs[i].leadingZeroBitCount) }
        }
        return 0
    }

    // MARK: Comparison

    static func compare(_ a: BigUInt, _ b: BigUInt) -> Int {
        let n = max(a.limbs.count, b.limbs.count)
        for i in stride(from: n - 1, through: 0, by: -1) {
            let ai: UInt32 = i < a.limbs.count ? a.limbs[i] : 0
            let bi: UInt32 = i < b.limbs.count ? b.limbs[i] : 0
            if ai != bi { return ai > bi ? 1 : -1 }
        }
        return 0
    }

    // MARK: Subtraction (a >= b assumed)

    static func subtract(_ a: BigUInt, _ b: BigUInt) -> BigUInt {
        var result = [UInt32](repeating: 0, count: a.limbs.count)
        var borrow: UInt64 = 0
        for i in 0..<a.limbs.count {
            let ai = UInt64(a.limbs[i])
            let bi = UInt64(i < b.limbs.count ? b.limbs[i] : 0)
            let total = bi + borrow
            if ai < total {
                result[i] = UInt32((ai + (UInt64(1) << 32)) - total)
                borrow = 1
            } else {
                result[i] = UInt32(ai - total)
                borrow = 0
            }
        }
        return BigUInt(limbs: result)
    }

    // MARK: Multiplication (schoolbook)

    static func multiply(_ a: BigUInt, _ b: BigUInt) -> BigUInt {
        var result = [UInt32](repeating: 0, count: a.limbs.count + b.limbs.count)
        for i in 0..<a.limbs.count {
            var carry: UInt64 = 0
            for j in 0..<b.limbs.count {
                let p = UInt64(a.limbs[i]) * UInt64(b.limbs[j]) + UInt64(result[i+j]) + carry
                result[i+j] = UInt32(p & 0xFFFF_FFFF)
                carry = p >> 32
            }
            var k = b.limbs.count
            while carry > 0 && i + k < result.count {
                let p = UInt64(result[i+k]) + carry
                result[i+k] = UInt32(p & 0xFFFF_FFFF)
                carry = p >> 32
                k += 1
            }
        }
        return BigUInt(limbs: result)
    }

    // MARK: Shift operations

    func shiftRight1() -> BigUInt {
        var result = [UInt32](repeating: 0, count: limbs.count)
        var carry: UInt32 = 0
        for i in stride(from: limbs.count - 1, through: 0, by: -1) {
            let newCarry = limbs[i] & 1
            result[i] = (limbs[i] >> 1) | (carry << 31)
            carry = newCarry
        }
        return BigUInt(limbs: result)
    }

    func shiftLeft(_ bits: Int) -> BigUInt {
        guard bits > 0 else { return self }
        let wordShift = bits / 32
        let bitShift  = bits % 32
        var result = [UInt32](repeating: 0, count: limbs.count + wordShift + 1)
        for i in 0..<limbs.count {
            let word = UInt64(limbs[i]) << bitShift
            result[i + wordShift] |= UInt32(word & 0xFFFF_FFFF)
            let hi = UInt32(word >> 32)
            if hi != 0 && i + wordShift + 1 < result.count {
                result[i + wordShift + 1] |= hi
            }
        }
        return BigUInt(limbs: result)
    }

    // MARK: Modulo (binary shift-and-subtract)

    static func mod(_ a: BigUInt, _ m: BigUInt) -> BigUInt {
        if compare(a, m) < 0 { return a }
        let aBits = a.bitLength()
        let mBits = m.bitLength()
        guard aBits >= mBits else { return a }

        let shift = aBits - mBits
        var shifted = m.shiftLeft(shift)
        var result = a

        for _ in 0...shift {
            if compare(result, shifted) >= 0 {
                result = subtract(result, shifted)
            }
            shifted = shifted.shiftRight1()
        }
        return result
    }

    static func mulmod(_ a: BigUInt, _ b: BigUInt, _ m: BigUInt) -> BigUInt {
        mod(multiply(a, b), m)
    }

    // MARK: Modular exponentiation with exponent 65537 = 2^16 + 1

    static func modpow65537(base: BigUInt, modulus m: BigUInt) -> BigUInt {
        var b = mod(base, m)
        let b0 = b          // original base mod m (for the '1' bit at position 0)
        for _ in 0..<16 {   // 16 squarings to reach bit 16
            b = mulmod(b, b, m)
        }
        return mulmod(b, b0, m)
    }

    // MARK: Hex output

    func hexString(width: Int) -> String {
        var hex = limbs.reversed().map { String(format: "%08x", $0) }.joined()
        // Strip leading zeros but keep at least 'width' chars
        while hex.count > width && hex.first == "0" { hex.removeFirst() }
        while hex.count < width { hex = "0" + hex }
        return hex
    }
}
