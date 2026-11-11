These are real Swift Testing console outputs or verbatim excerpts, saved for parser
and fake-command replay tests. No failing test was added to `Tests/`.

- `all-pass.log`: this checkout, 2026-11-08, one passing test selected by an exact
  filter (`SpawnParseTests/parsesEveryWireKey()`).
- `one-fail.log`: this checkout, same session, one failing test selected with
  `--filter AgentHooksTests/preToolUseBashCarriesTheCommand`. The sandbox refuses
  its Unix socket listener. The Swift Testing run completes and reports one failure.
- `retry-pass.log`: verbatim test excerpt, suite boundaries and summary from the
  existing real True suite output `/private/tmp/m0-test.log` (1599 passing tests).
  It contains the same test that fails in `one-fail.log`. This older captured output
  is replay evidence, not a claim that the current sandbox run passed.
- `crash.log`: verbatim crash diagnostics from this checkout's full suite in this
  session: SwiftPM reports unexpected signal 5 and Swift reports index out of range
  after sandbox-refused network/socket operations in AllowanceTests.
- `hang.log`: verbatim suite/test-start excerpt from that full run. The fake command
  prints it then stays running beyond the configured cap; timeouts have no special
  Swift Testing output to synthesize.
- `build-failure.log`: this checkout's real `swift build` failure because the default
  compiler module cache is outside writable sandbox roots.
- `zero-tests.log`: real output of an incorrectly end-anchored filter. This proves
  an exit-zero command with no selected tests cannot make the gate green.

The command double replays these outputs and returns the matching exit status. For
fail-then-pass it replays `one-fail.log`, then `retry-pass.log` when the gate supplies
`--filter`. For permanent failure it replays `one-fail.log` both times.

Swift Testing appends source-location components to its internal test identifier.
For this toolchain the working exact filter is:

```
swift test --no-parallel --filter '(?:^|\.)(?:SpawnParseTests/parsesEveryWireKey\(\))(?:/|$)'
```

Both ends are bounded to avoid selecting another suite or a longer function name;
the trailing slash permits Swift Testing's source-location component. The same
form applies to failed test names. A bare `$` after `()` selected zero tests.

Run policy/parser/integration tests with `python3 -m unittest discover scripts/tests`.
The release integration fixture runs the actual release script, gate wrapper and
Python gate, substituting only checkout operations and Swift commands. It verifies
that the default is `scripts/gate.sh`, that `TRUE_GATE_CMD` still overrides it, and
that the result remains after the temporary tree is removed.
