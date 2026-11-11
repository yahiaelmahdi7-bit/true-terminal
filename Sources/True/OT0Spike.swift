import Foundation
import CryptoKit
import Security

/// One True OT0 spike (docs/designs/one-true-spike.md). Test-only, hidden behind `--ot0-spike`.
/// Why an argument and not a second target: the question is about the PACKAGED, self-signed True.app
/// (its code signature, bundle id and entitlements), and only the real app binary has those.
/// Usage: True --ot0-spike <enclave|software|keychain> <create|reload> <dir>
/// Never touches the real ~/.true; everything goes under <dir>. Exits before any UI starts.
enum OT0Spike {
    static func runIfRequested() {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--ot0-spike") else { return }
        guard a.count >= i + 4 else { fail("usage: --ot0-spike <enclave|software|keychain> <create|reload> <dir>") }
        let mode = a[i + 1], phase = a[i + 2]
        let dir = URL(fileURLWithPath: a[i + 3], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do { try run(mode: mode, phase: phase, dir: dir) } catch { fail("\(mode)/\(phase) FAILED: \(error)") }
        exit(0)
    }

    private static func fail(_ s: String) -> Never {
        FileHandle.standardError.write(Data((s + "\n").utf8)); exit(1)
    }

    private struct Handle: Codable { var mode: String; var secureEnclave: Bool; var keyData: String }

    private static func run(mode: String, phase: String, dir: URL) throws {
        let handleURL = dir.appendingPathComponent("\(mode)-handle.json")
        let n = phase == "create" ? 1 : 2
        // fixed 32-byte challenges; the second differs so a replayed signature cannot pass
        let challenge = Data(SHA256.hash(data: Data("ot0-challenge-\(n)".utf8)))
        let signer: any OT0Signer
        if phase == "create" {
            switch mode {
            case "enclave":
                guard SecureEnclave.isAvailable else { throw SpikeError.msg("SecureEnclave.isAvailable == false") }
                let k = try SecureEnclave.P256.Signing.PrivateKey()   // default access control, no auth prompt
                try save(Handle(mode: mode, secureEnclave: true, keyData: k.dataRepresentation.base64EncodedString()), handleURL)
                signer = k
            case "software":
                let k = P256.Signing.PrivateKey()
                try save(Handle(mode: mode, secureEnclave: false, keyData: k.rawRepresentation.base64EncodedString()), handleURL)
                signer = k
            case "keychain":
                let k = P256.Signing.PrivateKey()
                try keychainStore(k.rawRepresentation)
                try save(Handle(mode: mode, secureEnclave: false, keyData: "keychain:io.github.true-terminal.True.ot0spike"), handleURL)
                signer = k
            default: throw SpikeError.msg("unknown mode \(mode)")
            }
        } else {
            let h = try JSONDecoder().decode(Handle.self, from: Data(contentsOf: handleURL))
            switch mode {
            case "enclave":
                signer = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: Data(base64Encoded: h.keyData)!)
            case "software":
                signer = try P256.Signing.PrivateKey(rawRepresentation: Data(base64Encoded: h.keyData)!)
            case "keychain":
                signer = try P256.Signing.PrivateKey(rawRepresentation: try keychainLoad())
            default: throw SpikeError.msg("unknown mode \(mode)")
            }
        }
        let sig = try signer.sign(challenge)
        try challenge.write(to: dir.appendingPathComponent("\(mode)-challenge\(n).bin"))
        try sig.write(to: dir.appendingPathComponent("\(mode)-sig\(n).der"))
        try signer.pubX963.write(to: dir.appendingPathComponent("\(mode)-pub\(n).x963"))
        print("\(mode)/\(phase) OK sig=\(sig.count)B pub=\(signer.pubX963.count)B handle=\(handleURL.path)")
        if mode == "enclave", phase == "create" {
            let blob = Data(base64Encoded: try JSONDecoder().decode(Handle.self, from: Data(contentsOf: handleURL)).keyData)!
            let asSoftware = (try? P256.Signing.PrivateKey(rawRepresentation: blob)) != nil
            print("enclave handle blob=\(blob.count)B, parses as raw software private key: \(asSoftware)")
        }
    }

    private enum SpikeError: Error { case msg(String) }
    private static func save(_ h: Handle, _ url: URL) throws {
        try JSONEncoder().encode(h).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "io.github.true-terminal.True.ot0spike",
         kSecAttrAccount as String: "device-key"]
    }
    private static func keychainStore(_ d: Data) throws {
        SecItemDelete(query() as CFDictionary)
        var q = query(); q[kSecValueData as String] = d
        let s = SecItemAdd(q as CFDictionary, nil)
        guard s == errSecSuccess else { throw SpikeError.msg("SecItemAdd OSStatus \(s)") }
    }
    private static func keychainLoad() throws -> Data {
        var q = query(); q[kSecReturnData as String] = true
        var out: CFTypeRef?
        let s = SecItemCopyMatching(q as CFDictionary, &out)
        guard s == errSecSuccess, let d = out as? Data else { throw SpikeError.msg("SecItemCopyMatching OSStatus \(s)") }
        return d
    }
}

private protocol OT0Signer {
    func sign(_ challenge: Data) throws -> Data
    var pubX963: Data { get }
}
extension SecureEnclave.P256.Signing.PrivateKey: OT0Signer {
    fileprivate func sign(_ c: Data) throws -> Data { try signature(for: c).derRepresentation }
    fileprivate var pubX963: Data { publicKey.x963Representation }
}
extension P256.Signing.PrivateKey: OT0Signer {
    fileprivate func sign(_ c: Data) throws -> Data { try signature(for: c).derRepresentation }
    fileprivate var pubX963: Data { publicKey.x963Representation }
}
