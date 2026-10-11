# MCP Integration Verification

Run on 2026-10-11 with Godot `4.7.stable.official.5b4e0cb0f` with GUT 9.7.1.

| Check | Result |
|---|---|
| All new GDScripts and changed plugin, panel, and runner scripts load | Passed |
| HTTP parser and JSON-RPC with simulated transport | Passed: initialization, version negotiation, ping, tools, notifications, UTF-8, partial transfers, invalid requests, Origins, size limits, GET/DELETE |
| Port conflict error path | Passed with simulated `ERR_ALREADY_IN_USE`; real port conflict remains unverified |
| Run manager with simulated editor control | Passed: all seven tools, arguments, unknown IDs, native GUT test discovery, script/class/name filters, empty selection, pause, debugger pause, two-second stop, protection of other sessions, restart, snapshot recovery, page limits, ten-run history |
| Real GUT runner without network | Passed: success, assertion failure details, pending tests, warnings, output, progress, real teardown pause/resume, open results window, graceful stop of a waiting test, save before quit |
| Isolated real headless editor without `godot_mcp` | Passed: panel, manager, and debugger bridge initialize; MCP defaults off; port 9081; disabling the plugin cleans up the manager |
| Existing GUT CLI invocation with MCP disabled | Passed: two filtered tests, exit code 0 |
| Python live client against the running editor | Passed: handshake, all seven tools, validation and Origin errors, test filters, success/failure/pending results, warnings, output, GUT pause/resume, stopping waiting/blocking tests, open-window close, repeated stop protection |

An earlier sandbox prevented local network sockets. The live test has now confirmed HTTP and editor-to-test-process communication against the running editor.

The full live smoke suite passed against the running editor. Real port conflicts, normal game sessions, and disabling the plugin during an active run remain manual editor checks.

## JSON-RPC response ID fix (2026-10-11)

Godot parses JSON numbers as floats. Success and error responses now convert integral numeric IDs back to `int` before serialization; string and null IDs stay unchanged. Protocol tests inspect the transmitted JSON tokens because parsing the response again in Godot would hide this type difference.

- Before the fix: 21 failed response ID checks.
- After the fix: GDScript load, protocol, and run manager checks passed.
- The Python live client also checks the integer type and value of every response ID.
- Focused the running editor; the real HTTP handshake then returned `"id":1`.
- The live server lists all seven `gut_*` tools. `gut_get_config` and `gut_list_tests` both succeeded. String IDs and numeric error IDs were also verified.
- The full `live_smoke.py` suite passed against the live editor after the ID fix.
