import Foundation

/// Codex CLI 0.167.0, foreground PTY captures on 2026-11-09.
enum CodexRecordings {
    static let dialog = #"""
    >_ OpenAI Codex (v0.167.0)
         ~/Projects/true.builders/codex-seats-core-20261108-025454/.out/codex-seats-spike
    
      Tip: When voice is available, use /voice to start or stop a voice conversation, or /voice settings to choose a voice.
    
    
    › Use the shell tool to request approval with sandbox_permissions require_escalated to run printf APPROVAL_OK.
      Justification: True seat approval capture. Request approval explicitly; do not run without it.
    
    
    • I’ll request explicit approval to run printf APPROVAL_OK. ROLE_CARD_OK
    
    ◦ Running printf APPROVAL_OK
    
    
      Would you like to run the following command?
    
      Environment: local
    
      Reason: True seat approval capture.
    
      $ printf APPROVAL_OK
    
    
    › 1. Yes, proceed (y)
      2. Yes, and don't ask again for commands that start with `printf APPROVAL_OK` (p)
      3. No, and tell Codex what to do differently (esc)
    
      Press enter to confirm or esc to cancel
    """#
    static let busy = #"""
    >_ OpenAI Codex (v0.167.0)
         ~/Projects/true.builders/codex-seats-core-20261108-025454/.out/codex-seats-spike
    
      Tip: Use the desktop app. Run codex app to open it. It installs automatically if needed.
    
    
    › Remember ORCHID_QUARTZ. Run sleep 25 then printf TOO_LATE in a shell tool, wait for it, then reply briefly.
    
    
    • I’ll remember ORCHID_QUARTZ for this conversation and run the command. ROLE_CARD_OK
    
    ◦ Working (5s • esc to interrupt)
    
    
    › Ask Codex to do anything
    
      GPT-6-Astra medium · main · Context 100% left · 0 in · 0 out · 5h 62% left · weekly 65% l…  ⚠ 5 warnings · f2 to view
    """#
    static let payloads = #"""
    [{"session_id":"01a1bf45-d682-7c00-a00a-a7eb9f477bf5","transcript_path":"/recorded/codex/rollout.jsonl","cwd":"/recorded/repo","hook_event_name":"SessionStart","model":"gpt-6-astra","permission_mode":"default","source":"startup"},{"session_id":"01a1bf45-d682-7c00-a00a-a7eb9f477bf5","turn_id":"01a1bf45-d6d0-7fa0-a872-db511bfe9214","transcript_path":"/recorded/codex/rollout.jsonl","cwd":"/recorded/repo","hook_event_name":"UserPromptSubmit","model":"gpt-6-astra","permission_mode":"default","prompt":"Use the shell tool to request approval with sandbox_permissions require_escalated to run printf APPROVAL_OK. Justification: True seat approval capture. Request approval explicitly; do not run without it."},{"session_id":"01a1bf45-d682-7c00-a00a-a7eb9f477bf5","turn_id":"01a1bf45-d6d0-7fa0-a872-db511bfe9214","transcript_path":"/recorded/codex/rollout.jsonl","cwd":"/recorded/repo","hook_event_name":"PreToolUse","model":"gpt-6-astra","permission_mode":"default","tool_name":"Bash","tool_input":{"command":"printf APPROVAL_OK"},"tool_use_id":"exec-39382b66-5dd7-4327-a0aa-0a1c69c36852"},{"session_id":"01a1bf45-d682-7c00-a00a-a7eb9f477bf5","turn_id":"01a1bf45-d6d0-7fa0-a872-db511bfe9214","transcript_path":"/recorded/codex/rollout.jsonl","cwd":"/recorded/repo","hook_event_name":"PermissionRequest","model":"gpt-6-astra","permission_mode":"default","tool_name":"Bash","tool_input":{"command":"printf APPROVAL_OK","description":"True seat approval capture."}},{"session_id":"01a1bf45-d682-7c00-a00a-a7eb9f477bf5","turn_id":"01a1bf45-d6d0-7fa0-a872-db511bfe9214","transcript_path":"/recorded/codex/rollout.jsonl","cwd":"/recorded/repo","hook_event_name":"Stop","model":"gpt-6-astra","permission_mode":"default","stop_hook_active":false,"last_assistant_message":"Requested approval with `require_escalated`; command returned `APPROVAL_OK`.\n\nROLE_CARD_OK"},{"session_id":"01a1bf46-352f-79f1-923b-c3b0278cb43e","turn_id":"01a1bf46-357c-78b3-9d8c-d378390c02e9","transcript_path":"/recorded/codex/rollout.jsonl","cwd":"/recorded/repo","hook_event_name":"Interrupt","model":"gpt-6-astra","permission_mode":"bypassPermissions"}]
    """#
}
