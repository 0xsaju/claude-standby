// Claude Auto-Resume Cockpit — pure UI over the claude-auto-resume CLI and
// its state file (~/.claude/auto-resume/state.json). This extension never
// spawns or parses Claude Code itself (D21): reads come from state.json,
// writes go through the CLI, so there is exactly one logic path.
'use strict';

const vscode = require('vscode');
const cp = require('child_process');
const fs = require('fs');
const path = require('path');
const os = require('os');
const dashboard = require('./dashboard');

const AR_HOME = path.join(os.homedir(), '.claude', 'auto-resume');
const STATE_FILE = path.join(AR_HOME, 'state.json');
const LOG_FILE = path.join(AR_HOME, 'logs', 'plugin.log');
const CONFIG_FILE = path.join(AR_HOME, 'config');
const INSTALL_CMD =
  'curl -fsSL https://raw.githubusercontent.com/0xsaju/claude-auto-resume/main/install.sh | bash';

const CONFIG_TEMPLATE = `# claude-auto-resume configuration (shell syntax, AR_CFG_* only)
# Docs: https://github.com/0xsaju/claude-auto-resume/blob/main/docs/USER-GUIDE.md
#
# Extra CLI args for headless resumes (e.g. a permission allowlist):
#AR_CFG_EXTRA_ARGS="--allowedTools Edit,Read,Bash(npm:*)"
#
# Claude binary the daemon invokes (default: claude):
#AR_CFG_CLAUDE_BIN="claude"
#
# Model used for auto-mode limit probes (default: haiku):
#AR_CFG_PROBE_MODEL="haiku"
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
    .getConfiguration('claudeAutoResume')
    .get('cliPath');
  if (configured) return configured;
  // GUI-launched VS Code often lacks ~/.local/bin on PATH — check directly.
  const local = path.join(os.homedir(), '.local', 'bin', 'claude-auto-resume');
  if (fs.existsSync(local)) return local;
  return 'claude-auto-resume';
}

function runCli(args, cwd) {
  return new Promise((resolve) => {
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

function refreshAll() {
  refreshStatusBar();
  dashboard.update(host);
}

// ------------------------------------------------------- session listing --
// Claude Code stores one JSONL per session at
// ~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl (HOOK-FINDINGS F2).
// Read-only here; the pick is executed by the CLI (`resume-at --session`).

const PROJECTS_DIR = path.join(os.homedir(), '.claude', 'projects');
const UUID_RE = /^[0-9a-fA-F-]{32,40}$/;

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
  let hooksVia = null;
  try {
    const settings = path.join(os.homedir(), '.claude', 'settings.json');
    if (
      fs.existsSync(settings) &&
      fs.readFileSync(settings, 'utf8').includes('on-stop.sh')
    ) {
      hooksVia = 'settings';
    } else {
      const plugins = path.join(os.homedir(), '.claude', 'plugins');
      if (
        fs.existsSync(plugins) &&
        JSON.stringify(fs.readdirSync(plugins)).includes('claude-auto-resume')
      ) {
        hooksVia = 'plugin';
      } else if (fs.existsSync(plugins)) {
        for (const sub of fs.readdirSync(plugins)) {
          try {
            const p = path.join(plugins, sub);
            if (
              fs.statSync(p).isDirectory() &&
              JSON.stringify(fs.readdirSync(p)).includes('claude-auto-resume')
            ) {
              hooksVia = 'plugin';
              break;
            }
          } catch {
            /* ignore */
          }
        }
      }
    }
  } catch {
    /* ignore */
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
  const currentWs = workspacePath();
  return {
    tasks: readAllTasks(),
    currentWs,
    sessions: listSessions(currentWs),
    cliFound: cliFoundCache.value,
    hooksVia,
    daemons,
  };
}

const host = {
  collectState,
  schedule: async (ws, when, tier, session) => {
    const args = ['resume-at', when || 'auto'];
    if (tier) args.push(tier);
    if (session) args.push('--session', session);
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
};

// --------------------------------------------------------------- status bar --

function shortTime(iso) {
  const m = /T(\d{2}:\d{2})/.exec(iso || '');
  return m ? m[1] : '';
}

function refreshStatusBar() {
  const task = readTask();
  if (!task) {
    statusItem.text = '$(circle-outline) auto-resume';
    statusItem.tooltip =
      'claude-auto-resume: no tracked task in this workspace. Click for actions.';
    return;
  }
  const t = shortTime(task.resume_at);
  const auto = task.resume_mode === 'auto';
  const map = {
    waiting: [
      '$(clock)',
      auto ? `waiting · auto${t ? ` (probe ${t})` : ''}` : `waiting · ${t}`,
    ],
    resuming: ['$(sync~spin)', 'resuming…'],
    running: ['$(play)', 'tracked'],
    'limit-hit': ['$(warning)', 'limit hit'],
    done: ['$(check)', 'done'],
    failed: ['$(error)', 'failed'],
    cancelled: ['$(circle-slash)', 'cancelled'],
  };
  const [icon, label] = map[task.status] || ['$(question)', task.status];
  statusItem.text = `${icon} AR: ${label}`;
  statusItem.tooltip =
    `claude-auto-resume — ${task.status} (${task.importance})` +
    `${task.resume_at ? `\nresume at: ${task.resume_at}` : ''}` +
    `\nresumes used: ${task.resume_count ?? 0}/${task.max_resumes ?? 3}` +
    '\nClick for actions.';
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
  const res = await runCli(['resume-at', when], cwd);
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
    vscode.window.showInformationMessage('No claude-auto-resume log yet.');
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
  const term = vscode.window.createTerminal('claude-auto-resume install');
  term.show();
  term.sendText(INSTALL_CMD, true);
}

async function offerInstall() {
  const choice = await vscode.window.showInformationMessage(
    'The claude-auto-resume terminal tool is not installed.',
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
  ];
  const pick = await vscode.window.showQuickPick(items, {
    placeHolder: 'claude-auto-resume',
  });
  if (pick) await pick.act();
}

// --------------------------------------------------------------- lifecycle --

async function activate(context) {
  output = vscode.window.createOutputChannel('Claude Auto-Resume');
  statusItem = vscode.window.createStatusBarItem(
    vscode.StatusBarAlignment.Left,
    50
  );
  statusItem.command = 'claudeAutoResume.openDashboard';
  statusItem.show();
  context.subscriptions.push(output, statusItem);

  // Sidebar = the dashboard itself (clicking the activity-bar logo opens it).
  context.subscriptions.push(
    vscode.window.registerWebviewViewProvider('claudeAutoResume.dashboardView', {
      resolveWebviewView: (view) => dashboard.resolveSidebar(view, host),
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('claudeAutoResume.openDashboard', () =>
      dashboard.createOrShow(context, host)
    ),
    vscode.commands.registerCommand('claudeAutoResume.menu', showMenu),
    vscode.commands.registerCommand('claudeAutoResume.status', showStatus),
    vscode.commands.registerCommand('claudeAutoResume.scheduleResume', scheduleResume),
    vscode.commands.registerCommand('claudeAutoResume.cancel', cancelTask),
    vscode.commands.registerCommand('claudeAutoResume.refreshView', refreshAll),
    vscode.commands.registerCommand('claudeAutoResume.openLog', openLog),
    vscode.commands.registerCommand('claudeAutoResume.openConfig', openConfig),
    vscode.commands.registerCommand('claudeAutoResume.installCli', installCli)
  );

  refreshAll();
  startWatching(context);

  // Onboarding: offer the one-command install when the CLI is missing.
  const probe = await runCli(['version']);
  if (probe.notFound) await offerInstall();
}

function deactivate() {}

module.exports = { activate, deactivate };
