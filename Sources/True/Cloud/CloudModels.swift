import Foundation

/// One model the cloud can run a job on. The only place the names live: `/health` supplies them when it can,
/// `CloudModel.builtIn` is the same list for an old or unreachable server.
struct CloudModel: Equatable, Identifiable, Sendable {
    var id: String
    var label: String
    /// One word under the label in the picker.
    var hint: String

    static let builtIn: [CloudModel] = [
        CloudModel(id: "claude-fable-5-1", label: "Fable 5.1", hint: "deepest"),
        CloudModel(id: "claude-opus-5-5", label: "Opus 5.5", hint: "strong"),
        CloudModel(id: "claude-sonnet-5-5", label: "Sonnet 5.5", hint: "balanced"),
        CloudModel(id: "claude-haiku-5-5", label: "Haiku 5.5", hint: "fastest"),
    ]
    static let defaultID = "claude-sonnet-5-5"
    static let builtInEfforts = ["low", "medium", "high", "xhigh", "max"]
    static let defaultEffort = "high"

    static func hint(for id: String) -> String { builtIn.first { $0.id == id }?.hint ?? "" }

    static func effortLabel(_ e: String) -> String {
        switch e {
        case "xhigh": return "X-High"
        default: return e.prefix(1).uppercased() + e.dropFirst()
        }
    }

    /// Label for an id the server may know better than we do: "claude-sonnet-5-5" -> "Sonnet 5.5" for ours,
    /// the raw id otherwise.
    static func label(for id: String, in list: [CloudModel] = builtIn) -> String {
        list.first { $0.id == id }?.label ?? builtIn.first { $0.id == id }?.label ?? id
    }

    static func chip(model: String?, effort: String?) -> String? {
        let parts = [model.map { label(for: $0) }, effort.map { effortLabel($0) }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// `GET /health`: the factory's load plus (newer servers) the models and efforts it accepts.
struct CloudHealth: Decodable, Equatable, Sendable {
    var running: Int?
    var queued: Int?
    var maxJobs: Int?
    var models: [CloudModel]
    var efforts: [String]
    var defaultModel: String?

    private struct Entry: Decodable { var id: String; var label: String? }
    private enum K: String, CodingKey { case running, queued, models, efforts, maxJobs = "max_jobs", defaultModel = "default_model" }

    init(running: Int? = nil, queued: Int? = nil, maxJobs: Int? = nil, models: [CloudModel] = CloudModel.builtIn,
         efforts: [String] = CloudModel.builtInEfforts, defaultModel: String? = nil) {
        (self.running, self.queued, self.maxJobs, self.models, self.efforts, self.defaultModel) = (running, queued, maxJobs, models, efforts, defaultModel)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        running = try? c.decodeIfPresent(Int.self, forKey: .running)
        queued = try? c.decodeIfPresent(Int.self, forKey: .queued)
        maxJobs = try? c.decodeIfPresent(Int.self, forKey: .maxJobs)
        defaultModel = (try? c.decodeIfPresent(String.self, forKey: .defaultModel)) ?? nil
        let entries = ((try? c.decodeIfPresent([Entry].self, forKey: .models)) ?? nil) ?? []
        models = entries.isEmpty ? CloudModel.builtIn : entries.map {
            CloudModel(id: $0.id, label: $0.label ?? CloudModel.label(for: $0.id), hint: CloudModel.hint(for: $0.id))
        }
        let ef = ((try? c.decodeIfPresent([String].self, forKey: .efforts)) ?? nil) ?? []
        efforts = ef.isEmpty ? CloudModel.builtInEfforts : ef
    }

    /// "Connected · streambox · 1 of 2 running".
    var statusLine: String {
        var s = "Connected · streambox"
        if let r = running { s += maxJobs.map { " · \(r) of \($0) running" } ?? " · \(r) running" }
        return s
    }
}
