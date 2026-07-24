# Independent Codebase Audit — 2026-07-24

Repository: `claude-standby`  
Audited tree: `/Users/sazzad/Documents/claude-auto-resume`  
Version in working tree: `0.9.4`  
Audit mode: independent, read-only verification of the live working tree,
including uncommitted changes

No implementation, test, configuration, or existing documentation file was
modified during the audit. This report was added afterward at the user's
request.

## Verification summary

- Read `CLAUDE.md` and all documents under `docs/` before auditing the
  implementation.
- Inspected the CLI, installer, all engine scripts, VS Code cockpit, test
  harness, metadata, release workflow, and packaged VSIX.
- `bash -n` passed for all 13 shell entry points under Apple Bash 3.2.57.
- `node --check` passed for `extension.js`, `dashboard.js`, and
  `cockpit-smoke.js`.
- `git diff --check` passed.
- `VERSION` and the extension version agree at `0.9.4`.
- The full suite was run twice with isolated state, log, rate, settings,
  project-store, configuration, and transcript paths. Both runs produced:

  ```text
  286 passed, 0 failed
  ```

- Both complete test outputs had SHA-1:
  `4934b959ffd8c69c7693ac2fd954d7763ea7e710`.
- All hands-on daemon and CLI probes used `test/fake-claude.sh`; no real Claude
  invocation was made.
- An initial status-line fixture inherited the default settings path because of
  zsh word-splitting behavior. The sandbox denied both attempted writes, so the
  real settings file was not modified. The fixture was rerun with explicit
  temporary paths.

No blocker was found, but the number and nature of high-severity findings make
the current tree unsuitable for release without further hardening.

## 1. Correctness and logic

### F01 — High — Rate detection — The advertised zero-probe rate path still probes at reset

**Location:** `plugin/scripts/daemon.sh:207`,
`plugin/scripts/lib.sh:720`

**Claim:** A static F4 rate snapshot cannot reach the daemon's local
reset-reached branch; the daemon makes a successful Claude probe before
resuming.

**Evidence:** `ar_rate_usable` rejects a snapshot as soon as
`resets_at <= now`. When the daemon wakes at `resets_at + grace`, the fixed
snapshot is therefore unusable and the branch at daemon lines 230–237 cannot
be reached unless another status-line update replaced the snapshot.

An isolated already-limited task with an expired rate snapshot produced:

```text
final_status=done
fake_invocations=2
journal=scheduled,limit-lifted,resumed,done
```

The two fake invocations were the supposedly unnecessary probe and the actual
resume.

**Trigger/repro:** Mark an auto task `limit_seen=1`, give it a past
`resets_at` snapshot and a due `resume_at`, then run the daemon against
`test/fake-claude.sh` in clean mode.

**Recommended remediation:** Persist the trusted sensor reset deadline
separately and transition to a due state at that deadline, or explicitly
change the task to fixed-time mode after sensor detection. Add a test that
advances beyond a static `resets_at` and asserts exactly one Claude
invocation.

### F02 — High — Scheduling/portability — Leading-zero times are interpreted as octal

**Location:** `plugin/scripts/task-resume-at.sh:74`,
`plugin/scripts/task-resume-at.sh:85`

**Claim:** Common times beginning with `08` or `09` are rejected or silently
scheduled at midnight.

**Evidence:**

```text
07:30 -> 07:30 next occurrence
08:30 -> printf: 08: invalid number -> scheduled 00:30
09:15 -> printf: 09: invalid number -> scheduled 00:15
08h   -> value too great for base -> rejected
09h   -> value too great for base -> rejected
```

This occurred under the required macOS Bash 3.2 runtime.

**Trigger/repro:** Run `task-resume-at.sh` with `AR_PARSE_ONLY=1` and pass
`08:30`, `09:15`, `08h`, or `09h`.

**Recommended remediation:** Validate fields and explicitly convert decimal
numbers using a leading-zero-safe method before `printf` or arithmetic. Add
tests for `08`, `09`, invalid ranges, and both clock and relative forms.

### F03 — High — Session integrity — Session resolution is not fail-closed

**Location:** `plugin/scripts/lib.sh:561`,
`plugin/scripts/lib.sh:607`,
`plugin/scripts/task-resume-at.sh:155`,
`plugin/scripts/task-resume-at.sh:190`

**Claim:** The tool can pin another workspace's session, accept a malformed
session identifier, or silently start a new chat.

**Evidence:**

- Lossy project-directory encoding is not followed by a `cwd` check. Two
  workspaces named `a-b` and `a_b` mapped to the same session directory.
  Scheduling from `a_b` produced:

  ```text
  expected_session=22222222-2222-2222-2222-222222222222
  pinned_session=11111111-1111-1111-1111-111111111111
  ```

- `grep -i "^$want"` interprets the user's session prefix as a regular
  expression, while `head -1` ignores ambiguity. Both `--session '.*'` and a
  shared prefix selected the newest session.
- The UUID regex accepts strings made entirely of hyphens.
- When no session exists, an implicit schedule proceeds with a new chat even
  though the primary product contract is resuming the same session.

**Trigger/repro:** Create colliding encoded workspace paths or two session IDs
with the same prefix, then schedule without an exact canonical UUID.

**Recommended remediation:** Inspect and require an exact matching `cwd` from
each session JSONL, enforce canonical UUID syntax, perform fixed-string prefix
matching, reject ambiguous prefixes, and refuse an empty session unless the
user explicitly passed `--session new`.

### F04 — High — Task lifecycle — `start` preserves stale session and cycle state

**Location:** `plugin/scripts/task-start.sh:23`,
`plugin/scripts/task-resume-at.sh:190`

**Claim:** Starting a new task in an already-used workspace can later resume
the previous task's conversation.

**Evidence:** After scheduling an old task, starting a new task in the same
workspace, and creating a newer Claude session:

```text
after_start status=running pinned=OLD latest=NEW
after_reschedule pinned=OLD expected_latest=NEW
```

The comment says `session_id` stays empty, but the upsert does not clear an
existing value. A custom old resume prompt and other cycle fields can also
survive.

**Trigger/repro:** Schedule a task with a pinned session, run `start` for a new
task in the same directory, create a newer session, then schedule without
`--session`.

**Recommended remediation:** Define a complete new-task reset operation that
clears session identity, resume prompt overrides, scheduling/detection fields,
daemon ownership, and attempt state.

### F05 — High — Rescheduling — A changed schedule can still execute the old resume

**Location:** `plugin/scripts/daemon.sh:341`,
`plugin/scripts/daemon.sh:365`

**Claim:** Rescheduling during grace or an in-flight resume does not prevent
the old quota-consuming action.

**Evidence:**

- Rescheduling one hour ahead during a three-second normal grace still ran
  Claude and ended `done`.
- Rescheduling one hour ahead during an in-flight resume left the new task
  `waiting`, but the old Claude process completed.

```text
grace repro: final_status=done resume_count=1 fake_runs=1
in-flight repro: final_status=waiting resume_count=0 completed_fake_runs=1
```

The grace check verifies only `status=waiting`, not that the schedule being
serviced is unchanged. In-flight rescheduling does not terminate the old
process.

**Trigger/repro:** Schedule a normal task with a short grace or a slow fake
resume, wait until grace/resuming, then reschedule an hour ahead.

**Recommended remediation:** Give each schedule a generation/token, revalidate
it immediately before execution and after grace, and make rescheduling
explicitly cancel and wait for the previous generation/process group.

### F06 — Medium — Cockpit correctness — The composer can silently change user intent

**Location:** `vscode-extension/extension.js:290`,
`vscode-extension/dashboard.js:1072`,
`vscode-extension/dashboard.js:1145`

**Claim:** Scheduling from the cockpit can replace an older pinned session or
turn an invalid time into auto-detection without warning.

**Evidence:**

- Only six sessions are sent to the dashboard. If a pinned session is older,
  `fillSessions` selects the newest visible session and scheduling always
  submits it.
- An invalid custom time silently becomes `auto`, potentially starting
  quota-bearing probes rather than reporting a validation failure.

**Trigger/repro:** Pin a session older than the six newest, or enter an invalid
hour/minute after clearing the preset chips, then submit.

**Recommended remediation:** Always include the pinned session even outside
the display cap, track whether the user actually changed it, and surface
invalid time fields without submitting anything.

### F07 — Medium — Reset timing — DST transitions can shift a reset by one hour

**Location:** `plugin/scripts/lib.sh:75`,
`plugin/scripts/lib.sh:91`

**Claim:** A reset scheduled across a daylight-saving transition can use the
wrong timezone offset.

**Evidence:** The parser uses the zone's current offset and adds exactly 86,400
seconds for tomorrow. The code comment acknowledges the possible one-hour
skew.

**Trigger/repro:** Parse a next-day wall-clock reset immediately before a DST
offset transition in the named IANA zone.

**Recommended remediation:** Construct the target wall-clock time using the
named timezone and target date, then let a timezone-aware parser determine the
target-date offset.

### F08 — Medium — CLI correctness — `watch` fails on a fresh runtime directory

**Location:** `bin/claude-standby:145`

**Claim:** `claude-standby watch` cannot initialize its log path on a fresh
installation.

**Evidence:**

```text
watch_rc=1
tail: .../missing/logs/plugin.log: No such file or directory
```

`touch` fails because its parent directory is not created, and the failure is
ignored before `tail -f`.

**Trigger/repro:** Point `CLAUDE_STANDBY_LOG_DIR` to a nonexistent nested
directory and run `watch`.

**Recommended remediation:** Create the log directory first and report a clear
nonzero error if that fails.

## 2. Security

### F09 — High — Process safety — Cancel trusts an unauthenticated PID

**Location:** `plugin/scripts/task-cancel.sh:32`

**Claim:** A stale or tampered pidfile can cause cancellation to signal
unrelated processes.

**Evidence:** Pidfile content is neither validated as a positive PID nor
verified as this workspace's daemon. PID reuse can target an unrelated
process. Values such as `0` or `-1` have process-group or broad signalling
semantics for shell `kill`.

**Trigger/repro:** Replace or stale-reuse the workspace pidfile before running
`cancel`. A destructive live repro was intentionally not performed.

**Recommended remediation:** Require a positive PID greater than one, validate
process identity/start time/workspace token, create a dedicated process group,
and signal only an ownership-validated group.

### F10 — High — Webview security — State values produce executable HTML

**Location:** `vscode-extension/dashboard.js:517`,
`vscode-extension/dashboard.js:625`,
`vscode-extension/dashboard.js:790`

**Claim:** JSON-valid but malicious state/config strings can become executable
webview markup under the current CSP.

**Evidence:** Direct rendering produced:

```text
payload_literal=true
unsafe_inline_csp=true
javascript_href=true
<span class="dim mono att"><img src=x onerror=globalThis.PWNED=1>/3</span>
```

`resume_count` and `max_resumes` are inserted without escaping, while CSP
allows inline scripts. Configurable About URLs are escaped for HTML but not
restricted to safe schemes.

**Trigger/repro:** Put an HTML event-handler string into a JSON-valid numeric
field or configure an About URL using a script-capable scheme, then render the
dashboard.

**Recommended remediation:** Escape every contract/config value, validate
state field types before rendering, use a nonce-based CSP without
`unsafe-inline`, and allowlist `https:` URLs.

### F11 — High — Command injection — Terminal commands interpolate executables unquoted

**Location:** `vscode-extension/extension.js:530`,
`vscode-extension/extension.js:742`,
`vscode-extension/package.json:136`

**Claim:** Configurable command paths can break or inject shell syntax through
`term.sendText`.

**Evidence:** Both `${claude} --resume ...` and `${cliPath()} update` are
passed as terminal text. A path containing spaces breaks; shell metacharacters
in an environment value or workspace-configured `cliPath` become commands.

**Trigger/repro:** Set `CLAUDE_STANDBY_CLAUDE_BIN` or
`claudeStandby.cliPath` to a string containing spaces or shell control
characters, then use the corresponding cockpit action.

**Recommended remediation:** Avoid shell command synthesis where possible.
Otherwise apply platform-correct shell quoting and disallow unsafe
workspace-scoped command paths, especially in untrusted workspaces.

### F12 — High — Installer safety — Environment overrides can target destructive broad paths

**Location:** `install.sh:30`, `install.sh:103`, `install.sh:159`

**Claim:** A mistaken installer override can recursively delete a home or other
broad directory.

**Evidence:** `CAR_INSTALL_DIR` is used directly in
`rm -rf "$INSTALL_DIR"` without canonical-path or sentinel validation. A
mistaken `CAR_INSTALL_DIR=$HOME` can erase the home directory after staging
succeeds.

**Trigger/repro:** Supply a broad existing path through `CAR_INSTALL_DIR`.
A destructive live repro was intentionally not performed.

**Recommended remediation:** Canonicalize and reject empty, root, home,
workspace-root, and other broad paths; require an install sentinel before
update/uninstall; apply similar validation to link targets.

### F13 — Medium — Local trust/confidentiality — Runtime files and the common cache are insufficiently protected

**Location:** `plugin/scripts/lib.sh:204`,
`plugin/scripts/lib.sh:664`,
`plugin/scripts/statusline.sh:47`

**Claim:** Sensitive runtime data can be world-readable, and an unowned
predictable `/tmp` cache can influence detection.

**Evidence:** Under `umask 022`, isolated state, rate, and log files were all
mode `0644`. They can contain prompts, session IDs, output tails, and
arguments. `/tmp/claude_rate_cache_$USER.json` is accepted without owner,
mode, freshness, or reset-horizon validation.

**Trigger/repro:** Initialize state/log/rate files under a normal `022` umask,
or pre-create the predictable common cache before the user does.

**Recommended remediation:** Set `umask 077`, enforce private directories and
files, use secure temporary creation, and validate ownership plus a plausible
five-hour horizon before trusting an external cache for detection.

## 3. Portability and compatibility

### F14 — Medium — Process portability — Immediate cancellation depends on `pgrep`

**Location:** `plugin/scripts/task-cancel.sh:37`

**Claim:** Without functional `pgrep`, cancelling a daemon sleeping on a long
tick is not immediate.

**Evidence:** In the process-restricted sandbox, the suite failed
`cancel: kills waiting daemon immediately` and the daemon remained behind a
600-second sleep. The two complete runs outside that restriction passed.
Without `pgrep`, the sleep child is not killed and Bash may defer its trap
until the foreground child returns.

**Trigger/repro:** Run cancellation where `pgrep -P` is absent or denied while
the daemon is inside a long `sleep`.

**Recommended remediation:** Start the daemon/resume in a dedicated process
group and kill the validated group. Do not make immediate cancellation depend
on optional `pgrep` or a fixed two-level descendant walk.

All syntax otherwise passed on macOS Bash 3.2. No additional confirmed
GNU-only runtime failure was found, but Linux was not executed.

## 4. Concurrency and state integrity

### F15 — High — State integrity — Atomic rename does not prevent lost updates

**Location:** `plugin/scripts/lib.sh:509`,
`plugin/scripts/lib.sh:533`

**Claim:** Concurrent supported writers overwrite each other's task and
journal changes.

**Evidence:** Forty simultaneous valid jq-engine task upserts produced:

```text
round 1: expected=40 actual=3
round 2: expected=40 actual=4
round 3: expected=40 actual=4
```

Every writer independently reads, modifies, and replaces the entire file.

**Trigger/repro:** Start multiple processes that upsert distinct task keys in
the same state file at the same time.

**Recommended remediation:** Lock the complete read-modify-write transaction
using a Bash-3.2/macOS-compatible lock strategy, or introduce revision-based
compare-and-swap with retry.

### F16 — High — Daemon ownership — The pidfile protocol has a TOCTOU race

**Location:** `plugin/scripts/daemon.sh:58`

**Claim:** Concurrent schedules can start duplicate daemons and cause either
daemon to remove the other's pidfile.

**Evidence:** Two processes can both observe no live pidfile, both overwrite
it, and both run. Each exit trap blindly removes the shared file. An alive
recycled PID also prevents the real daemon from starting.

**Trigger/repro:** Invoke schedule concurrently for the same workspace before
either daemon has completed pidfile acquisition.

**Recommended remediation:** Acquire an atomic lock directory/file, store an
ownership token and process start identity, and only let the matching owner
remove it.

### F17 — Medium — Output isolation — Distinct workspaces share live-output filenames

**Location:** `plugin/scripts/lib.sh:640`,
`vscode-extension/extension.js:26`

**Claim:** Parallel resumes from different paths can truncate or display each
other's output.

**Evidence:**

```text
/a-b -> .../live/-a-b.out
/a_b -> .../live/-a-b.out
/a/b -> .../live/-a-b.out
/a.b -> .../live/-a-b.out
```

**Trigger/repro:** Derive live-output paths for workspaces that differ only by
non-alphanumeric characters.

**Recommended remediation:** Key host-local files with a collision-resistant
digest and, if needed, retain a separate human-readable suffix.

## 5. Resource management

### F18 — High — Uninstall/process lifecycle — Uninstall leaves daemons and resumes running

**Location:** `install.sh:159`, `bin/claude-standby:243`

**Claim:** Removing the installation does not stop already-loaded daemon or
Claude processes.

**Evidence:** Neither uninstall path stops validated pidfiles or waits for
active resumes. Runtime state is intentionally retained, and a Bash daemon
that already sourced its functions continues after its script tree is
removed. Sensor-removal failures are also ignored before deleting the
referenced script.

**Trigger/repro:** Uninstall while a workspace daemon is waiting or resuming.

**Recommended remediation:** Stop and wait for every ownership-validated
daemon/process group before removal, abort if status-line deregistration
fails, and report any process that could not be stopped.

### F19 — Medium — Resource growth — Resume output, logs, and journal are unbounded

**Location:** `plugin/scripts/daemon.sh:138`,
`plugin/scripts/daemon.sh:149`,
`plugin/scripts/lib.sh:109`,
`plugin/scripts/lib.sh:533`

**Claim:** A long-running resume can consume unbounded disk and shell memory,
while persistent state and logs grow indefinitely.

**Evidence:** Resume output is written without a limit and then read completely
into a shell variable. Live files are retained, the plugin log never rotates,
and every journal entry permanently enlarges a state file that is fully parsed
and rewritten on every mutation.

**Trigger/repro:** Run a resume that emits a large output stream or keep the
tool active across many schedules and retries.

**Recommended remediation:** Stream or tail directly from the file, impose
per-attempt limits/rotation, cap or archive journals, and remove stale live
files on explicit cleanup/uninstall.

## 6. Data-contract integrity

### F20 — High — Safety schema — Invalid numeric state bypasses `max_resumes`

**Location:** `plugin/scripts/lib.sh:32`,
`plugin/scripts/daemon.sh:322`

**Claim:** Malformed numeric contract data disables the mandatory attempt cap.

**Evidence:** After setting `max_resumes=not-a-number`:

```text
daemon.sh: [: not-a-number: integer expression expected
final_status=done
resume_count=1
max_resumes=not-a-number
```

The resume still ran.

**Trigger/repro:** Write a nonnumeric `max_resumes` through the library or a
JSON-valid state edit, then execute a due task.

**Recommended remediation:** Validate and range-check all numeric contract
fields before any action and fail closed to `failed` without invoking Claude.

### F21 — Medium — JSON fallback — The three JSON engines are observably different

**Location:** `plugin/scripts/lib.sh:145`,
`plugin/scripts/lib.sh:231`,
`plugin/scripts/lib.sh:533`

**Claim:** The fallback chain does not preserve the same valid values or
default schema across jq, Python, and text engines.

**Evidence:**

- Text engine: a U+0001 prompt produced invalid JSON.
- Text engine changed literal bytes `5c 6e` (`\n`) into `5c 0a`
  (backslash followed by a real newline) on readback.
- `ar_journal_append` on a missing task produced:

  ```text
  jq:      status="" max="" count=""
  python3: status=running max=3 count=0
  text:    status=running max=3 count=0
  ```

**Trigger/repro:** Store control characters or a literal backslash-n through
the text engine, or append a journal entry before task creation with each
engine.

**Recommended remediation:** Use one canonical default object across all
engines and a complete JSON string encoder. If safe encoding cannot be
implemented without jq/Python, reject unsupported values without corrupting
state.

### F22 — Medium — Schema resilience — Corrupt and future state are reported as healthy

**Location:** `plugin/scripts/lib.sh:218`,
`bin/claude-standby:164`, `CLAUDE.md:70`

**Claim:** Existing state bypasses initialization validation, and `doctor`
does not distinguish corrupt or unsupported state.

**Evidence:** A corrupt state file produced:

```text
doctor_rc=0
state ok .../state.json (0 task(s))
```

Readers suppress parse errors, and neither `doctor` nor the daemon checks
schema version/type. Additive fields were also introduced without the required
version bump.

**Trigger/repro:** Write truncated JSON, wrong top-level types, or an
unsupported version and run `doctor`, `status`, or a daemon.

**Recommended remediation:** Validate JSON, top-level types, supported version,
task field types, and invariants; report corruption nonzero; provide explicit
migration or quarantine/recovery behavior.

## 7. Failure modes and resilience

### F23 — High — Detection — Any nonzero probe is treated as a usage limit

**Location:** `plugin/scripts/daemon.sh:86`,
`plugin/scripts/daemon.sh:254`

**Claim:** Missing Claude, network/auth failure, or another unrelated probe
error can authorize a later resume of a healthy session.

**Evidence:** `do_probe` returns “limited” immediately for `rc != 0`, before
matching F1. The caller then sets `limit_seen=1`. If the unrelated failure
later clears, a successful probe is interpreted as “limit lifted.”

This directly contradicts C1's “trusts the F1 message — never the exit code.”

**Trigger/repro:** Make the probe return a nonzero error without the measured
F1 message, then make the next probe succeed.

**Recommended remediation:** Only an exact measured F1 match may establish
`limit_seen`. Classify all other failures separately and retry without ever
authorizing a resume.

### F24 — High — Fail-closed behavior — State-write failures do not necessarily stop Claude execution

**Location:** `plugin/scripts/daemon.sh:113`,
`plugin/scripts/task-resume-at.sh:219`,
`vscode-extension/extension.js:491`

**Claim:** The daemon can invoke Claude without successfully recording the
attempt or transition, and the cockpit can treat failed writes as successful
actions.

**Evidence:** The daemon ignores the return value of the transition to
`resuming`/incremented attempt. Most task backends print an error but exit
zero; the cockpit checks only the exit code.

**Trigger/repro:** Make the state directory unwritable or simulate disk-full
during the safety-critical transition.

**Recommended remediation:** Make every safety-critical state transition
mandatory and fail closed before invocation. Return nonzero for operational
failures and make the cockpit surface them.

### F25 — Medium — Configuration resilience — Most timing and threshold values are unvalidated

**Location:** `plugin/scripts/daemon.sh:31`

**Claim:** Malformed configuration can create rapid loops, arithmetic
failures, or incorrect timing.

**Evidence:** Only `RESET_GRACE` is sanitized. `TICK`, `GRACE`,
`BACKOFF_BASE`, `PROBE_INTERVAL`, `AUTO_GIVEUP`, `ARMED_MAX`, and
`LIMIT_PCT` reach sleep, comparisons, or arithmetic without consistent
validation.

**Trigger/repro:** Set these variables to blank, negative, fractional, or
nonnumeric values.

**Recommended remediation:** Centrally parse each value as a bounded decimal
integer and reject unsafe configuration before registering the daemon.

### F26 — Medium — Updater resilience — The validated update is not atomic or rollback-safe

**Location:** `install.sh:81`

**Claim:** An interruption after validation can leave no working installation.

**Evidence:** Only `lib.sh` receives `bash -n`; then the current install is
removed before `mv` places the staged tree. A failed `mv` or interruption
leaves a gap. Staging cleanup also lacks an interrupt trap.

**Trigger/repro:** Interrupt or fail the move after `rm -rf "$INSTALL_DIR"`.

**Recommended remediation:** Validate every shell/JS entry point and version,
rename the existing install to a backup, atomically place the new tree,
rollback on failure, and trap cleanup.

## 8. Architecture and hard-constraint consistency

### F27 — High — C1 — Detection systematically accepts unmeasured shapes

**Location:** `plugin/scripts/lib.sh:37`,
`plugin/scripts/lib.sh:70`,
`plugin/scripts/lib.sh:669`,
`plugin/scripts/daemon.sh:128`,
`test/run-tests.sh:279`

**Claim:** Multiple positive detection and identity decisions rely on formats
outside F1, F2, and F4 as actually measured.

**Evidence:**

- F1 measured one exact sentence, but detection uses the substring
  `hit your session limit`.
- The parser accepts `resets 9:00am` without the measured prefix, separator, or
  IANA zone; the suite explicitly requires this invented form.
- Positive detection accepts unmeasured `rate_pct` and a guessed common cache.
- Stream-JSON remains opt-in, but its unmeasured output still feeds the bounce
  safety guard.
- Session matching accepts non-UUID shapes and unverified path collisions.

**Trigger/repro:** Feed the relevant parser/detector substring-containing but
non-F1 text, a `rate_pct` cache, stream-JSON, or malformed session ID.

**Recommended remediation:** Use an exact F1 recognizer/parser, restrict
positive rate detection to measured F4 fields, keep unmeasured caches/display
formats informational only, and prevent stream-JSON from feeding safety logic
until measured and documented.

### F28 — High — C4 — The status-line path neither always exits zero nor always preserves the old line

**Location:** `plugin/scripts/statusline.sh:17`,
`plugin/scripts/setup-statusline.sh:29`,
`plugin/scripts/setup-statusline.sh:38`

**Claim:** Executable config and substring registration checks violate the
sensor's mandatory failure-invisibility and no-clobber properties.

**Evidence:**

- A config containing `exit 23` made the sensor exit 23.
- A config containing `sleep 2` delayed it by two seconds.
- A different status command containing
  `plugin/scripts/statusline.sh-custom` was classified as the sensor,
  overwritten without a chain, and deleted on removal:

  ```text
  before:        printf plugin/scripts/statusline.sh-custom
  after install: bash ".../plugin/scripts/statusline.sh"
  chain:         absent
  after remove:  statusLine deleted
  ```

- Backup failure is ignored because `backup_settings` always returns zero.

**Trigger/repro:** Point `CLAUDE_STANDBY_CONFIG` at a config that exits/sleeps,
or configure a different status line whose command merely contains the
sensor-path substring.

**Recommended remediation:** Do not source executable config in the sensor,
compare the parsed command exactly to the normalized installed command, always
chain non-identical commands, and abort modification if backup creation fails.

### F29 — High — C5 — Required safety features are absent or incomplete

**Location:** `CLAUDE.md:30`,
`plugin/scripts/daemon.sh:55`,
`plugin/scripts/daemon.sh:373`,
`README.md:234`

**Claim:** Default permission allowlisting, quiet hours, progress-stall
detection, and outcome verification are not implemented.

**Evidence:**

- Default extra arguments are empty; no permission allowlist is installed or
  required.
- Quiet hours are not implemented.
- “Stuck detection” only notices a dead daemon during `resuming`; progress
  stall detection remains planned.
- Any zero exit without the loose limit substring becomes `done` and emits
  “Task finished,” without verifying progress or permission denial.

**Trigger/repro:** Run a headless task requiring unapproved permissions, or a
resume that exits zero without completing useful work.

**Recommended remediation:** Provide a safe default allowlist or refuse
unattended work until explicitly configured, implement quiet hours, and add
progress/outcome verification before reporting completion.

### F30 — Medium — Layering — The cockpit duplicates engine logic and directly invokes Claude

**Location:** `vscode-extension/extension.js:1`,
`vscode-extension/extension.js:15`,
`vscode-extension/extension.js:187`,
`vscode-extension/extension.js:511`

**Claim:** The cockpit is not a purely thin CLI/state shell and already
disagrees with engine parsing.

**Evidence:** Despite comments that all actions go through the CLI, “Open
session” directly constructs a Claude command. The extension separately
implements project encoding, UUID recognition, rate-source resolution, state
health, and daemon liveness. It hardcodes state/log paths and does not expand
shell config such as `AR_CFG_RATE_SOURCE="$HOME/x"` as Bash does.

**Trigger/repro:** Use a shell-expanded rate source, environment-overridden
state path, or configured Claude/CLI path and compare cockpit behavior with
the CLI.

**Recommended remediation:** Expose read-only validated CLI JSON for derived
state and a safe open-session action, leaving the cockpit responsible only for
presentation and intent dispatch.

## 9. Dead, unreachable, duplicated, and stale code

### F31 — Low — Stale contract/artifact — The commands channel is dead and the checked-in VSIX is stale

**Location:** `docs/ARCHITECTURE.md:47`,
`plugin/scripts/lib.sh:218`,
`vscode-extension/CHANGELOG.md:20`

**Claim:** The documented UI-to-daemon channel has no implementation, and the
release artifact is not an exact representation of the current source tree.

**Evidence:**

- `commands` is initialized and documented as UI-to-daemon communication, but
  no implementation consumes or writes it.
- The checked-in VSIX matches current package, extension, dashboard, and README
  hashes, but its CHANGELOG is missing the current 0.9.4 hardening entry.

**Trigger/repro:** Search all implementation files for `commands`, or compare
the unpacked VSIX CHANGELOG with the source CHANGELOG.

**Recommended remediation:** Remove or explicitly reserve the dead channel in
documentation/schema and rebuild/verify the VSIX from the exact release
commit.

## 10. Maintainability

### F32 — Medium — Contract duplication — Similar validators disagree across layers

**Location:** `plugin/scripts/lib.sh:620`,
`vscode-extension/extension.js:254`,
`vscode-extension/extension.js:526`,
`plugin/scripts/setup-statusline.sh:29`

**Claim:** Duplicated session, rate, path, and sensor validation is a recurring
source of behavioral drift.

**Evidence:** Session regex ranges differ (`32–40` versus `8–64`),
rate/config parsing differs between shell and JavaScript, and three separate
substring checks decide whether the status-line sensor exists. These
divergences directly contributed to several findings above.

**Trigger/repro:** Compare the same malformed session ID, shell-expanded rate
configuration, or status-line command across the CLI, setup script, and
cockpit.

**Recommended remediation:** Centralize schema/identity validation and expose
derived facts through one engine-owned interface instead of duplicating
contract semantics.

## 11. Test coverage and quality

### F33 — High — Release security — Publishing runs unpinned downloaded code with registry secrets

**Location:** `.github/workflows/publish-extension.yml:29`

**Claim:** A compromised current npm publisher package could access both
registry credentials during packaging or publication.

**Evidence:** `VSCE_PAT` and `OVSX_TOKEN` are job-wide environment variables,
while `npx --yes @vscode/vsce` and `npx --yes ovsx` fetch unpinned current
packages. No tests run before packaging or publication.

**Trigger/repro:** Trigger the publish workflow after an upstream package or
transitive dependency changes.

**Recommended remediation:** Pin and lock publisher dependencies, install them
before exposing secrets, scope each token to its individual publish step, run
the complete test suite, and verify tag/version/artifact consistency before
publishing.

### F34 — Medium — Coverage quality — The green suite misses the live dirty installer and critical boundaries

**Location:** `test/run-tests.sh:927`,
`test/run-tests.sh:1012`,
`test/fake-claude.sh:30`,
`test/cockpit-smoke.js:1`

**Claim:** The suite can pass deterministically while major scheduling,
concurrency, security, and fallback defects remain.

**Evidence:**

- Installer payload tests build from `git archive HEAD`, excluding current
  uncommitted code. Some scripts are copied later, after many installer
  assertions, but the full live tree is never packaged and retested
  consistently.
- Fake stream-JSON is explicitly guessed, which can make the unmeasured stream
  safety path look valid.
- The suite lacks the reproduced 08/09, session-collision, ambiguous-prefix,
  stale-start, reschedule-during-grace/in-flight, state-race, malformed-cap,
  corrupt-state, XSS, and status-line false-positive cases.
- Cockpit coverage is a small pure-render smoke test; extension
  process/terminal behavior is untested.
- No Linux CI exists.
- The in-flight cancel test changes state directly rather than invoking the
  CLI cancellation/process-kill path.

**Trigger/repro:** Run the existing suite, then run any of the isolated probes
documented in this report.

**Recommended remediation:** Package the current source snapshot under test,
add deterministic regression cases for every high finding, test extension
host behavior with a VS Code stub/harness, and run macOS plus Linux CI.

The two complete successful suite runs were otherwise hermetic: state, logs,
settings, rate files, session stores, installer destinations, and fake
transcripts stayed under temporary directories.

## 12. Documentation accuracy

### F35 — Medium — Documentation drift — Safety, timing, and CLI behavior are overstated or stale

**Location:** `docs/USER-GUIDE.md:106`,
`docs/USER-GUIDE.md:237`,
`README.md:156`,
`vscode-extension/dashboard.js:600`

**Claim:** Current documentation promises behavior contradicted by the
implementation and the audit repros.

**Evidence:**

- “Rescheduling always takes effect within a minute” is false during grace or
  in-flight execution.
- `start` says automatic detection has not shipped.
- README says “Nothing polls a server,” although the fallback invokes Claude
  and the extension checks GitHub.
- README lists stuck detection as planned while C5 requires it and the
  extension claims partial support.
- The dashboard documents `status` as “everywhere,” `log` as the journal, and
  gives `8:30pm`, which the CLI does not accept.
- “No probe” rate claims are false for a static post-reset snapshot.
- Uninstall documentation does not warn that daemons remain active.
- Installer comments claim a failed update cannot leave a broken install, but
  delete-before-move has no rollback.

**Trigger/repro:** Follow the cited commands and safety claims against the
current implementation.

**Recommended remediation:** Reconcile documentation only after behavior is
fixed, clearly distinguish measured facts from assumptions, and turn command
examples into executable documentation tests.

### F36 — Info — Measurement provenance — HOOK-FINDINGS is candid but not independently reproducible

**Location:** `docs/HOOK-FINDINGS.md:33`,
`docs/HOOK-FINDINGS.md:59`,
`docs/HOOK-FINDINGS.md:108`

**Claim:** The measured-format claims are transparently qualified, but the
repository lacks the raw artifacts needed for an independent verification.

**Evidence:** F1 is explicitly one sample, F2 admits limited path sampling, and
F4's real-block semantics remain unverified. The repository contains prose and
derived fixtures but not sanitized raw capture artifacts, commands with
outputs, or hashes that independently substantiate the measurements.

**Trigger/repro:** Attempt to reconstruct each measured finding using only
repository artifacts.

**Recommended remediation:** Preserve sanitized raw samples and exact
reproduction metadata for every format used by detection, while retaining the
existing caveats.

## Overall codebase health

The codebase has a clear architecture, readable intent documentation, a useful
fake-Claude harness, portable date/stat fallbacks, atomic individual file
replacement, aligned versions, and a deterministic 286-test suite. No
telemetry or hidden real-Claude invocation was found in the tests, and default
resume output is correctly plain rather than unmeasured stream-JSON.

However, core safety and identity properties are not currently reliable.

### Top risks

1. Unrelated probe failures can authorize a resume.
2. Session selection can resume the wrong workspace or conversation.
3. Concurrent state writers lose most updates.
4. Rescheduling can fail to stop the old quota-consuming action.
5. Invalid state bypasses `max_resumes`.
6. PID cancellation can target unrelated processes.
7. The status-line setup can clobber another status line or violate `exit 0`.
8. The cockpit has executable HTML and shell-command injection surfaces.
9. Uninstall leaves active daemons running.
10. The advertised no-probe rate path uses a successful probe when its
    snapshot is not refreshed.

### Coverage gaps not verified

The following could not be verified without violating C6, obtaining additional
real-limit evidence, or executing on additional platforms:

- Real Claude's limit exit status.
- Weekly and model-cap message formats.
- Real stream-JSON limit shape and incremental flushing.
- `used_percentage` and status-line refresh behavior at an actual block.
- Real headless permission-denial and partial-success exit semantics.
- End-to-end outcome/progress verification against a real session.
- Linux/BSD-versus-GNU runtime behavior beyond static inspection.
- Disk-full and filesystem interruption behavior.
- Real marketplace publication state.
- Raw provenance behind the measured HOOK-FINDINGS samples.

