import CryptoKit
import Foundation

/// The private line between Peaky and its `peaky` CLI (Claude hooks, terminal alerts).
///
/// Messages travel as distributed notifications, which any app on the Mac can post and observe — sandboxed
/// App Store apps included. So every message is signed with a key kept in a file only you can read
/// (~/Library/Application Support/Peaky/channel.key, mode 600); messages without a valid signature are
/// ignored. Without this, any app could have answered Claude's permission requests ("Allow") or put fake
/// alerts in the notch. The CLI (tools/peaky-cli.swift) carries a copy of this file's logic.
enum Channel {
    static let notify = Notification.Name("io.github.iamsumanp.peaky.notify")
    static let reply = Notification.Name("io.github.iamsumanp.peaky.reply")

    private static let key: SymmetricKey = {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Peaky")
        let url = dir.appendingPathComponent("channel.key")
        if let d = try? Data(contentsOf: url), d.count == 32 { return SymmetricKey(data: d) }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fresh = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        // Another process may have won the race to create it: whoever got there first wins.
        if !fm.createFile(atPath: url.path, contents: fresh, attributes: [.posixPermissions: 0o600]),
           let d = try? Data(contentsOf: url), d.count == 32 {
            return SymmetricKey(data: d)
        }
        return SymmetricKey(data: (try? Data(contentsOf: url)) ?? fresh)
    }()

    /// Make sure the key exists before any CLI needs it.
    static func prepare() { _ = key }

    private static func mac(_ s: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(s.utf8), using: key).map { String(format: "%02x", $0) }.joined()
    }

    /// `{"p": <json>, "m": <signature>}`
    static func seal(_ json: String) -> String {
        let o: [String: String] = ["p": json, "m": mac(json)]
        guard let d = try? JSONSerialization.data(withJSONObject: o) else { return "" }
        return String(decoding: d, as: UTF8.self)
    }

    /// The inner JSON if the signature is valid, nil otherwise.
    static func open(_ sealed: String?) -> String? {
        guard let sealed, let d = sealed.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: String],
              let p = o["p"], let m = o["m"], m.count == 64 else { return nil }
        // Constant-time comparison of the two signatures.
        let expected = Array(mac(p).utf8), given = Array(m.utf8)
        var diff: UInt8 = 0
        for i in 0..<64 { diff |= expected[i] ^ given[i] }
        return diff == 0 ? p : nil
    }

    static func post(_ name: Notification.Name, _ object: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: object) else { return }
        DistributedNotificationCenter.default().postNotificationName(
            name, object: seal(String(decoding: d, as: UTF8.self)), userInfo: nil, deliverImmediately: true)
    }
}
