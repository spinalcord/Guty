# GUT MCP (Godot 4.7, GUT 9.7.1)

The GUT editor plugin includes a standalone local MCP server. It does not require or integrate with `godot_mcp`; it manages GUT tests and reads debugger diagnostics for tests and normal game sessions. The Godot editor must be open and responsive.

## Connect

1. Enable GUT under **Project → Project Settings → Plugins**.
2. Check **GUT MCP** in the GUT panel. The server is disabled by default.
3. Keep port **9081**, or choose another port. The adjacent label shows the connection URL or an error if the port cannot be opened.
4. Configure your MCP client to use Streamable HTTP at `http://127.0.0.1:9081/mcp`. For clients that use `mcpServers` configuration:

```json
{"mcpServers":{"gut":{"url":"http://127.0.0.1:9081/mcp"}}}
```

The server returns JSON, without SSE streams or session IDs. It negotiates protocol versions `2025-11-25`, `2025-06-18`, and `2025-03-26`. After `initialize`, the client sends `notifications/initialized`; subsequent requests include `MCP-Protocol-Version`. POST requests need `Content-Type: application/json` and `Accept: application/json, text/event-stream`. GET and DELETE return 405. See the [MCP transport specification](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports).

The server binds only to `127.0.0.1`. Requests without an Origin header are allowed for local clients. If present, Origin must be `http://127.0.0.1:<port>` or `http://localhost:<port>`; other Origins return 403. The server does not require authentication. HTTP requests have a five-second connection limit, up to 16 concurrent connections, 16 KiB of headers, and a 1 MiB request body. These limits do not limit test run time.

## Tools

All arguments are optional. Unknown arguments, wrong types, and unknown run IDs return a tool error (`isError: true`). Results are returned as JSON in `content` and in `structuredContent`.

| Tool | Arguments | Result |
|---|---|---|
| `gut_get_config` | None | Test directories and scripts, file filters, current selection filters, versions, server status, recent run IDs |
| `gut_list_tests` | `script`, `inner_class`, `test_name`, `offset`, `limit` | Recognized tests with script path, inner class, and method name |
| `gut_run_tests` | `script`, `inner_class`, `test_name`, `close_on_finish`, `ignore_pause` | Immediate `run_id` and `starting` state |
| `gut_get_run_status` | `run_id` | State, current test, elapsed time, progress, debugger pause, diagnosis ID and last break reason, window status, stop request |
| `gut_get_debug_sessions` | None | Active and recent diagnostics with `debug_id`, Godot `session_id`, optional `run_id`, and state |
| `gut_get_debug_info` | `debug_id` or `run_id` | Last break reason and stacktrace with file, line, function, and `stacktrace_current` |
| `gut_get_debug_output` | `debug_id` or `run_id`, `category`, `offset`, `limit` | A page of debugger output, errors, and warnings with their source |
| `gut_get_results` | `run_id`, `section`, `offset`, `limit` | Summary and one page of results or output; `incomplete` marks partial results |
| `gut_continue` | `run_id` | Resumes a GUT pause before teardown |
| `gut_stop` | `run_id` | Stops a GUT run or closes its results window |

`script` must be an existing `res://...gd` path. Without it, the server uses GUT's configured test directories and explicit test scripts. Providing a script replaces the directory selection for that run. `inner_class` uses GUT's case-insensitive substring filter; `test_name` uses its case-sensitive substring filter. Empty filters include all tests. An empty selection returns a clear error.

MCP runs default to `close_on_finish=true` and `ignore_pause=true`; set either to `false` to override it for one run. GUT's saved panel configuration is not changed. Internal runs started from the GUT panel are registered too; external shell and CLI runs are outside this interface.

Without `run_id`, run-specific tools use the current or most recent run. `section` can be `tests` (default), `warnings`, `errors`, or `output`. `offset` starts at 0; `limit` ranges from 1 to 100 (default 50). `next_offset` gives the next position or `null`. Output is returned in 4096-character chunks. A page is limited to about 60 KiB; large items are shortened and marked with `page_truncated`. Individual strings are limited to 4096 characters and nested lists to 100 items. Each run stores up to 262144 characters of GUT output, with truncation marked by `output_truncated`. This is GUT's GUI and test output; direct `print()` and `printerr()` calls are available through `gut_get_debug_output`.

## Workflow: start → status → results → stop if needed

```text
gut_list_tests({"script":"res://test/test_inventory.gd"})
gut_run_tests({"script":"res://test/test_inventory.gd","test_name":"save"})
→ {"run_id":"…","state":"starting"}
gut_get_run_status({"run_id":"…"})
gut_get_results({"run_id":"…","section":"tests","limit":20})
gut_get_results({"run_id":"…","section":"output"})
```

Poll status as needed. States are `starting`, `running`, `gut_paused`, `debugger_paused`, `completed`, `aborted`, and `runtime_error`. `completed` means the test run ended; failed assertions appear in the summary and test results. `window_open` is reported independently from the test result. `debugger_paused` is also reported as a Boolean. `gut_continue` resumes a GUT pause only; it does not continue a debugger break.

Set `ignore_pause=false` to stop at a test's pre-teardown pause:

```text
gut_run_tests({"script":"res://test/test_inventory.gd","ignore_pause":false})
gut_get_run_status({"run_id":"…"})
→ state: gut_paused
gut_continue({"run_id":"…"})
```

There is no automatic test run timeout. Call `gut_stop` when you decide to stop a hanging test. The runner first saves partial results and requests a graceful stop. If it does not respond within two seconds, the editor stops only the associated GUT run through `stop_playing_scene()`. With `close_on_finish=false`, the same tool closes the remaining results window. Repeated stops on closed or old runs are safe and cannot stop another session. A new run cannot start while a game or test window is open.

The last ten runs are stored separately under `user://gut_temp_directory/mcp/`. Each run has its own config, status, and snapshots. The runner saves a final snapshot before closing; the editor also reads it if the debugger session disconnects. Partial results received or saved before a forced stop remain available. Existing GUT result files continue to feed the GUT panel. Disabling the plugin shuts down the server and debugger bridge, and stops only an associated open GUT run. Unchecking GUT MCP stops only the HTTP server.

A responsive editor can stop a blocked test process. A fully blocked editor cannot answer MCP requests.

## Workflow: select session → read diagnosis → read messages

```text
gut_get_debug_sessions({})
gut_get_debug_info({"debug_id":"debug-…"})
gut_get_debug_output({"debug_id":"debug-…","limit":50})
gut_get_debug_output({"run_id":"…","category":"error"})
```

`debug_id` and `run_id` are mutually exclusive. With neither selector, these tools select the newest active diagnosis, otherwise the latest stopped one. Unknown IDs return a tool error. A known run without a debugger diagnosis returns empty data. With no sessions, info returns `{}` and output returns an empty page. Session listing uses `items`; states are `running`, `paused`, and `stopped`.

Each session start gets a new diagnosis ID, even when Godot reuses its session ID. The editor retains the last ten diagnoses; GUT diagnoses also persist with the last ten runs. Break reasons, the last stacktrace, and captured messages remain readable after stopping. `stacktrace_current` is true only when the stack belongs to the current debugger pause. Continuing or stopping makes it historical; a new pause invalidates it until a new stack arrives. Large stacks are marked by `stacktrace_truncated`.

Output categories are `stdout` (including rich text), `stderr`, `error`, and `warning`. Each entry identifies `debugger_output` or `debugger_error_tree` as its `source`. Repeated reads of an error tree do not duplicate messages; repeated print calls and distinct error occurrences remain separate. The last 500 messages are retained per diagnosis. `messages_dropped` and `output_truncated` identify discarded messages; long messages have `truncated: true`. Output uses the existing page and string size limits.

Diagnostics provide read access only. They do not continue a debugger, inspect variables, or force a stacktrace from a hung process. A fresh stacktrace requires an actual debugger pause. A responsive editor can return existing output from a blocked test; a blocked editor cannot answer MCP requests. The bridge uses private editor signals and error-tree metadata verified with Godot 4.7; future editor changes may require updating it. The [Godot debugger source](https://github.com/godotengine/godot/blob/master/editor/debugger/script_editor_debugger.cpp) defines those signals and metadata.

## Verification

From the project directory, run with Godot 4.7 (use the full path to Godot if it is not on `PATH`):

```sh
godot --headless --path . --script tests/mcp/check_scripts.gd
godot --headless --path . --script tests/mcp/test_protocol.gd
godot --headless --path . --script tests/mcp/test_manager.gd
godot --headless --path . --script tests/mcp/test_runtime.gd
# In an isolated copy of this project, with godot_mcp disabled:
godot --headless --editor --path . --script tests/mcp/test_debug_editor.gd
```

Use a separate `XDG_DATA_HOME` for harness tests; the manager test clears its test history. The runtime harness runs filtered tests and has its own watchdog. The production server has no test run watchdog.

`tests/mcp/test_fixture.gd` contains intentional failures, a pause, a waiting test, and an infinite loop. Run it only with a matching `test_name` filter; do not configure it as a regular test directory.

With the editor open and GUT MCP enabled, run this client to check real HTTP, debugger, and editor connections:

```sh
python3 tests/mcp/live_smoke.py --url http://127.0.0.1:9081/mcp
```

The client checks initialization, all ten tools, filters, successful/failed/pending tests, pause and resume, automatic window close, result retrieval, waiting and blocking tests with explicit stops, and repeated closing of a results window. Also check a port conflict (open another editor on the same port), normal game sessions during tool requests, panel runs, and plugin disable in the editor. Disable or remove `godot_mcp` to verify independence. For a CLI regression check, run the fixture with `-gtest=res://tests/mcp/test_fixture.gd -gunit_test_name=success -gexit`.

The editor harness starts normal game scenes, tests errors without pause, print/printerr, a real breakpoint, an assertion with stacktrace, session reuse, a blocking GUT test, cleanup, and the HTTP live suite on port 19081. Run it in an isolated project with separate `XDG_CONFIG_HOME` and `XDG_DATA_HOME`; child game processes require a working display. The two `debug_*.tscn` scenes deliberately generate errors.
