import Foundation

/// Where the Place tile's peer rows come from. Peers do not send their folder or presence yet, so the live
/// source returns none; wiring them later means swapping this one type, not the view.
protocol PlacePeerSource {
    func peers() -> [PlaceRow]
}

struct NoPlacePeers: PlacePeerSource {
    func peers() -> [PlaceRow] { [] }
}

/// The Place tile's rows: this Mac first (its real name and the pane's folder), then peers.
struct PlaceSource {
    var macName: String
    var folder: String
    var peers: any PlacePeerSource = NoPlacePeers()

    static func live(folder: String) -> PlaceSource {
        PlaceSource(macName: Host.current().localizedName ?? TaskDetailCopy.thisMac, folder: folder,
                    peers: PlaceDiskPeers.ifPeersOn(folder: folder))
    }

    func rows() -> [PlaceRow] {
        [PlaceRow(id: "me", name: macName, folder: folder, isThisMac: true)] + peers.peers()
    }
}

/// G2a: peer rows for the focused pane's repo, from today's fields (`SharedRepo` list + Card staleness).
/// Pure: links, shared repos, Cards and the clock come in, so a removed share drops the row at render time with no new Card.
enum PlacePeerRows {
    static func rows(repoURL: String, links: [PeerLink], shared: [String: [SharedRepo]],
                     card: (String) -> PeerCaps?, names: PeerNicknames = PeerNicknames(), now: Date) -> [PlaceRow] {
        let rows = links.filter { l in (shared[l.mailboxId] ?? []).contains { PeerRepo.same($0.url, repoURL) } }.map { l -> PlaceRow in
            let c = card(l.mailboxId)
            let online = c.map { !$0.isStale(at: now) } ?? false
            let f = PlaceFolders.pick(c?.folders[PeerRepo.hash(repoURL) ?? ""] ?? [])
            // No folders sent (an older True, or none shared): the plain note, never a guess.
            return PlaceRow(id: l.mailboxId, name: names.resolve(id: l.mailboxId, label: l.label), folder: f.folder, online: online, lastSeen: c?.updated,
                            moreFolders: f.more, note: f.folder.isEmpty ? GroupCopy.folderNotShared : nil, label: l.label)
        }
        return PlaceLayout.order(rows)
    }
}

struct SharedRepoPlacePeers: PlacePeerSource {
    var repoURL: String
    var links: () -> [PeerLink]
    var shared: () -> [String: [SharedRepo]]
    var card: (String) -> PeerCaps?
    var names: () -> PeerNicknames = { PeerNicknames() }
    var now: () -> Date = Date.init
    func peers() -> [PlaceRow] { PlacePeerRows.rows(repoURL: repoURL, links: links(), shared: shared(), card: card, names: names(), now: now()) }
}

/// Reads Peers' files straight from disk. It never touches `PeerService`, so rendering Place cannot create keys,
/// connect the relay or start the chat bus. No `identity.json` = Peers was never set up = no peer rows.
enum PlaceDiskPeers {
    static func ifPeersOn(folder: String, root: URL = PeerEngine.standardRoot,
                          shared: @escaping () -> [String: [SharedRepo]] = { PeerSettings.sharedRepos },
                          origin: (String) -> String? = { PeerLauncherLive().remoteURL(ofRepoAt: $0) },
                          now: @escaping () -> Date = Date.init) -> any PlacePeerSource {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("identity.json").path),
              !folder.isEmpty, let url = origin(folder) else { return NoPlacePeers() }
        let links: [PeerLink] = PeerEngine.load(root.appendingPathComponent("peers.json")) ?? []
        let caps: [String: PeerCaps] = PeerEngine.load(root.appendingPathComponent("caps.json")) ?? [:]
        guard !links.isEmpty else { return NoPlacePeers() }
        return SharedRepoPlacePeers(repoURL: url, links: { links.filter(\.confirmed) }, shared: shared, card: { caps[$0] }, names: { PeerNicknames.load(root: root) }, now: now)
    }
}

/// G2b: what a peer's Card says about where it works. The sender already sends `~`-relative paths, or the last
/// component for paths outside home; the receiver shows them as given and never re-abbreviates with its own home.
enum PlaceFolders {
    static let maxLength = 120
    /// First usable folder + how many more were sent. Blank or control-character entries are ignored.
    static func pick(_ folders: [String]) -> (folder: String, more: Int) {
        let ok = folders.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }
        guard let first = ok.first else { return ("", 0) }
        return (String(first.prefix(maxLength)), ok.count - 1)
    }
}
