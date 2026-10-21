import Foundation
import AppKit

/// The real folders and Mac-side effects for the phone drop. Everything touching AppKit hops to main.
enum RemoteFilesLive {
    /// One inbox for the whole app: the server reads it, the Mac "Send to Phone" buttons write it.
    static let inbox = RemoteInbox()

    private static func onMain<T: Sendable>(_ f: @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated { f() } }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { f() } }
    }

    static func make() -> RemoteFiles {
        let fm = FileManager.default
        let support = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let files = RemoteFiles(
            tray: { onMain { ScreenshotWatcher.shared.store } },
            inbox: inbox,
            downloads: downloads,
            tmpDir: support.appendingPathComponent("True/RemoteTmp"),
            notify: { msg in DispatchQueue.main.async { RemoteToast.show(msg) } },
            setClipboard: { text in
                DispatchQueue.main.async {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    ClipboardShare.shared.noteExternal(text)
                }
            },
            didIngest: { Task { @MainActor in await ScreenshotWatcher.shared.refresh() } })
        files.sweepTemp()
        return files
    }
}

/// A small non-activating toast (never steals focus from the terminal).
@MainActor
enum RemoteToast {
    private static var panel: NSPanel?
    private static var gen = 0

    static func show(_ text: String) {
        gen += 1
        let mine = gen
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 32, height: 36)
        let p = panel ?? NSPanel(contentRect: NSRect(origin: .zero, size: size),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.level = .statusBar; p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .transient]
        let box = NSView(frame: NSRect(origin: .zero, size: size))
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.92).cgColor
        box.layer?.cornerRadius = 10
        label.frame.origin = NSPoint(x: 16, y: (size.height - label.frame.height) / 2)
        box.addSubview(label)
        p.contentView = box
        p.setContentSize(size)
        if let s = NSScreen.main {
            p.setFrameOrigin(NSPoint(x: s.visibleFrame.midX - size.width / 2, y: s.visibleFrame.minY + 48))
        }
        p.orderFrontRegardless()
        panel = p
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if gen == mine { panel?.orderOut(nil) }
        }
    }
}

/// Mac → phone: copies into the inbox, never links.
@MainActor
enum PhoneOutbox {
    static func sendFile(_ url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        if isDir.boolValue { RemoteToast.show("Folders can't be sent"); return }
        let name = url.lastPathComponent
        let inbox = RemoteFilesLive.inbox
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = inbox.add(name: name, kind: .file, from: url) != nil
            DispatchQueue.main.async { RemoteToast.show(ok ? "Sent to phone: \(name)" : "Couldn't send \(name)") }
        }
    }

    static func sendClipboard() {
        guard let s = NSPasteboard.general.string(forType: .string), !s.isEmpty else {
            RemoteToast.show("Clipboard has no text"); return
        }
        let ok = RemoteFilesLive.inbox.add(name: "Clipboard", kind: .text, data: Data(s.utf8)) != nil
        RemoteToast.show(ok ? "Clipboard sent to phone" : "Couldn't send clipboard")
    }
}
