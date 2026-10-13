import Foundation
import SwiftTerm

/// The one door every byte True types into an agent's PTY leaves through. Intent is stated by the
/// caller (``Intent``) and the mechanics live here, so whether a spoken instruction actually RAN
/// never depends on which call site it took.
///
/// Verification is honest: it reads the RENDERED screen (`TrueTerminalView.screenText`) and retries
/// only on positive evidence that the text is still sitting in the composer — never on the mere
/// absence of evidence. (Lifted from Axon; its PaneTail / ActivityMonitor / SleepCenter are gone —
/// `AgentRegistry.talk` wakes a sleeping agent before it calls in.)

@MainActor
enum PaneDelivery {

    /// What the caller means by a write. Previously encoded as a trailing `"\r"` smuggled on the
    /// end of the string, which meant a caller that forgot it silently produced staging behaviour
    /// and no error anywhere.
    enum Intent: Equatable {
        /// Type it, never submit — an attachment path parked ahead of a spoken follow-up.
        case stage
        /// A complete instruction: type, submit, verify, and count the seat as working.
        case prompt
        /// A CLI control line such as `/model sonnet`: type and submit, but it is not the seat's
        /// work — counting it as work would let the announcer call a `/model` switch a finished task.
        case control
        /// Bare Return, nothing typed ("submit", "send it").
        case submitOnly
        /// Answer Claude Code's permission dialog: Approve picks option "1. Yes", Deny sends Escape.
        /// Never types Return, and only fires while the dialog is visibly on screen.
        case answer(approve: Bool)
    }

    /// What actually happened, so callers can say it out loud instead of assuming.
    enum Outcome: Equatable {
        /// The seat visibly took it — it is busy, it reported in, or the composer cleared.
        case landed
        /// Typed only, by request (``Intent/stage``). Not work, not a failure.
        case staged
        /// Pressed Return, but the pane never gave evidence either way. Explicitly NOT success.
        case unverified
        /// The text is still sitting in the composer after a retry — the seat did not take it.
        case stuckInComposer
        /// No live terminal for that pane.
        case noPane
        /// A permission answer was requested but no permission dialog was on screen. Nothing sent.
        case promptGone
    }

    /// The exact bytes a permission answer types: "1" selects "1. Yes" in one keystroke (no Return
    /// needed), Escape cancels — the dialog's own "(esc)" option.
    static func answerKey(approve: Bool) -> String { approve ? "1" : "\u{1B}" }

    // MARK: Reading the pane

    private static func screen(_ pane: UUID, last n: Int) -> String {
        String(TerminalRegistry.shared.view(for: pane)?.screenText().suffix(n) ?? "")
    }

    /// Claude Code draws "esc to interrupt" only while a turn is running.
    private static func looksBusy(_ pane: UUID) -> Bool {
        screen(pane, last: 2000).lowercased().contains("esc to interrupt")
    }

    // MARK: Typing

    /// Collapse a prompt to a single line.
    ///
    /// A newline inside a PTY write is a submit: the first one ends the prompt and everything after
    /// it lands as a second, truncated instruction. Callers upstream already flatten
    /// their jobs, but this is the seam that must guarantee it — a hand-typed multi-line paste or a
    /// future caller would otherwise reintroduce the bug one prompt at a time.
    /// The one door for typed text, every origin: C0 (except tab/newline), DEL and C1 never reach the pane, so a
    /// message can't close the bracketed paste early (ESC[201~) or toggle the agent's mode (ESC[Z).
    nonisolated static func sanitize(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { u in
            u.value == 0x09 || u.value == 0x0A || !(u.value < 0x20 || u.value == 0x7F || (0x80...0x9F).contains(u.value))
        }))
    }

    static func flatten(_ raw: String) -> String {
        raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Type `body` into the pane, wrapped in bracketed paste **only when the running program has
    /// actually turned that mode on** (DECSET 2004, which SwiftTerm tracks for us).
    ///
    /// Detecting rather than assuming matters: a program that never enabled 2004 receives the
    /// `ESC[200~` frame as literal garbage in its input, so unconditional wrapping would corrupt
    /// the prompt for exactly the plain-REPL seats (Deke) that are least able to recover. When the
    /// mode is on, the frame tells the TUI "this is one pasted unit" so it cannot act on anything
    /// inside it half-way through.
    private static func typeBody(_ body: String, into view: LocalProcessTerminalView) {
        if view.getTerminal().bracketedPasteMode {
            view.send(txt: "\u{1B}[200~" + body + "\u{1B}[201~")
        } else {
            view.send(txt: body)
        }
    }

    /// Let the TUI absorb a paste (and draw its `[Image #N]` chip) before the next keystrokes.
    private static let attachSettleNanos: UInt64 = 150_000_000

    // MARK: The protocol

    /// Deliver `text` to `paneID` under an explicit `intent`, calling back with what really
    /// happened. The callback fires exactly once.
    ///
    /// `attachments` are file paths pasted first (bracketed, exactly like dropping a tray shot on the
    /// terminal) so Claude Code turns them into `[Image #N]`, then the text follows. Only for
    /// prompt / stage / control; ignored for submitOnly / answer. Both go through `sanitize`.
    static func write(_ text: String, intent: Intent, attachments: [String] = [], to paneID: UUID,
                      onOutcome: ((Outcome) -> Void)? = nil) {
        if case .answer(let approve) = intent {
            // Never wakes an asleep seat: a sleeping seat cannot be showing a dialog.
            guard let view = TerminalRegistry.shared.view(for: paneID) else { onOutcome?(.noPane); return }
            guard PermissionDialog.isVisible(in: view.screenText()) else {
                onOutcome?(.promptGone)
                return
            }
            view.send(txt: answerKey(approve: approve))
            Task {
                for _ in 0..<12 {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    if !PermissionDialog.isVisible(in: view.screenText()) {
                        onOutcome?(.landed)
                        return
                    }
                }
                onOutcome?(.unverified)
            }
            return
        }
        guard let view = TerminalRegistry.shared.view(for: paneID) else {
            onOutcome?(.noPane)
            return
        }

        let attach = !attachments.isEmpty && (intent == .stage || intent == .prompt || intent == .control)
        if attach { typeBody(sanitize(TerminalDrop.pasteText(forPaths: attachments)), into: view) }

        switch intent {
        case .stage:
            if attach, text.isEmpty { onOutcome?(.staged); return }
            if attach {
                Task {
                    try? await Task.sleep(nanoseconds: attachSettleNanos)
                    view.send(txt: sanitize(text))
                    onOutcome?(.staged)
                }
                return
            }
            view.send(txt: sanitize(text))
            onOutcome?(.staged)

        case .submitOnly:
            view.send(txt: "\r")
            // Nothing was typed, so there is no probe to verify against — a bare Return is the
            // user asserting something is already sitting at the prompt.
            onOutcome?(.landed)

        case .answer:
            break // handled above, before the sleep/wake branch

        case .prompt, .control:
            let body = sanitize(flatten(text))
            guard !body.isEmpty || attach else { onOutcome?(.staged); return }
            if !attach { typeBody(body, into: view) }   // no paste to wait for: type now, as before
            Task {
                if attach {
                    try? await Task.sleep(nanoseconds: attachSettleNanos)
                    if !body.isEmpty { typeBody(body, into: view) }
                }
                await settle(paneID: paneID)
                // Attachment-only: nothing typed to probe for, so press Return and say so honestly.
                let outcome = await submitAndVerify(paneID: paneID, probe: body.isEmpty ? "" : probe(for: body),
                                                    allowRetry: !body.isEmpty)
                onOutcome?(body.isEmpty && outcome != .landed && outcome != .noPane ? .unverified : outcome)
            }
        }
    }

    /// Wait for the composer to stop redrawing before pressing Return.
    ///
    /// Replaces a flat 350 ms guess. A long prompt makes an Ink-based TUI reflow and repaint for
    /// noticeably longer than a short one, and a Return that arrives mid-reflow is swallowed — the
    /// single most common way a prompt ended up parked in the composer. Quiet is defined as one
    /// poll with no new output; the 1.5 s ceiling keeps a chatty pane (a spinner already running
    /// from previous work) from stalling delivery forever.
    private static func settle(paneID: UUID) async {
        var last = screen(paneID, last: 400)
        for _ in 0..<6 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            let now = screen(paneID, last: 400)
            if now == last { return }
            last = now
        }
    }

    /// The distinctive fragment used to recognise the prompt still sitting in the composer.
    ///
    /// The tail is ANSI-stripped but still soft-wrapped, so a long needle would straddle a wrap and
    /// never match. The last few words are short enough to survive wrapping in one piece and are
    /// the part nearest the cursor, which is the part a composer keeps on screen.
    private static func probe(for body: String) -> String {
        let words = body.split(separator: " ").suffix(4).joined(separator: " ")
        return words.isEmpty ? String(body.suffix(24)) : words
    }

    /// Press Return, then decide from the pane's own output whether the seat took it.
    ///
    /// Acceptance is any ONE of three positives, in confidence order:
    /// 1. ``PaneTail/looksBusy(_:)`` — a spinner frame or an "esc to interrupt" hint. A TUI only
    ///    draws these once it has a turn to work on.
    /// 2. An agent event newer than the keystroke — the seat reported in through the agent hooks,
    ///    which is proof from the process itself rather than from its pixels.
    /// 3. The composer region no longer holds the probe while the tail has grown — the text moved
    ///    out of the input box and something else was printed.
    ///
    /// The third clause is deliberately the weakest, because of the trap that makes naive
    /// text-matching wrong here: after a SUCCESSFUL submit the prompt is still on screen, echoed as
    /// the user's turn. Presence of the text proves nothing; only its absence from the last few
    /// lines does. That is why a retry requires seeing the probe still in the composer region, and
    /// why "no evidence" resolves to ``Outcome/unverified`` rather than to another Return.
    private static func submitAndVerify(paneID: UUID, probe: String,
                                        allowRetry: Bool) async -> Outcome {
        guard let view = TerminalRegistry.shared.view(for: paneID) else { return .noPane }
        let before = screen(paneID, last: 2000).count
        let pressedAt = Date()
        // A seat that was ALREADY spinning when the prompt arrived (a prompt sent straight through
        // `send` rather than queued by `dispatch`) would satisfy the busy test on the very first
        // poll and report a landing we never witnessed. When it was busy before the keystroke,
        // busy after the keystroke proves nothing — fall back to the signals that do.
        let wasBusy = looksBusy(paneID)
        view.send(txt: "\r")

        // ~6 s of polling: long enough for a cold Claude seat booting MCP servers to draw its first
        // spinner, short enough that a genuinely stuck prompt is caught while the user still
        // remembers asking for it.
        for _ in 0..<24 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard TerminalRegistry.shared.view(for: paneID) != nil else { return .noPane }

            if !wasBusy, looksBusy(paneID) { return .landed }
            if let event = AgentRegistry.shared.latest[paneID], event.at > pressedAt {
                return .landed
            }
            let tail = screen(paneID, last: 2000)
            if tail.count > before + 24, !composerHolds(probe, in: tail) { return .landed }
        }

        let tail = screen(paneID, last: 2000)
        guard composerHolds(probe, in: tail) else { return .unverified }
        // Second guard before spending another Return: a pane that printed a screenful since the
        // keystroke DID something, even if we cannot name it, and the probe may simply be the
        // echoed user turn sitting at the bottom while the model thinks. Pressing Return into that
        // is the duplicate-submission failure — an empty turn at best, a repeated task at worst.
        // Retry only when the pane both still shows the words AND has stayed essentially silent.
        guard tail.count <= before + 200 else { return .unverified }
        guard allowRetry else { return .stuckInComposer }
        // One retry, and only here — we can see the words still sitting in a quiet box.
        return await submitAndVerify(paneID: paneID, probe: probe, allowRetry: false)
    }

    /// Whether `probe` appears in the composer region — the last few non-empty lines, which is
    /// where every TUI in the crew keeps its input box.
    ///
    /// Scoped to the tail's last lines on purpose: searching the whole buffer would match the
    /// echoed user turn of a submit that already succeeded and report every delivery as stuck.
    /// Comparison is whitespace-collapsed and case-folded so a soft wrap or a redraw that changes
    /// padding does not read as a different string.
    private static func composerHolds(_ probe: String, in tail: String) -> Bool {
        let region = tail
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(4)
            .joined(separator: " ")
        return normalized(region).contains(normalized(probe))
    }

    private static func normalized(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

extension PermissionDialog {
    /// The live screen as text: the END of the active buffer, whatever the viewport is scrolled
    /// to. Cells a renderer skipped with a cursor move come back as NUL, not space, so NUL becomes
    /// the space a person sees. (Lives here, not in NeedsYou.swift: SwiftTerm's `Color` collides
    /// with SwiftUI's.)
    static func screenText(_ terminal: Terminal) -> String {
        String(decoding: terminal.getBufferAsData(kind: .active).suffix(16_384), as: UTF8.self)
            .replacingOccurrences(of: "\u{0}", with: " ")
    }
}
