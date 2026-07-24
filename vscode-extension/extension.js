// Claude Standby Cockpit — pure UI over the claude-standby CLI and
// its state file (~/.claude/auto-resume/state.json). Reads come from
// state.json; scheduling/cancel writes go through the CLI (D21), so there is
// one logic path for the engine's work. The single deliberate exception is
// "Open in Claude Code" (openSession, D44): an id-validated interactive
// `claude --resume` launch that the engine has no headless equivalent for.
'use strict';

const vscode = require('vscode');
const cp = require('child_process');
const fs = require('fs');
const path = require('path');
const os = require('os');
const dashboard = require('./dashboard');

const EXT_VERSION = require('./package.json').version;
const AR_HOME = path.join(os.homedir(), '.claude', 'auto-resume');
const STATE_FILE = path.join(AR_HOME, 'state.json');
const LOG_FILE = path.join(AR_HOME, 'logs', 'plugin.log');
// Where the daemon streams each resume's output (D44). The filename encodes the
// workspace with the same [^A-Za-z0-9]->'-' rule the engine uses, so we can
// derive it here without reimplementing its hash.
const AR_LIVE_DIR = path.join(AR_HOME, 'live');

// Set by the daily/manual CLI update check; surfaced as a red header alert.
let _updatePending = false;

function readLiveOutput(ws) {
  if (!ws) return '';
  try {
    const f = path.join(AR_LIVE_DIR, ws.replace(/[^A-Za-z0-9]/g, '-') + '.out');
    // The live file is truncated per resume attempt, so it stays small (and is
    // plain output by default). Keep only the tail — the panel shows recent
    // lines — so a long opt-in stream-json run can't bloat the webview payload.
    return fs.readFileSync(f, 'utf8').slice(-8000);
  } catch {
    return '';
  }
}
const CONFIG_FILE = path.join(AR_HOME, 'config');
const INSTALL_CMD =
  'curl -fsSL https://raw.githubusercontent.com/0xsaju/claude-standby/main/install.sh | bash';

const CONFIG_TEMPLATE = `# claude-standby configuration (shell syntax, AR_CFG_* only)
# Docs: https://github.com/0xsaju/claude-standby/blob/main/docs/USER-GUIDE.md
#
# Extra CLI args for headless resumes (e.g. a permission allowlist). Setting
# this REPLACES the safe default allowlist below and takes full control:
#AR_CFG_EXTRA_ARGS="--allowedTools Edit,Read,Bash(npm:*)"
#
# Default permission allowlist (C5). Applied ONLY when AR_CFG_EXTRA_ARGS is
# unset, so an unattended resume can edit/read/search files but not run
# arbitrary shell or reach the network. Set empty to opt out. Never enables
# --dangerously-skip-permissions:
#AR_CFG_DEFAULT_ALLOWED_TOOLS="Read,Edit,Write,Grep,Glob,LS,TodoWrite,NotebookRead,NotebookEdit"
#
# Quiet hours (C5), 24h LOCAL time as "HH" or "HH:MM". A resume that becomes
# ready inside this window is deferred until it closes (never resumes earlier
# than the reset). Off unless BOTH are set; supports crossing midnight
# (e.g. 22:00-07:00):
#AR_CFG_QUIET_START="22:00"
#AR_CFG_QUIET_END="07:00"
#
# Progress-stall guard (C5). A resume that exits cleanly but leaves the
# workspace progress file (progress_file, default PROGRESS.md) unchanged this
# many times in a row is marked stuck/failed instead of "done". 0 disables:
#AR_CFG_STALL_MAX="2"
#
# Claude binary the daemon invokes (default: claude):
#AR_CFG_CLAUDE_BIN="claude"
#
# Model used for auto-mode limit probes (default: haiku):
#AR_CFG_PROBE_MODEL="haiku"
#
# Live resume output granularity. Default is PLAIN output — the daemon's limit
# detection stays on the measured format. Set to 1 for stream-json (a richer
# per-step live panel in the cockpit), which runs detection on an unverified
# format — opt in only if you want the granular live view:
#AR_CFG_RESUME_STREAM="0"
#
# Path to an existing rate-limit cache to read the exact reset time from
# (e.g. a status line that caches it). Zero setup — point us at your file.
# Fields: used_percentage|rate_pct + resets_at (epoch or ISO):
#AR_CFG_RATE_SOURCE="/tmp/claude_rate_cache_$USER.json"
`;

let statusItem;
let output;

// ---------------------------------------------------------------- helpers --

function workspacePath() {
  const folders = vscode.workspace.workspaceFolders;
  return folders && folders.length ? folders[0].uri.fsPath : undefined;
}

function cliPath() {
  const configured = vscode.workspace
    .getConfiguration('claudeStandby')
    .get('cliPath');
  if (configured) return configured;
  // GUI-launched VS Code often lacks ~/.local/bin on PATH — check directly.
  const local = path.join(os.homedir(), '.local', 'bin', 'claude-standby');
  if (fs.existsSync(local)) return local;
  return 'claude-standby';
}

function runCli(args, cwd) {
  return new Promise((resolve) => {
    // execFile (no shell): args are passed as an argv vector, so nothing in
    // `args` can inject shell syntax. The only trust concern here is which
    // BINARY runs — cliPath() — which we constrain to machine/user settings in
    // package.json so an untrusted workspace can't repoint it (F11).
    cp.execFile(
      cliPath(),
      args,
      { cwd: cwd || workspacePath() || os.homedir() },
      (err, stdout, stderr) => {
        resolve({
          notFound: Boolean(err && err.code === 'ENOENT'),
          code: err ? 1 : 0,
          text: `${stdout || ''}${stderr || ''}`.trim(),
        });
      }
    );
  });
}

// A terminal's sendText types raw text into a live shell, so any executable
// path we splice into a command string must be neutralized first (F11). Reject
// a path we can't safely type at all — a newline/carriage-return/NUL would
// submit an extra line, i.e. run a second command — and POSIX single-quote the
// rest so spaces or shell metacharacters can't break out of the argument.
function safeExecPath(p) {
  const s = String(p || '').trim();
  if (!s || /[\r\n\0]/.test(s)) return null;
  return s;
}
function shArg(s) {
  return `'` + String(s).replace(/'/g, `'\\''`) + `'`;
}

// ------------------------------------------------------------- CLI update --
// The extension never bundles the engine; it only nudges. The one supported
// update path is the CLI's own `update` (download-validate-swap). Here we just
// notice when a newer release exists and offer to run it. Network reads are
// best-effort and silent on failure — a cockpit must never nag when offline.

const LATEST_RELEASE_API =
  'https://api.github.com/repos/0xsaju/claude-standby/releases/latest';

// Minimal HTTPS GET → parsed JSON, no dependencies. Resolves null on any
// failure (offline, rate-limited, bad JSON) so callers can no-op quietly.
function httpsGetJson(url) {
  return new Promise((resolve) => {
    let https;
    try {
      https = require('https');
    } catch {
      return resolve(null);
    }
    const req = https.get(
      url,
      { headers: { 'User-Agent': 'claude-standby-cockpit', Accept: 'application/vnd.github+json' } },
      (res) => {
        if (res.statusCode !== 200) {
          res.resume();
          return resolve(null);
        }
        let body = '';
        res.on('data', (c) => (body += c));
        res.on('end', () => {
          try {
            resolve(JSON.parse(body));
          } catch {
            resolve(null);
          }
        });
      }
    );
    req.on('error', () => resolve(null));
    req.setTimeout(5000, () => {
      req.destroy();
      resolve(null);
    });
  });
}

// Parse a dotted version out of an arbitrary string ("v0.9.1", "claude-standby
// 0.9.1") → [0,9,1], or null. Returns >0 if a is newer than b, <0 if older.
function parseVersion(str) {
  const m = String(str || '').match(/(\d+)\.(\d+)\.(\d+)/);
  return m ? [Number(m[1]), Number(m[2]), Number(m[3])] : null;
}
function compareVersions(a, b) {
  const va = parseVersion(a);
  const vb = parseVersion(b);
  if (!va || !vb) return 0;
  for (let i = 0; i < 3; i++) {
    if (va[i] !== vb[i]) return va[i] - vb[i];
  }
  return 0;
}

function readAllTasks() {
  try {
    const state = JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
    return state.tasks || {};
  } catch {
    return {};
  }
}

function readTask() {
  const ws = workspacePath();
  return ws ? readAllTasks()[ws] : undefined;
}

// The exact 5-hour reset time, read from whatever rate snapshot exists —
// our sensor's rate.json or a status-line cache already on disk (mirrors
// ar_rate_file in lib.sh). Returns { resetsAt(epoch), usedPct, source } or
// null. Zero setup: if a file with the time is there, we just read it.
// Mirror lib.sh ar_rate_file()'s priority so the cockpit and the CLI never
// disagree about whether a reset time exists: env override, then the config's
// AR_CFG_RATE_SOURCE, then our rate.json, then a common /tmp cache.
function rateSourceOverride() {
  if (process.env.CLAUDE_STANDBY_RATE_FILE) return process.env.CLAUDE_STANDBY_RATE_FILE;
  try {
    const cfg = fs.readFileSync(path.join(AR_HOME, 'config'), 'utf8');
    const m = cfg.match(/^\s*AR_CFG_RATE_SOURCE\s*=\s*["']?([^"'#\n]+?)["']?\s*$/m);
    if (m && m[1].trim()) return m[1].trim();
  } catch {
    /* no config file */
  }
  return null;
}

function readRate() {
  const user = process.env.USER || (os.userInfo && os.userInfo().username) || '';
  const override = rateSourceOverride();
  const candidates = [
    ...(override ? [override] : []),
    path.join(AR_HOME, 'rate.json'),
    `/tmp/claude_rate_cache_${user}.json`,
  ];
  for (const f of candidates) {
    try {
      const d = JSON.parse(fs.readFileSync(f, 'utf8'));
      const raw = d.resets_at;
      let epoch = null;
      if (typeof raw === 'number') epoch = raw;
      else if (/^\d+$/.test(String(raw))) epoch = parseInt(raw, 10);
      else if (typeof raw === 'string' && raw.includes('T'))
        epoch = Math.floor(Date.parse(raw) / 1000);
      if (!epoch || epoch * 1000 <= Date.now()) continue; // absent/stale
      const used = d.used_percentage != null ? d.used_percentage : d.rate_pct;
      return { resetsAt: epoch, usedPct: used != null ? used : null, source: path.basename(f) };
    } catch {
      /* try next candidate */
    }
  }
  return null;
}

// A resume is only genuinely in flight while the daemon that started it is
// still alive. If status is "resuming" but that daemon is gone (crash, kill,
// machine reset mid-resume), the task is stuck and needs the user to
// reschedule or cancel. A missing/blank daemon_pid is treated as NOT stuck —
// we only flag a pid we can prove is dead, to avoid false alarms.
function isDaemonStuck(task) {
  if (!task || task.status !== 'resuming') return false;
  const pid = parseInt(task.daemon_pid, 10);
  if (!pid) return false;
  try {
    process.kill(pid, 0);
    return false;
  } catch {
    return true;
  }
}

function refreshAll() {
  refreshStatusBar();
  dashboard.update(host);
}

// ------------------------------------------------------- session listing --
// Claude Code stores one JSONL per session at
// ~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl (HOOK-FINDINGS F2).
// Read-only here; the pick is executed by the CLI (`resume-at --session`).

const PROJECTS_DIR = path.join(os.homedir(), '.claude', 'projects');
// Canonical 8-4-4-4-12 hex UUID — the exact shape the engine's ar_is_uuid()
// enforces (lib.sh). Kept identical here so the cockpit and the CLI agree on
// what a session id is: no all-hyphen strings, bare prefixes, or over-long
// ids slip through in either layer (F32). Used for both session-file discovery
// and the pre-shell id check in openSession.
const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function sessionSummary(file) {
  let fd;
  try {
    fd = fs.openSync(file, 'r');
    const buf = Buffer.alloc(32768);
    const n = fs.readSync(fd, buf, 0, buf.length, 0);
    for (const line of buf.toString('utf8', 0, n).split('\n')) {
      let o;
      try {
        o = JSON.parse(line);
      } catch {
        continue;
      }
      if (o.type !== 'user' || o.isMeta) continue;
      let c = o.message && o.message.content;
      if (Array.isArray(c))
        c = c.filter((b) => b.type === 'text').map((b) => b.text).join(' ');
      if (typeof c !== 'string') continue;
      c = c.replace(/\s+/g, ' ').trim();
      if (!c || c.startsWith('<command-') || c.startsWith('<local-command')) continue;
      // First prompts are often markdown — strip heading/list/quote
      // markers so the summary reads as a title, not source text.
      c = c.replace(/^[#>*\-–—\s`]+/, '').trim();
      if (!c) continue;
      return c.slice(0, 90);
    }
  } catch {
    /* unreadable */
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
  return '';
}

function listSessions(ws) {
  if (!ws) return [];
  const dir = path.join(PROJECTS_DIR, ws.replace(/[^A-Za-z0-9]/g, '-'));
  try {
    return fs
      .readdirSync(dir)
      .filter((f) => f.endsWith('.jsonl') && UUID_RE.test(f.slice(0, -6)))
      .map((f) => {
        const st = fs.statSync(path.join(dir, f));
        return { id: f.slice(0, -6), mtime: st.mtimeMs, sizeKb: Math.round(st.size / 1024) };
      })
      .sort((a, b) => b.mtime - a.mtime)
      .slice(0, 6)
      .map((s) => ({ ...s, summary: sessionSummary(path.join(dir, `${s.id}.jsonl`)) }));
  } catch {
    return [];
  }
}

// Build a single session entry by id. listSessions() only returns the 6
// newest, so a pinned session that is older than that window (or whose file is
// gone) would otherwise vanish from the composer — and scheduling would
// silently swap the user's pin for the newest visible chat (F06). This lets
// collectState re-inject the pinned session no matter its age.
function sessionEntry(ws, id) {
  const base = { id, mtime: 0, sizeKb: 0, summary: '' };
  if (!ws) return base;
  try {
    const file = path.join(
      PROJECTS_DIR,
      ws.replace(/[^A-Za-z0-9]/g, '-'),
      `${id}.jsonl`
    );
    const st = fs.statSync(file);
    return {
      id,
      mtime: st.mtimeMs,
      sizeKb: Math.round(st.size / 1024),
      summary: sessionSummary(file),
    };
  } catch {
    return base;
  }
}

// The encoded project-dir name is lossy (every non-alphanumeric became
// "-"), so the true workspace path is recovered from the `cwd` field the
// session lines carry (HOOK-FINDINGS F2).
function projectDirCwd(dir) {
  try {
    let newest = null;
    for (const f of fs.readdirSync(dir)) {
      if (!f.endsWith('.jsonl') || !UUID_RE.test(f.slice(0, -6))) continue;
      const st = fs.statSync(path.join(dir, f));
      if (!newest || st.mtimeMs > newest.mtime) newest = { f, mtime: st.mtimeMs };
    }
    if (!newest) return undefined;
    const fd = fs.openSync(path.join(dir, newest.f), 'r');
    try {
      const buf = Buffer.alloc(32768);
      const n = fs.readSync(fd, buf, 0, buf.length, 0);
      for (const line of buf.toString('utf8', 0, n).split('\n')) {
        try {
          const o = JSON.parse(line);
          if (typeof o.cwd === 'string' && o.cwd) return o.cwd;
        } catch {
          /* keep scanning */
        }
      }
    } finally {
      fs.closeSync(fd);
    }
  } catch {
    /* unreadable */
  }
  return undefined;
}

// Every schedulable project: the open folder first, then tracked tasks,
// then anything else with sessions on disk. Cached — this stats/reads a
// lot of files and collectState runs every few seconds.
let projectsCache = { at: 0, value: null };

function listProjects(currentWs) {
  if (projectsCache.value && Date.now() - projectsCache.at < 30000) {
    const cached = projectsCache.value;
    return currentWs && !cached.includes(currentWs) ? [currentWs, ...cached] : cached;
  }
  const seen = new Set();
  const out = [];
  const add = (ws) => {
    if (ws && !seen.has(ws)) {
      seen.add(ws);
      out.push(ws);
    }
  };
  add(currentWs);
  for (const ws of Object.keys(readAllTasks())) add(ws);
  try {
    for (const d of fs.readdirSync(PROJECTS_DIR)) {
      const p = path.join(PROJECTS_DIR, d);
      try {
        if (!fs.statSync(p).isDirectory()) continue;
      } catch {
        continue;
      }
      const cwd = projectDirCwd(p);
      if (cwd && fs.existsSync(cwd)) add(cwd);
      if (out.length >= 12) break;
    }
  } catch {
    /* no session store yet */
  }
  projectsCache = { at: Date.now(), value: out };
  return out;
}

// -------------------------------------------------------- dashboard state --

let cliFoundCache = { at: 0, value: true };

function collectState() {
  const cli = cliPath();
  if (Date.now() - cliFoundCache.at > 60000) {
    cliFoundCache = {
      at: Date.now(),
      value: path.isAbsolute(cli) ? fs.existsSync(cli) : true,
    };
  }
  let daemons = 0;
  try {
    const dir = path.join(AR_HOME, 'daemons');
    for (const f of fs.existsSync(dir) ? fs.readdirSync(dir) : []) {
      if (!f.endsWith('.pid')) continue;
      const pid = parseInt(fs.readFileSync(path.join(dir, f), 'utf8'), 10);
      try {
        process.kill(pid, 0);
        daemons++;
      } catch {
        /* stale */
      }
    }
  } catch {
    /* ignore */
  }
  // Workspaces whose resume was interrupted (status stuck at "resuming"
  // with no live daemon) — the dashboard surfaces these for a reschedule.
  const stuckWs = [];
  for (const [ws, t] of Object.entries(readAllTasks())) {
    if (isDaemonStuck(t)) stuckWs.push(ws);
  }
  const currentWs = workspacePath();
  const projects = listProjects(currentWs);
  const allTasks = readAllTasks();
  const sessionsByWs = {};
  for (const ws of projects) {
    const list = listSessions(ws);
    // Guarantee the pinned session is always selectable, even when it's older
    // than the 6-item window listSessions caps at (F06).
    const pinned = allTasks[ws] && allTasks[ws].session_id;
    if (pinned && UUID_RE.test(pinned) && !list.some((s) => s.id === pinned)) {
      list.unshift(sessionEntry(ws, pinned));
    }
    sessionsByWs[ws] = list;
  }
  const cfg = vscode.workspace.getConfiguration('claudeStandby');
  const author = {
    name: cfg.get('author.name') || '',
    github: cfg.get('author.github') || '',
    linkedin: cfg.get('author.linkedin') || '',
    buyMeACoffee: cfg.get('author.buyMeACoffee') || '',
  };
  // Onboarding checklist facts. "Claude Code present" can't be probed
  // reliably from a GUI-launched editor (no login PATH), so we treat the
  // ~/.claude store as the honest signal that Claude Code is in use.
  const claudeFound = fs.existsSync(path.join(os.homedir(), '.claude'));
  // Status-line sensor (F4): registered when Claude Code's settings.json
  // carries the sensor command. Read-only check — enabling goes through
  // the CLI (`setup-statusline`), same override the CLI honors.
  let sensorRegistered = false;
  try {
    const settingsFile =
      process.env.CLAUDE_SETTINGS_FILE ||
      path.join(os.homedir(), '.claude', 'settings.json');
    sensorRegistered = fs
      .readFileSync(settingsFile, 'utf8')
      .includes('plugin/scripts/statusline.sh');
  } catch {
    /* absent or unreadable -> not registered */
  }
  // state.json is created on first use (first schedule), so on a
  // brand-new install it is simply ABSENT — which is fine, not broken. Only
  // a file that exists but won't parse is a real problem. Distinguish the
  // three so the checklist doesn't greet a new user with a scary red ✗.
  let stateStatus;
  if (!fs.existsSync(STATE_FILE)) {
    stateStatus = 'absent';
  } else {
    try {
      JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
      stateStatus = 'ok';
    } catch {
      stateStatus = 'corrupt';
    }
  }
  const stateHealthy = stateStatus === 'ok';
  return {
    tasks: readAllTasks(),
    currentWs,
    projects,
    stuckWs,
    sessionsByWs,
    cliFound: cliFoundCache.value,
    daemons,
    author,
    extVersion: EXT_VERSION,
    claudeFound,
    sensorRegistered,
    stateHealthy,
    stateStatus,
    updatePending: _updatePending,
    // Live resume output for the open workspace, so a running resume is visible
    // in the cockpit instead of only in a headless background process (D44).
    liveOutput: readLiveOutput(currentWs),
    rate: readRate(),
    ready: cliFoundCache.value,
  };
}

const host = {
  collectState,
  schedule: async (ws, when, tier, session, prompt) => {
    const args = ['resume-at', when || 'auto'];
    if (tier) args.push(tier);
    if (session) args.push('--session', session);
    if (prompt) args.push('--prompt', prompt);
    if (ws) args.push('--workspace', ws);
    const res = await runCli(args, ws);
    if (res.notFound) return offerInstall();
    if (res.code !== 0)
      vscode.window.showWarningMessage(`Scheduling failed: ${res.text}`);
    refreshAll();
  },
  cancel: async (ws) => {
    const res = await runCli(['cancel'], ws);
    if (res.notFound) return offerInstall();
    refreshAll();
  },
  openLog: () => openLog(),
  openConfig: () => openConfig(),
  installCli: () => installCli(),
  setupSensor: async () => {
    const res = await runCli(['setup-statusline']);
    if (res.notFound) return offerInstall();
    vscode.window.showInformationMessage(res.text.split('\n')[0]);
    refreshAll();
  },
  // Open the resumed conversation in a real Claude Code session so the user can
  // SEE what the headless resume did (append-in-place, so --resume continues
  // the same conversation). Runs in an integrated terminal (D44).
  openSession: (ws) => {
    const t = ws && readAllTasks()[ws];
    const sid = t && t.session_id;
    if (!sid) {
      vscode.window.showWarningMessage(
        'No pinned session for this workspace yet — nothing to open.'
      );
      return;
    }
    // sid is interpolated into a shell command run in a terminal — never trust
    // it blindly (state.json could be hand-edited/corrupt). Claude session ids
    // are canonical UUIDs (same shape the engine enforces, F32); refuse
    // anything else rather than risk a shell injection.
    if (!UUID_RE.test(sid)) {
      vscode.window.showWarningMessage('Pinned session id looks malformed — not opening.');
      return;
    }
    // The claude binary comes from the environment, not the untrusted
    // workspace, but a path with spaces or metacharacters would still break or
    // inject when typed into a terminal — validate and shell-quote it (F11).
    const claude = safeExecPath(process.env.CLAUDE_STANDBY_CLAUDE_BIN || 'claude');
    if (!claude) {
      vscode.window.showWarningMessage(
        'CLAUDE_STANDBY_CLAUDE_BIN is not a usable path — not opening.'
      );
      return;
    }
    const term = vscode.window.createTerminal({ name: `resume ${sid.slice(0, 8)}`, cwd: ws });
    term.show(true);
    // sid is a validated canonical UUID (safe charset), so it needs no quoting.
    term.sendText(`${shArg(claude)} --resume ${sid}`, true);
  },
};

// --------------------------------------------------------------- status bar --

function shortTime(iso) {
  const m = /T(\d{2}:\d{2})/.exec(iso || '');
  return m ? m[1] : '';
}

// 24h ISO time -> "8:30 PM" for the status bar / tooltip (Screen C).
function clockAmPm(iso) {
  const m = /T(\d{2}):(\d{2})/.exec(iso || '');
  if (!m) return '';
  let h = parseInt(m[1], 10);
  const suffix = h >= 12 ? 'PM' : 'AM';
  h = h % 12 || 12;
  return `${h}:${m[2]} ${suffix}`;
}

// Status bar item — Screen C. Shows OUR tool's state for the open
// workspace; clicking it opens the dashboard. The hover tooltip is the
// rich "tool-status popup" from the design, built as a MarkdownString.
function refreshStatusBar() {
  const task = readTask();
  if (!task) {
    statusItem.text = '$(sync) Standby';
    statusItem.tooltip = statusTooltip(null);
    return;
  }
  if (isDaemonStuck(task)) {
    statusItem.text = '$(warning) resume interrupted';
    statusItem.tooltip = statusTooltip(task);
    return;
  }
  const auto = task.resume_mode === 'auto';
  const at = clockAmPm(task.resume_at);
  const map = {
    waiting: [
      '$(sync)',
      auto ? `auto-detect${at ? ` · next check ${at}` : ''}` : `waiting · resumes ${at}`,
    ],
    resuming: ['$(sync~spin)', 'resuming…'],
    running: ['$(play)', 'tracked'],
    'limit-hit': ['$(warning)', 'limit hit'],
    done: ['$(check)', `done${at ? ` · ${at}` : ''}`],
    failed: ['$(error)', `failed · ${task.resume_count ?? 0} attempts used`],
    cancelled: ['$(circle-slash)', 'cancelled'],
  };
  const [icon, label] = map[task.status] || ['$(question)', task.status];
  statusItem.text = `${icon} ${label}`;
  statusItem.tooltip = statusTooltip(task);
}

function statusTooltip(task) {
  const md = new vscode.MarkdownString();
  md.isTrusted = true;
  md.supportThemeIcons = true;
  md.appendMarkdown('**Claude Standby**\n\n');
  if (!task) {
    md.appendMarkdown('Nothing scheduled in this workspace.\n\n');
    md.appendMarkdown(
      'Hit a limit and it shows up here — or schedule one yourself.\n\n'
    );
    md.appendMarkdown('[Open dashboard](command:claudeStandby.openDashboard)');
    return md;
  }
  const wordMap = {
    waiting: 'Waiting',
    resuming: 'Resuming',
    running: 'Tracked',
    'limit-hit': 'Limit hit',
    done: 'Done',
    failed: 'Failed',
    cancelled: 'Cancelled',
  };
  if (isDaemonStuck(task)) {
    md.appendMarkdown(
      '$(warning) **Resume interrupted** — the daemon exited mid-resume.\n\n'
    );
    md.appendMarkdown(
      'The conversation may or may not have continued. Reschedule to try ' +
        'again, or cancel to clear it.\n\n'
    );
    md.appendMarkdown(
      '[Reschedule](command:claudeStandby.scheduleResume) · ' +
        '[Cancel](command:claudeStandby.cancel)'
    );
    return md;
  }
  md.appendMarkdown(
    `$(circle-filled) **${wordMap[task.status] || task.status}** · ${task.importance}\n\n`
  );
  if (task.status === 'waiting' && task.resume_at) {
    const auto = task.resume_mode === 'auto';
    md.appendMarkdown(
      auto
        ? `Auto-detecting the reset · next check **${clockAmPm(task.resume_at)}**\n\n`
        : `Resumes at **${clockAmPm(task.resume_at)}**\n\n`
    );
  }
  if (task.session_id) {
    md.appendMarkdown(`Continues session \`${task.session_id.slice(0, 8)}\`\n\n`);
  } else if (['waiting', 'resuming'].includes(task.status)) {
    md.appendMarkdown('$(warning) No session pinned — resume starts a new chat\n\n');
  }
  md.appendMarkdown(
    `Attempt ${task.resume_count ?? 0} / ${task.max_resumes ?? 3}\n\n`
  );
  md.appendMarkdown(
    '[Open dashboard](command:claudeStandby.openDashboard) · ' +
      '[Cancel](command:claudeStandby.cancel)'
  );
  return md;
}

function startWatching(context) {
  // state.json is replaced atomically (mv), so watch the directory and
  // keep a slow poll as a fallback for platforms where fs.watch is flaky.
  try {
    if (fs.existsSync(AR_HOME)) {
      const watcher = fs.watch(AR_HOME, () => refreshAll());
      context.subscriptions.push({ dispose: () => watcher.close() });
    }
  } catch {
    /* fall back to polling only */
  }
  const timer = setInterval(refreshAll, 5000);
  context.subscriptions.push({ dispose: () => clearInterval(timer) });
}

// ---------------------------------------------------------------- commands --

async function showStatus() {
  const res = await runCli(['status']);
  if (res.notFound) return offerInstall();
  output.clear();
  output.appendLine(res.text);
  output.show(true);
}

async function scheduleResume(item) {
  const cwd = item && item.ws ? item.ws : undefined;
  const pick = await vscode.window.showQuickPick(
    [
      { label: 'auto', description: 'detect the reset and resume (recommended)' },
      { label: '30m', description: 'in 30 minutes' },
      { label: '1h', description: 'in 1 hour' },
      { label: '2h30m', description: 'in 2.5 hours' },
      { label: 'now', description: 'immediately' },
      { label: 'custom…', description: '20:00, 45m, ISO-8601 …' },
    ],
    { placeHolder: `Resume ${cwd || workspacePath() || 'this workspace'} when?` }
  );
  if (!pick) return;
  let when = pick.label;
  if (when === 'custom…') {
    when = await vscode.window.showInputBox({
      prompt: 'Resume when? (20:00 | 2h30m | ISO-8601 | now | auto)',
    });
    if (!when) return;
  }
  const prompt = await vscode.window.showInputBox({
    prompt: 'Message for the resumed session (leave empty for the default)',
    placeHolder: 'Limit reset. Continue from where you stopped.',
  });
  const args = ['resume-at', when];
  if (prompt) args.push('--prompt', prompt);
  const res = await runCli(args, cwd);
  if (res.notFound) return offerInstall();
  vscode.window.showInformationMessage(
    res.code === 0 ? res.text.split('\n')[0] : `Scheduling failed: ${res.text}`
  );
  refreshAll();
}

async function cancelTask(item) {
  const cwd = item && item.ws ? item.ws : undefined;
  const res = await runCli(['cancel'], cwd);
  if (res.notFound) return offerInstall();
  vscode.window.showInformationMessage(res.text.split('\n')[0]);
  refreshAll();
}

async function openLog() {
  if (!fs.existsSync(LOG_FILE)) {
    vscode.window.showInformationMessage('No claude-standby log yet.');
    return;
  }
  const doc = await vscode.workspace.openTextDocument(LOG_FILE);
  await vscode.window.showTextDocument(doc, { preview: true });
}

async function openConfig() {
  if (!fs.existsSync(CONFIG_FILE)) {
    fs.mkdirSync(path.dirname(CONFIG_FILE), { recursive: true });
    fs.writeFileSync(CONFIG_FILE, CONFIG_TEMPLATE);
  }
  const doc = await vscode.workspace.openTextDocument(CONFIG_FILE);
  await vscode.window.showTextDocument(doc, { preview: false });
}

function installCli() {
  const term = vscode.window.createTerminal('claude-standby install');
  term.show();
  term.sendText(INSTALL_CMD, true);
}

// Run the CLI's own update in a visible terminal (download-validate-swap).
function updateCli() {
  // cliPath() can come from a configured path; validate + shell-quote it before
  // typing it into a terminal so a path with spaces/metacharacters can't break
  // or inject the command (F11). (Workspace overrides are already blocked by
  // the machine scope on claudeStandby.cliPath in package.json.)
  const cli = safeExecPath(cliPath());
  if (!cli) {
    vscode.window.showWarningMessage(
      'claudeStandby.cliPath is not a usable path — cannot run update.'
    );
    return;
  }
  const term = vscode.window.createTerminal('claude-standby update');
  term.show();
  term.sendText(`${shArg(cli)} update`, true);
}

// Compare the installed CLI version against the latest GitHub release and, if
// newer, offer a one-click update. `manual` = surfaced from the menu, so it
// reports "up to date" / failures; the automatic call stays silent otherwise.
async function checkCliUpdate({ manual = false } = {}) {
  const probe = await runCli(['version']);
  if (probe.notFound) {
    if (manual) return offerInstall();
    return;
  }
  const installed = probe.text; // e.g. "claude-standby 0.9.0"
  const release = await httpsGetJson(LATEST_RELEASE_API);
  const latest = release && release.tag_name; // e.g. "v0.9.1"
  if (!latest) {
    if (manual) {
      vscode.window.showWarningMessage(
        'Could not check for updates (offline or GitHub unreachable).'
      );
    }
    return;
  }
  if (compareVersions(latest, installed) > 0) {
    _updatePending = true; // surfaced as a red header alert in the dashboard
    refreshAll();
    const shown = parseVersion(latest).join('.');
    const have = (parseVersion(installed) || []).join('.') || 'unknown';
    const choice = await vscode.window.showInformationMessage(
      `claude-standby ${shown} is available (you have ${have}).`,
      'Update',
      'Later'
    );
    if (choice === 'Update') updateCli();
  } else if (manual) {
    _updatePending = false;
    refreshAll();
    vscode.window.showInformationMessage(
      `claude-standby is up to date (${(parseVersion(installed) || []).join('.')}).`
    );
  }
}

async function offerInstall() {
  const choice = await vscode.window.showInformationMessage(
    'The claude-standby terminal tool is not installed.',
    'Install in Terminal',
    'Later'
  );
  if (choice === 'Install in Terminal') installCli();
}

async function showMenu() {
  const task = readTask();
  const items = [
    { label: '$(calendar) Schedule resume', act: scheduleResume },
    { label: '$(info) Show status', act: showStatus },
    ...(task && ['waiting', 'resuming', 'running'].includes(task.status)
      ? [{ label: '$(circle-slash) Cancel task', act: cancelTask }]
      : []),
    { label: '$(output) Open log', act: openLog },
    { label: '$(gear) Open config', act: openConfig },
    { label: '$(cloud-download) Install/reinstall terminal tool', act: installCli },
    { label: '$(sync) Check for CLI update', act: () => checkCliUpdate({ manual: true }) },
  ];
  const pick = await vscode.window.showQuickPick(items, {
    placeHolder: 'claude-standby',
  });
  if (pick) await pick.act();
}

// --------------------------------------------------------------- lifecycle --

async function activate(context) {
  output = vscode.window.createOutputChannel('Claude Standby');
  statusItem = vscode.window.createStatusBarItem(
    vscode.StatusBarAlignment.Left,
    50
  );
  statusItem.command = 'claudeStandby.openDashboard';
  statusItem.show();
  context.subscriptions.push(output, statusItem);

  // Sidebar = the dashboard itself (clicking the activity-bar logo opens it).
  context.subscriptions.push(
    vscode.window.registerWebviewViewProvider('claudeStandby.dashboardView', {
      resolveWebviewView: (view) => dashboard.resolveSidebar(view, host),
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('claudeStandby.openDashboard', () =>
      dashboard.createOrShow(context, host)
    ),
    vscode.commands.registerCommand('claudeStandby.menu', showMenu),
    vscode.commands.registerCommand('claudeStandby.status', showStatus),
    vscode.commands.registerCommand('claudeStandby.scheduleResume', scheduleResume),
    vscode.commands.registerCommand('claudeStandby.cancel', cancelTask),
    vscode.commands.registerCommand('claudeStandby.refreshView', refreshAll),
    vscode.commands.registerCommand('claudeStandby.openLog', openLog),
    vscode.commands.registerCommand('claudeStandby.openConfig', openConfig),
    vscode.commands.registerCommand('claudeStandby.installCli', installCli),
    vscode.commands.registerCommand('claudeStandby.updateCli', () =>
      checkCliUpdate({ manual: true })
    )
  );

  refreshAll();
  startWatching(context);

  // Onboarding: offer the one-command install when the CLI is missing.
  const probe = await runCli(['version']);
  if (probe.notFound) return offerInstall();

  // Best-effort update check, at most once per 24h so it never nags. Silent
  // when offline, up to date, or the CLI is absent (handled above).
  const DAY = 24 * 60 * 60 * 1000;
  const last = context.globalState.get('lastUpdateCheck', 0);
  if (Date.now() - last > DAY) {
    context.globalState.update('lastUpdateCheck', Date.now());
    checkCliUpdate().catch(() => {});
  }
}

function deactivate() {}

module.exports = { activate, deactivate };
