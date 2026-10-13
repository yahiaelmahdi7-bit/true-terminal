import Foundation

/// Hub, ⌘K and Recent for the phone. Auth (identity, Host, exact Origin, bearer, scope) already ran in `handle`;
/// these handlers only ever act on a server-made routeId or a known builder id.
extension RemoteServer {
    private func readJSON(_ fd: Int32, _ req: HTTPRequest) -> [String: Any]? {
        // Only the drop/clip routes stream; these small JSON bodies arrive fully buffered (parser caps them).
        let body = req.body
        guard !body.isEmpty, body.count <= 16 * 1024 else { plainReply(fd, 400, "Bad Request", "Send small JSON"); return nil }
        guard let o = (try? JSONSerialization.jsonObject(with: Data(body))) as? [String: Any] else {
            plainReply(fd, 400, "Bad Request", "Need JSON"); return nil
        }
        return o
    }

    private func plainReply(_ fd: Int32, _ status: Int, _ reason: String, _ msg: String) {
        let body = (try? JSONSerialization.data(withJSONObject: ["error": msg])) ?? Data()
        _ = send(fd, HTTPResponse.make(status: status, reason: reason, body: [UInt8](body), contentType: "application/json"))
    }

    private func jsonReply(_ fd: Int32, _ status: Int, _ reason: String, _ obj: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        _ = send(fd, HTTPResponse.make(status: status, reason: reason, body: [UInt8](body), contentType: "application/json"))
    }

    func handleBar(_ fd: Int32, _ req: HTTPRequest, device: UUID) {
        let path = req.path
        if req.method == "GET", path == "/api/hub" {
            _ = send(fd, HTTPResponse.make(status: 200, reason: "OK", body: [UInt8](commands.hubJSON()), contentType: "application/json")); return
        }
        if path.hasPrefix("/api/hub/builder/") {
            let rest = String(path.dropFirst("/api/hub/builder/".count))
            if req.method == "GET" {
                guard let d = commands.builderDetail(id: rest) else { plainReply(fd, 404, "Not Found", "No such builder"); return }
                _ = send(fd, HTTPResponse.make(status: 200, reason: "OK", body: [UInt8](d), contentType: "application/json")); return
            }
            if req.method == "POST", rest.hasSuffix("/ack") {
                let id = String(rest.dropLast("/ack".count))
                guard commands.ackBuilder(id: id) else { plainReply(fd, 404, "Not Found", "No such builder"); return }
                jsonReply(fd, 200, "OK", ["ok": true]); return
            }
        }
        if req.method == "GET", path == "/api/recent" {
            jsonReply(fd, 200, "OK", ["items": Array(commands.history().prefix(50))]); return
        }
        if req.method == "POST", path == "/api/route" {
            guard let o = readJSON(fd, req) else { return }
            guard let text = o["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                plainReply(fd, 400, "Bad Request", "Need {\"text\"}"); return
            }
            guard RemoteBar.isSingleLine(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                plainReply(fd, 400, "Bad Request", "One line only"); return
            }
            guard let p = bar.propose(device: device, text: text) else { plainReply(fd, 429, "Too Many Requests", "Slow down"); return }
            jsonReply(fd, 200, "OK", RemoteBar.routeJSON(id: p.id, p.entry)); return
        }
        if req.method == "POST", path.hasPrefix("/api/route/"), path.hasSuffix("/slot") {
            let id = String(path.dropFirst("/api/route/".count).dropLast("/slot".count))
            guard let o = readJSON(fd, req), let slot = o["slot"] as? String, let value = o["value"] as? String else {
                plainReply(fd, 400, "Bad Request", "Need {\"slot\",\"value\"}"); return
            }
            switch bar.setSlot(id, device: device, slot: slot, value: value) {
            case .ok(let e): jsonReply(fd, 200, "OK", RemoteBar.routeJSON(id: id, e))
            case .gone: plainReply(fd, 404, "Not Found", "Route expired")
            case .invalid: plainReply(fd, 400, "Bad Request", "Not one of the offered values")
            }
            return
        }
        if req.method == "POST", path == "/api/run" {
            guard let o = readJSON(fd, req), let id = o["routeId"] as? String else { plainReply(fd, 400, "Bad Request", "Need {\"routeId\"}"); return }
            switch bar.run(id, device: device, background: o["background"] as? Bool == true, confirm: o["confirm"] as? Bool == true) {
            case .ok(let l):
                var out: [String: Any] = ["ok": true]
                switch l {
                case .pane(let p): out["pane"] = p.uuidString
                case .background(let n): out["background"] = n
                default: break
                }
                jsonReply(fd, 200, "OK", out)
            case .needsConfirm(let why): jsonReply(fd, 409, "Conflict", ["needsConfirm": true, "reason": why])
            case .refused(let why): plainReply(fd, 403, "Forbidden", why)
            case .rateLimited: plainReply(fd, 429, "Too Many Requests", "Max 10 runs a minute")
            case .tooManyBuilders: plainReply(fd, 429, "Too Many Requests", "3 phone builders already running")
            case .gone: plainReply(fd, 404, "Not Found", "Route expired")
            }
            return
        }
        plainReply(fd, 404, "Not Found", "Not found")
    }
}
