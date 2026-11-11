import Foundation

/// Seam for `launchctl`, so tests never load a real LaunchAgent.
public struct LaunchControl: Sendable {
    public var load: @Sendable (_ plist: URL) -> Void
    public init(load: @escaping @Sendable (URL) -> Void) { self.load = load }
    /// `launchctl bootout` then `bootstrap` in the user's own GUI domain.
    public static let real = LaunchControl { plist in
        let uid = String(getuid())
        _ = UpdateInstaller.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(SafetyNet.lifelineLabel)"])
        _ = UpdateInstaller.run("/bin/launchctl", ["bootstrap", "gui/\(uid)", plist.path])
    }
}

/// True's side of the lifeline: copy the signed helper out of the bundle, keep its own copy of the feed URL and key, and register
/// the LaunchAgent (at login, then every 15 minutes). Runs only for a build that carries `TrueUpdateFeed`.
public enum LifelineInstall {
    public static let helperRelPath = "Contents/Helpers/TrueLifeline"
    public static let repairRelPath = "Contents/Resources/True-Repair.command"

    public enum Result: Equatable, Sendable { case notTeamBuild, noHelper, upToDate, installed }

    public static func plist(binary: URL, log: URL) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Label</key><string>\(SafetyNet.lifelineLabel)</string>
          <key>ProgramArguments</key><array><string>\(binary.path)</string></array>
          <key>RunAtLoad</key><true/>
          <key>StartInterval</key><integer>900</integer>
          <key>ProcessType</key><string>Background</string>
          <key>StandardErrorPath</key><string>\(log.path)</string>
        </dict></plist>

        """
    }

    @discardableResult
    public static func ensure(bundle: URL, info: [String: Any]?, paths: SafetyPaths, launch: LaunchControl = .real) -> Result {
        let fm = FileManager.default
        guard let feed = (info?["TrueUpdateFeed"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !feed.isEmpty,
              let key = (info?[UpdateCore.pubKeyKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return .notTeamBuild }
        // The pinned repair file travels with the bundle when the build had a signing certificate (ad-hoc builds leave it out).
        let repairSrc = bundle.appendingPathComponent(repairRelPath)
        if let d = try? Data(contentsOf: repairSrc), (try? Data(contentsOf: paths.repairFile)) != d {
            try? SafetyNet.writeAtomic(d, to: paths.repairFile)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.repairFile.path)
        }
        let src = bundle.appendingPathComponent(helperRelPath)
        guard fm.fileExists(atPath: src.path), let srcHash = UpdateCore.sha256Hex(fileAt: src) else { return .noHelper }
        try? fm.createDirectory(at: paths.lifelineDir, withIntermediateDirectories: true)
        var changed = false
        if UpdateCore.sha256Hex(fileAt: paths.lifelineBinary) != srcHash {
            // Copy beside it and rename, so a lifeline run never sees half a file. The signature travels with the file.
            let tmp = paths.lifelineDir.appendingPathComponent(".TrueLifeline.new")
            try? fm.removeItem(at: tmp)
            guard (try? fm.copyItem(at: src, to: tmp)) != nil else { return .noHelper }
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
            _ = try? fm.replaceItemAt(paths.lifelineBinary, withItemAt: tmp)
            if !fm.fileExists(atPath: paths.lifelineBinary.path) { try? fm.moveItem(at: tmp, to: paths.lifelineBinary) }
            changed = true
        }
        let cfg = LifelineConfig(feedURL: feed, publicKey: key)
        if SafetyNet.readJSON(LifelineConfig.self, at: paths.lifelineConfigFile) != cfg {
            try? SafetyNet.writeJSON(cfg, to: paths.lifelineConfigFile); changed = true
        }
        let want = plist(binary: paths.lifelineBinary, log: paths.lifelineLog)
        if (try? String(contentsOf: paths.launchAgentPlist, encoding: .utf8)) != want {
            try? SafetyNet.writeAtomic(Data(want.utf8), to: paths.launchAgentPlist); changed = true
        }
        guard changed else { return .upToDate }
        launch.load(paths.launchAgentPlist)
        return .installed
    }
}
