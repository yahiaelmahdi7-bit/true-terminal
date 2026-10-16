// Ed25519 helper for True's signed updates. Run: swift scripts/update-sign.swift <command> ...
//   genkey                        make a keypair, store the private half in the login Keychain, print the PUBLIC key
//   pubkey                        print the public key of the Keychain key
//   sign <zip>                    print the base64 signature of the exact zip bytes
//   verify <zip> <sig> <pubkey>   exit 0 only if the signature is valid for that public key (base64 raw 32 bytes)
// The private key is never written to disk or printed; it lives only in the Keychain item
// (service `true-update-signing`, account `release`, secret = base64 of the 32-byte seed).
// TRUE_UPDATE_KEYCHAIN_SERVICE overrides the service name (tests only).
import CryptoKit
import Foundation
import Security

let service = ProcessInfo.processInfo.environment["TRUE_UPDATE_KEYCHAIN_SERVICE"] ?? "true-update-signing"
let account = "release"

func die(_ m: String) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(1) }

func query() -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
}

func loadKey() -> Curve25519.Signing.PrivateKey? {
    var q = query(); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
    var out: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
          let s = String(data: d, encoding: .utf8), let raw = Data(base64Encoded: s),
          let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { return nil }
    return k
}

let a = CommandLine.arguments
guard a.count >= 2 else { die("usage: update-sign.swift genkey | pubkey | sign <zip> | verify <zip> <sig> <pubkey>") }
switch a[1] {
case "genkey":
    var probe = query(); probe[kSecReturnData as String] = false
    if SecItemCopyMatching(probe as CFDictionary, nil) == errSecSuccess { die("a key already exists in the Keychain (\(service)); refusing to overwrite it") }
    let key = Curve25519.Signing.PrivateKey()
    var add = query()
    add[kSecValueData as String] = Data(key.rawRepresentation.base64EncodedString().utf8)
    add[kSecAttrLabel as String] = "True update signing key"
    guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { die("could not store the key in the Keychain") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "pubkey":
    guard let k = loadKey() else { die("no signing key in the Keychain (\(service)); run scripts/gen-update-key.sh") }
    print(k.publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard a.count == 3, let data = try? Data(contentsOf: URL(fileURLWithPath: a[2]), options: .mappedIfSafe) else { die("usage: sign <zip>") }
    guard let k = loadKey() else { die("no signing key in the Keychain (\(service))") }
    guard let sig = try? k.signature(for: data) else { die("signing failed") }
    print(sig.base64EncodedString())
case "verify":
    guard a.count == 5, let data = try? Data(contentsOf: URL(fileURLWithPath: a[2]), options: .mappedIfSafe) else { die("usage: verify <zip> <sig> <pubkey>") }
    let sigText = ((try? String(contentsOfFile: a[3], encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard let sig = Data(base64Encoded: sigText), sig.count == 64 else { die("signature file is not a base64 Ed25519 signature") }
    guard let raw = Data(base64Encoded: a[4].trimmingCharacters(in: .whitespacesAndNewlines)), raw.count == 32,
          let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { die("public key is not base64 of 32 bytes") }
    guard pub.isValidSignature(sig, for: data) else { die("SIGNATURE INVALID") }
    print("signature ok")
default: die("unknown command \(a[1])")
}
