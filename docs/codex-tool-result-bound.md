# Codex Bash tool-result bound

The repository hook protects Bash results only. It receives Codex `PostToolUse` events and, only when a result is over 10 KiB, archives the exact textual result and returns bounded feedback through `continue: false` and `systemMessage`. Codex then replaces the original model-visible result with that feedback.

For a confirmed Firstmate Captain (`FM_HOME` is this Firstmate home, has state, and is not marked `.fm-secondmate-home`), archives are in `${FM_STATE_OVERRIDE:-$FM_HOME/state}/tool-results/<session-id>/`. Confirmed secondmates and any other context with `FM_HOME` are deliberately no-ops. Without `FM_HOME`, the runner protects ordinary direct Codex sessions and archives in `~/.codex/tool-results/<session-id>/`.

The installed Codex `PostToolUse` contract supplies `session_id`, `turn_id`, `tool_use_id`, `tool_name`, and `tool_response`; it runs for non-zero Bash exits too. This adapter only acts when `tool_response` is a string, so ambiguous response shapes pass through unchanged. Codex does not document a separate Bash exit-status field for this event, so the bounded replacement preserves the documented textual result but does not invent status metadata.

The tracked [hooks file](../.codex/hooks.json) covers trusted sessions launched in this repository. To protect ordinary direct Codex sessions elsewhere, add this single handler to the user's `~/.codex/hooks.json` without removing existing hooks, substituting the absolute path of this checkout:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "^Bash$",
        "hooks": [
          {
            "type": "command",
            "command": "node /absolute/path/to/firstmate/bin/fm-codex-post-tool-use.mjs",
            "timeout": 30
          }
        ]
      }
    ]
  }
}
```
