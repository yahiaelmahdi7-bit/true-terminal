import Foundation
import TrueUpdateCore

// The lifeline: one run per launch (LaunchAgent: at login, then every 15 minutes). It depends on nothing inside True.
// All the rules live in TrueUpdateCore's `Lifeline` so they are tested; this file only wires the real world to the seams.

func ps() -> String { UpdateInstaller.run("/bin/ps", ["-axo", "pid=,comm="]).out }

func fetch(_ url: URL) throws -> Data {
    var req = URLRequest(url: url, timeoutInterval: 30)
    req.setValue("TrueLifeline", forHTTPHeaderField: "User-Agent")
    let sem = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var out: Result<Data, Error> = .failure(UpdateFailure("no answer"))
    URLSession.shared.dataTask(with: req) { d, r, e in
        if let e { out = .failure(e) }
        else if let d, (r as? HTTPURLResponse)?.statusCode == 200, Int64(d.count) <= 600 * 1024 * 1024 { out = .success(d) }
        else { out = .failure(UpdateFailure("answered \((r as? HTTPURLResponse)?.statusCode ?? 0)")) }
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + 600)
    return try out.get()
}

func notify(_ text: String) {
    let safe = text.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "")
    _ = UpdateInstaller.run("/usr/bin/osascript", ["-e", "display notification \"\(safe)\" with title \"True\""])
}

let v = ProcessInfo.processInfo.operatingSystemVersion
let lifeline = Lifeline(paths: .standard, seams: LifelineSeams(
    processList: ps, fetch: fetch, notify: notify, osVersion: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"))
lifeline.run()
