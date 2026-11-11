import Foundation

/// templates (a mission file with `{{blanks}}`) and the Steward-backed home for human steps.

enum MissionTemplates {
    /// Where templates are looked up, first hit wins. The repo copy is the committed source; a Mac without the repo
    /// can drop files in `~/.true/mission-templates`.
    static var dirs: [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        var out: [URL] = []
        if let env = ProcessInfo.processInfo.environment["TRUE_MISSION_TEMPLATES"], !env.isEmpty { out.append(URL(fileURLWithPath: env)) }
        out.append(home.appendingPathComponent(".true/mission-templates"))
        out.append(home.appendingPathComponent("Projects/true/docs/missions/templates"))
        return out
    }

    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 60 && name.allSatisfy { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII || $0 == "-" }
    }

    static func names(in dirs: [URL] = dirs) -> [String] {
        var seen = Set<String>()
        for dir in dirs {
            for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasSuffix(".md") {
                let n = String(f.dropLast(3)); if validName(n) { seen.insert(n) }
            }
        }
        return seen.sorted()
    }

    static func load(_ name: String, in dirs: [URL] = dirs) throws -> String {
        guard validName(name) else { throw PeerError.invalid("Choose a template by name") }
        for dir in dirs {
            if let text = try? String(contentsOf: dir.appendingPathComponent(name + ".md"), encoding: .utf8) { return text }
        }
        throw PeerError.invalid("No template called \(name)")
    }

    /// Replace every `{{blank}}`. A blank with no value is an error that names the flag to add; a value is one short line.
    static func fill(_ text: String, vars: [String: String]) throws -> String {
        for (k, v) in vars {
            guard v.count <= 120, !v.contains("\n"), !v.contains("{{"), !v.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw PeerError.invalid("Use one short line for \(k)")
            }
        }
        var out = "", rest = Substring(text)
        while let open = rest.range(of: "{{") {
            out += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: "}}") else { out += rest[open.lowerBound...]; rest = ""; break }
            let name = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            guard let value = vars[name] else { throw PeerError.invalid("Add --\(name) for this template") }
            out += value
            rest = rest[close.upperBound...]
        }
        return out + rest
    }
}

