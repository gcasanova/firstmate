# Claude Code Captain context meter

When Claude Code runs a confirmed Firstmate Captain, the tracked project `statusLine` command renders a local footer line. It receives Claude Code's status-line `context_window.context_window_size` and `context_window.used_percentage`, then measures `round(context_window_size * used_percentage / 100)`. Those are Claude's authoritative current-context fields. It deliberately ignores `total_input_tokens`, output tokens, costs, billing data, and transcript data.

The status line is terminal UI only: its stdout is footer text, never hook output, a prompt, or a model message. The adapter is inert unless `FM_HOME` confirms the Captain home through `lib/fm-captain-scope.mjs`; secondmates, worktrees, and ambiguous homes get no output or state.

The shared `lib/fm-context-meter.mjs` owns the 75k, 120k, and 160k thresholds and one-warning-per-threshold behavior. Since status commands are separate processes, `state/claude-context-meter.json` stores only notified threshold ids and the previous token estimate. It is atomically replaced. A reset re-arms the shared meter only when the current value drops by at least 40,000 tokens and to at most 60% of the previous value. Smaller fluctuations do not re-arm it.

Pi measures the exact per-request prompt components (`input + cacheRead + cacheWrite`) and has an explicit compaction event. Claude's status-line API supplies current-window percentage instead, so its estimate is rounded to the percentage resolution and its reset is deterministic drop detection rather than an explicit compaction event.
