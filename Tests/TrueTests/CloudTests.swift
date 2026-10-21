import Testing
import Foundation
@testable import True

final class FakeCloud: CloudTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    var status = 200
    var body = Data("[]".utf8)
    var fail = false
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        lock.withLock { requests.append(request) }
        if fail { throw URLError(.cannotConnectToHost) }
        return (status, body)
    }
}

private let jobJSON = """
{"id":"j-1","title":"Fix it","repo":"app","branch":"factory/j-1","status":"needsYou","foreman_status":"ESCALATED",
 "needs_you_reason":"Which db?","reason":"Which db?","created_at":100.5,"updated_at":200,"viewed_at":null,"unviewed":true,"archived":false}
"""

@Suite struct CloudClientTests {
    private func client(_ t: FakeCloud, token: String? = "tok-secret") -> CloudClient {
        CloudClient(transport: t, tokenProvider: { token })
    }

    @Test func listsJobsWithBearerAndDecodesSnakeCase() async throws {
        let t = FakeCloud(); t.body = Data("[\(jobJSON)]".utf8)
        let jobs = try await client(t).jobs()
        #expect(jobs.count == 1 && jobs[0].needsYou && jobs[0].needsYouReason == "Which db?" && jobs[0].createdAt == 100.5)
        let r = t.requests[0]
        #expect(r.url?.absoluteString == "http://100.120.234.70:8788/jobs" && r.httpMethod == "GET")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer tok-secret")
    }

    @Test func noTokenMeansNoRequest() async {
        let t = FakeCloud()
        await #expect(throws: CloudError.noToken) { _ = try await client(t, token: nil).jobs() }
        #expect(t.requests.isEmpty)
    }

    @Test func createSendsRepoJobBase() async throws {
        let t = FakeCloud(); t.status = 201; t.body = Data(jobJSON.utf8)
        _ = try await client(t).create(repo: "app", job: "do x", title: nil, base: "abc123")
        let r = t.requests[0]
        #expect(r.httpMethod == "POST" && r.url?.path == "/jobs")
        let b = try #require(JSONSerialization.jsonObject(with: r.httpBody!) as? [String: String])
        #expect(b == ["repo": "app", "job": "do x", "base": "abc123"])
    }

    @Test func answerPostsText() async throws {
        let t = FakeCloud(); t.body = Data(jobJSON.utf8)
        _ = try await client(t).answer("j-1", text: "postgres")
        #expect(t.requests[0].url?.path == "/jobs/j-1/answer" && t.requests[0].httpMethod == "POST")
        #expect((try JSONSerialization.jsonObject(with: t.requests[0].httpBody!) as? [String: String]) == ["text": "postgres"])
    }

    @Test func errorsAreMapped() async {
        let t = FakeCloud(); t.status = 409; t.body = Data(#"{"error":"job is not waiting for an answer"}"#.utf8)
        await #expect(throws: CloudError.http(409, "job is not waiting for an answer")) { _ = try await client(t).answer("j-1", text: "x") }
        t.fail = true
        await #expect(throws: CloudError.network) { _ = try await client(t).jobs() }
        t.fail = false; t.status = 200; t.body = Data("nope".utf8)
        await #expect(throws: CloudError.bad) { _ = try await client(t).jobs() }
    }

    @Test func tokenNeverAppearsInErrors() async {
        let t = FakeCloud(); t.status = 401; t.body = Data(#"{"error":"unauthorized"}"#.utf8)
        do { _ = try await client(t).jobs() } catch { #expect(!"\(error)".contains("tok-secret")) }
    }

    @Test func detailKeepsPromptAndBase() async throws {
        let t = FakeCloud()
        t.body = Data(jobJSON.replacingOccurrences(of: "\"archived\":false", with: "\"archived\":false,\"job\":\"the prompt\",\"base\":\"HEAD\",\"base_sha\":\"deadbeef\"").utf8)
        let d = try await client(t).detail("j-1")
        #expect(d.prompt == "the prompt" && d.baseSha == "deadbeef" && d.job.id == "j-1")
    }

    @Test func diffAndViewed() async throws {
        let t = FakeCloud(); t.body = Data("diff --git a/x b/x\n".utf8)
        #expect(try await client(t).diff("j-1").hasPrefix("diff --git"))
        try await client(t).markViewed("j-1")
        #expect(t.requests.map(\.url?.path) == ["/jobs/j-1/diff", "/jobs/j-1/viewed"])
    }

    @Test func parsesSSEAndDropsEnd() {
        let text = """
        id: 1
        event: factory
        data: {"type":"assistant_message","message":"hello"}

        id: 2
        event: factory
        data: {"event_type":"tool_call","tool":"Bash","ts":5}

        id: 2
        event: end
        data: {"cursor": 2}

        """
        let ev = CloudClient.parseSSE(text)
        #expect(ev.map(\.id) == [1, 2] && ev[0].type == "assistant_message" && ev[0].text == "hello" && ev[1].text == "Bash" && ev[1].at == 5)
    }

    @Test func eventsPassSinceCursor() async throws {
        let t = FakeCloud(); t.body = Data()
        _ = try await client(t).events("j-1", since: 7)
        #expect(t.requests[0].url?.query == "since=7")
    }
}

@Suite struct CloudChangeTests {
    private func job(_ id: String, _ status: String) -> CloudJob {
        CloudJob(id: id, title: "t", repo: "r", branch: "b", status: status, createdAt: 0, updatedAt: 0)
    }
    @Test func firstPollSeedsWithoutNotifying() {
        #expect(CloudChange.transitions(old: nil, new: [job("a", "done")]).isEmpty)
    }
    @Test func notifiesOnNeedsYouAndDoneOnly() {
        let old = ["a": "working", "b": "working", "c": "working", "d": "done"]
        let t = CloudChange.transitions(old: old, new: [job("a", "needsYou"), job("b", "done"), job("c", "failed"), job("d", "done"), job("new", "done")])
        #expect(t.map(\.job.id) == ["a", "b"] && t.map(\.kind) == [.needsYou, .done])
    }
    @MainActor @Test func storeFiresOncePerTransition() {
        let s = CloudStore(client: CloudClient(transport: FakeCloud(), tokenProvider: { "t" }))
        var fired: [String] = []
        s.notify = { k, j in fired.append("\(j.id):\(k)") }
        s.apply([job("a", "working")])
        s.apply([job("a", "needsYou")])
        s.apply([job("a", "needsYou")])
        s.apply([job("a", "done")])
        #expect(fired == ["a:needsYou", "a:done"])
    }
    @Test func bannerWords() {
        #expect(CloudNotifier.body(.needsYou, title: "X") == "Cloud job needs you: X")
        #expect(CloudNotifier.body(.done, title: "X") == "Cloud job done: X")
    }
}

@Suite struct CloudRepoTests {
    @Test func repoNameSanitised() {
        #expect(CloudSync.repoName(forPath: "/a/b/My App") == "My-App")
        #expect(CloudSync.repoName(forPath: "/a/.hidden") == "hidden")
        #expect(CloudSync.repoName(forPath: "/a/true") == "true")
    }

    @Test func syncRunsBundleScpSshInOrder() throws {
        let log = Box<[[String]]>([])
        let sync = CloudSync(run: { exe, args in
            log.mutate { $0.append([exe] + args) }
            if args.contains("rev-parse") { return (0, String(repeating: "a", count: 40)) }
            return (0, "")
        })
        let r = try sync.sync(localRepo: "/Users/example/Projects/app")
        #expect(r == CloudSync.Result(repoName: "app", sha: String(repeating: "a", count: 40), dirty: false))
        let cmds = log.value.map { $0[0].split(separator: "/").last.map(String.init)! + ":" + ($0.contains("bundle") ? "bundle" : $0.contains("rev-parse") ? "rev" : $0.contains("status") ? "status" : "") }
        #expect(cmds == ["git:rev", "git:status", "git:bundle", "scp:", "ssh:"])
        let ssh = try #require(log.value.last)
        #expect(ssh.contains("root@100.120.234.70") && ssh.contains("BatchMode=yes"))
        let script = ssh.last!
        #expect(script.contains("runuser -u 'truefactory'") && script.contains("'/var/lib/true-factory/repos/app'") && script.contains("refs/true/sync"))
    }

    @Test func syncFailureSurfacesAndStops() {
        let log = Box<Int>(0)
        let sync = CloudSync(run: { exe, args in
            log.mutate { $0 += 1 }
            if args.contains("rev-parse") { return (0, String(repeating: "b", count: 40)) }
            if exe.hasSuffix("scp") { return (1, "Permission denied") }
            return (0, "")
        })
        #expect(throws: CloudRepoError.self) { try sync.sync(localRepo: "/x/app") }
        #expect(log.value == 4)   // rev-parse, status, bundle, scp — never reaches ssh
    }

    @Test func shellQuotingEscapesSingleQuotes() {
        #expect(CloudSync.shq("a'b") == "'a'\\''b'")
    }

    // MARK: Land, against a real throwaway git repo (local only: no network, nothing pushed)
    private func git(_ dir: String, _ args: String...) -> String {
        cloudRunLive("/usr/bin/git", ["-C", dir, "-c", "user.name=t", "-c", "user.email=t@t"] + args).out
    }
    private func tempRepo() throws -> String {
        let root = NSTemporaryDirectory() + "cloudland-" + UUID().uuidString
        let dir = root + "/proj"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        _ = git(dir, "init", "-q", "-b", "main")
        try "one\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        _ = git(dir, "add", "."); _ = git(dir, "commit", "-q", "-m", "init")
        return dir
    }

    @Test func landAppliesDiffOnNewBranchWithoutTouchingMain() throws {
        let dir = try tempRepo()
        defer { try? FileManager.default.removeItem(atPath: (dir as NSString).deletingLastPathComponent) }
        let base = git(dir, "rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
        let diff = """
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -1 +1,2 @@
         one
        +two
        diff --git a/b.txt b/b.txt
        new file mode 100644
        --- /dev/null
        +++ b/b.txt
        @@ -0,0 +1 @@
        +new
        """
        let r = try CloudLand(run: { cloudRunLive($0, $1) }).land(localRepo: dir, jobID: "j-9", title: "Add two", baseSha: base, diff: diff)
        #expect(r.branch == "cloud/j-9" && r.path.hasSuffix("proj-cloud-j-9"))
        #expect(try String(contentsOfFile: r.path + "/a.txt", encoding: .utf8) == "one\ntwo\n")
        #expect(FileManager.default.fileExists(atPath: r.path + "/b.txt"))
        #expect(git(r.path, "log", "-1", "--format=%s").contains("Cloud job j-9: Add two"))
        #expect(git(r.path, "status", "--porcelain").isEmpty)
        // main and the original checkout are untouched
        #expect(git(dir, "rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines) == base)
        #expect(try String(contentsOfFile: dir + "/a.txt", encoding: .utf8) == "one\n")
        #expect(git(dir, "branch", "--show-current").contains("main"))
        // landing twice is refused
        #expect(throws: CloudRepoError.self) { try CloudLand().land(localRepo: dir, jobID: "j-9", title: "x", baseSha: base, diff: diff) }
    }

    @Test func landCleansUpWhenDiffDoesNotApply() throws {
        let dir = try tempRepo()
        defer { try? FileManager.default.removeItem(atPath: (dir as NSString).deletingLastPathComponent) }
        let bad = "diff --git a/zzz b/zzz\n--- a/zzz\n+++ b/zzz\n@@ -1 +1 @@\n-x\n+y\n"
        #expect(throws: CloudRepoError.self) { try CloudLand().land(localRepo: dir, jobID: "j-8", title: "t", baseSha: nil, diff: bad) }
        #expect(!FileManager.default.fileExists(atPath: dir + "-cloud-j-8"))
        #expect(!git(dir, "branch", "--list", "cloud/j-8").contains("cloud/j-8"))
    }

    @Test func landRefusesEmptyDiff() {
        #expect(throws: CloudRepoError.self) { try CloudLand().land(localRepo: "/nope", jobID: "j", title: "t", baseSha: nil, diff: "  \n") }
    }
}

final class CloudBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T { lock.withLock { v } }
    func mutate(_ f: (inout T) -> Void) { lock.withLock { f(&v) } }
}

@Suite struct CloudComposerTests {
    private func client(_ t: FakeCloud) -> CloudClient { CloudClient(transport: t, tokenProvider: { "tok" }) }
    private func body(_ t: FakeCloud) throws -> [String: Any] {
        let data = try #require(t.requests.last?.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func createSendsModelAndEffort() async throws {
        let t = FakeCloud(); t.body = Data(jobJSON.utf8)
        _ = try await client(t).create(repo: "app", job: "do it", title: nil, base: "abc", model: "claude-sonnet-5-5", effort: "high")
        let b = try body(t)
        #expect(b["model"] as? String == "claude-sonnet-5-5" && b["effort"] as? String == "high" && b["repo"] as? String == "app")
    }

    @Test func createOmitsModelAndEffortWhenNil() async throws {
        let t = FakeCloud(); t.body = Data(jobJSON.utf8)
        _ = try await client(t).create(repo: "app", job: "do it")
        let b = try body(t)
        #expect(b["model"] == nil && b["effort"] == nil && b["title"] == nil && b["base"] == nil)
    }

    @Test func jobDecodesModelAndEffortWhenPresentAndNilWhenNot() throws {
        let with = jobJSON.replacingOccurrences(of: "\"archived\":false", with: "\"archived\":false,\"model\":\"claude-opus-5-5\",\"effort\":\"xhigh\"")
        let a = try JSONDecoder().decode(CloudJob.self, from: Data(with.utf8))
        #expect(a.model == "claude-opus-5-5" && a.effort == "xhigh" && a.modelChip == "Opus 5.5 · X-High")
        let b = try JSONDecoder().decode(CloudJob.self, from: Data(jobJSON.utf8))
        #expect(b.model == nil && b.effort == nil && b.modelChip == nil)
    }

    @Test func healthDecodesNewFields() async throws {
        let t = FakeCloud()
        t.body = Data("""
        {"factory":"ok","running":1,"queued":0,"max_jobs":2,"models":[{"id":"claude-haiku-5-5","label":"Haiku 5.5"},{"id":"x-new","label":"New One"}],
         "default_model":"claude-haiku-5-5","efforts":["low","high"]}
        """.utf8)
        let h = try await client(t).health()
        #expect(h.models.map(\.id) == ["claude-haiku-5-5", "x-new"] && h.models[0].hint == "fastest" && h.models[1].label == "New One")
        #expect(h.efforts == ["low", "high"] && h.defaultModel == "claude-haiku-5-5")
        #expect(h.statusLine == "Connected · streambox · 1 of 2 running")
        #expect(t.requests[0].url?.path == "/health")
    }

    @Test func healthFallsBackToBuiltInListWhenFieldsMissing() async throws {
        let t = FakeCloud(); t.body = Data(#"{"factory":"ok","running":0,"queued":0,"max_jobs":2}"#.utf8)
        let h = try await client(t).health()
        #expect(h.models == CloudModel.builtIn && h.efforts == CloudModel.builtInEfforts && h.defaultModel == nil)
        #expect(CloudModel.builtIn.map(\.label) == ["Fable 5.1", "Opus 5.5", "Sonnet 5.5", "Haiku 5.5"])
        #expect(CloudModel.builtIn.map(\.hint) == ["deepest", "strong", "balanced", "fastest"])
    }

    @Test func repoStateParsing() {
        let sha = String(repeating: "a", count: 40)
        let log = "\(sha)\u{1f}Fix login\u{1f}1800000000"
        let clean = CloudRepoInfo.parse(path: "/p/app", isGit: true, log: log, branch: "main\n", porcelain: "")
        #expect(clean.isRunnable && clean.stateLabel == "clean" && clean.branch == "main" && clean.subject == "Fix login" && clean.shortSha == "aaaaaaa")
        let dirty = CloudRepoInfo.parse(path: "/p/app", isGit: true, log: log, branch: "main", porcelain: " M a.swift\n?? b\n M c")
        #expect(dirty.dirtyCount == 3 && dirty.stateLabel == "3 uncommitted changes · won't be sent")
        #expect(CloudRepoInfo.parse(path: "/p/app", isGit: true, log: log, branch: "main", porcelain: " M a").stateLabel == "1 uncommitted change · won't be sent")
        let notGit = CloudRepoInfo.parse(path: "/p/docs", isGit: false, log: "", branch: "", porcelain: "")
        #expect(!notGit.isRunnable && notGit.problem != nil && notGit.kind == .notGit)
        #expect(CloudRepoInfo.parse(path: "/p/new", isGit: true, log: "", branch: "main", porcelain: "").kind == .noCommit)
        #expect(CloudRepoInfo.parse(path: "/p/app", isGit: true, log: log, branch: "HEAD", porcelain: "").branch == "detached")
    }

    @Test func repoReadUsesGitSeam() {
        let sha = String(repeating: "b", count: 40)
        let run: CloudRun = { _, args in
            if args.contains("--is-inside-work-tree") { return (0, "true") }
            if args.contains("log") { return (0, "\(sha)\u{1f}Hello\u{1f}1700000000") }
            if args.contains("--abbrev-ref") { return (0, "dev") }
            return (0, " M x")
        }
        let r = CloudRepoInfo.read(path: "/p/r", run: run)
        #expect(r.branch == "dev" && r.dirtyCount == 1 && r.committedAt == 1_700_000_000)
        #expect(CloudRepoInfo.read(path: "/p/r", run: { _, _ in (128, "fatal") }).kind == .notGit)
    }

    @Test func ageWords() {
        #expect(CloudRepoInfo.age(of: 1000, now: 1030) == "now" && CloudRepoInfo.age(of: 0, now: 300) == "5m")
        #expect(CloudRepoInfo.age(of: 0, now: 3 * 3600) == "3h" && CloudRepoInfo.age(of: 0, now: 2 * 86_400) == "2d")
        #expect(CloudRepoInfo.age(of: 0, now: 21 * 86_400) == "3w" && CloudRepoInfo.age(of: nil, now: 5) == "")
    }

    @Test func rememberedChoicesRoundTrip() throws {
        let suite = "cloud-prefs-test-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite)); defer { d.removePersistentDomain(forName: suite) }
        let p = CloudPrefs(defaults: d)
        #expect(p.model == "claude-sonnet-5-5" && p.effort == "high" && p.repo == nil)
        p.model = "claude-opus-5-5"; p.effort = "max"; p.repo = "/p/app"
        let q = CloudPrefs(defaults: d)
        #expect(q.model == "claude-opus-5-5" && q.effort == "max" && q.repo == "/p/app")
    }

    @MainActor @Test func canRunNeedsCloudRepoAndTask() {
        let m = CloudComposerModel(projects: [])
        let sha = String(repeating: "c", count: 40)
        m.link = .online
        #expect(!m.canRun && m.blocker == "Pick a repo")
        m.selected = CloudRepoInfo.parse(path: "/p/a", isGit: true, log: "\(sha)\u{1f}s\u{1f}1", branch: "main", porcelain: "")
        #expect(!m.canRun && m.blocker == "Describe the job")
        m.prompt = "  fix it \n"
        #expect(m.canRun && m.blocker == nil)
        m.link = .offline
        #expect(!m.canRun)
        m.link = .online
        m.selected = CloudRepoInfo.parse(path: "/p/docs", isGit: false, log: "", branch: "", porcelain: "")
        #expect(!m.canRun)
    }

    @MainActor @Test func healthRefreshKeepsBuiltInsOnOldServerAndMarksOfflineOnNetwork() async {
        let t = FakeCloud(); t.body = Data(#"{"running":1,"max_jobs":2}"#.utf8)
        let m = CloudComposerModel(projects: [])
        await m.refreshHealth(client: CloudClient(transport: t, tokenProvider: { "t" }), running: 1)
        #expect(m.link == .online && m.models == CloudModel.builtIn && m.statusLine == "Connected · streambox · 1 of 2 running")
        t.fail = true
        await m.refreshHealth(client: CloudClient(transport: t, tokenProvider: { "t" }), running: 0)
        #expect(m.link == .offline && !m.canRun)
    }

    @MainActor @Test func runSendsChosenModelAndReportsFailedStep() async throws {
        let sha = String(repeating: "d", count: 40)
        let t = FakeCloud(); t.body = Data(jobJSON.utf8)
        let c = CloudClient(transport: t, tokenProvider: { "t" })
        let suite = "cloud-run-test-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite)); defer { d.removePersistentDomain(forName: suite) }
        let m = CloudComposerModel(projects: [], prefs: CloudPrefs(defaults: d))
        m.link = .online; m.prompt = "do it"; m.model = "claude-haiku-5-5"; m.effort = "low"
        m.selected = CloudRepoInfo.parse(path: "/p/app", isGit: true, log: "\(sha)\u{1f}s\u{1f}1", branch: "main", porcelain: "")
        // Upload fails: the sheet stays open, inputs kept, the failing step is Uploading.
        var finished = false
        await m.run(client: c, sync: { _, progress in progress(.uploading); throw CloudRepoError(message: "scp broke") }, onDone: { finished = true })
        #expect(!finished && m.send == .failed(.uploading, "scp broke") && m.prompt == "do it" && t.requests.isEmpty)
        // Retry succeeds: the request carries model + effort, choices are remembered.
        await m.run(client: c, sync: { _, _ in CloudSync.Result(repoName: "app", sha: sha, dirty: false) }, onDone: { finished = true })
        let data = try #require(t.requests.first(where: { $0.httpMethod == "POST" })?.httpBody)
        let b = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(finished && b["model"] as? String == "claude-haiku-5-5" && b["effort"] as? String == "low" && b["base"] as? String == sha)
        #expect(d.string(forKey: CloudPrefs.modelKey) == "claude-haiku-5-5" && d.string(forKey: CloudPrefs.repoKey) == "/p/app")
    }

    @Test func triageCarriesModelChip() {
        var j = CloudJob(id: "j", title: "t", repo: "app", branch: "b", status: "working", createdAt: 0, updatedAt: 0)
        #expect(HubTriage.item(j, now: 10).modelChip == "")
        j.model = "claude-sonnet-5-5"; j.effort = "high"
        #expect(HubTriage.item(j, now: 10).modelChip == "Sonnet 5.5 · High")
    }

    @Test func editorGrowsFromSixToFourteenLines() {
        #expect(CloudComposerContent.editorHeight(for: "") == CloudComposerContent.editorHeight(for: "a\nb\nc"))
        #expect(CloudComposerContent.editorHeight(for: String(repeating: "x\n", count: 40)) == CGFloat(14 * 20 + 16))
    }
}
