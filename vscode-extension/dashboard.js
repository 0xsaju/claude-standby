// Dashboard webview for Claude Standby Cockpit.
// Pure presentation: receives a state snapshot from extension.js, renders
// the page, and posts user intents back. Every scheduling/cancel write goes
// through the CLI; the one deliberate exception is "Open in Claude Code"
// (openSession, D44), an id-validated interactive launch that has no CLI
// equivalent. Visual direction: the Claude-design "Auto-Resume.dc.html" — an
// onboarding/setup screen (A) that gates a professional-tool dashboard (B);
// the status bar + tooltip (C) live in extension.js.
'use strict';

const vscode = require('vscode');
const path = require('path');
const crypto = require('crypto');

const STATUS_HUE = {
  waiting: 'yellow',
  resuming: 'blue',
  running: 'blue',
  'limit-hit': 'orange',
  done: 'green',
  failed: 'red',
  cancelled: 'desc',
};

const STATUS_LABEL = {
  waiting: 'Waiting',
  resuming: 'Resuming',
  running: 'Tracked',
  'limit-hit': 'Limit hit',
  done: 'Done',
  failed: 'Failed',
  cancelled: 'Cancelled',
};

const EVENT_GLYPH = {
  scheduled: ['◔', 'yellow'],
  'session-pinned': ['◎', 'desc'],
  'prompt-set': ['✎', 'desc'],
  armed: ['◇', 'yellow'],
  'limit-hit': ['▲', 'orange'],
  'limit-lifted': ['●', 'green'],
  'reset-detected': ['◑', 'blue'],
  'reset-reached': ['●', 'yellow'],
  grace: ['◷', 'yellow'],
  resumed: ['▶', 'blue'],
  'resume-failed': ['↻', 'red'],
  'resume-finished': ['■', 'desc'],
  done: ['✓', 'green'],
  failed: ['✗', 'red'],
  cancelled: ['⃠', 'desc'],
  'task-started': ['●', 'blue'],
};

const DEFAULT_PROMPT =
  'Limit reset. Continue from where you stopped.';

const BRAND_SVG = `<svg width="18" height="18" viewBox="0 0 18 18"><circle cx="9" cy="9" r="8" fill="#0B1220"/><path d="M9 4a5 5 0 1 0 5 5" fill="none" stroke="#F59E0B" stroke-width="1.8" stroke-linecap="round"/><path d="M14 3.5v3h-3z" fill="#F59E0B"/></svg>`;

// Small inline glyphs for the About row and setup checklist.
const ICON_GH = `<svg width="12" height="12" viewBox="0 0 16 16" style="vertical-align:-2px"><path fill="currentColor" d="M8 0a8 8 0 0 0-2.5 15.6c.4.07.55-.17.55-.38v-1.3c-2.2.48-2.67-1.06-2.67-1.06-.36-.92-.88-1.16-.88-1.16-.72-.49.05-.48.05-.48.8.06 1.22.82 1.22.82.71 1.22 1.87.87 2.33.66.07-.51.28-.87.5-1.07-1.75-.2-3.6-.88-3.6-3.9 0-.86.31-1.56.82-2.11-.08-.2-.36-1 .08-2.09 0 0 .67-.21 2.2.8a7.6 7.6 0 0 1 4 0c1.53-1.01 2.2-.8 2.2-.8.44 1.09.16 1.89.08 2.09.51.55.82 1.25.82 2.11 0 3.03-1.85 3.7-3.61 3.89.29.24.54.72.54 1.45v2.15c0 .21.15.46.55.38A8 8 0 0 0 8 0Z"/></svg>`;
const ICON_IN = `<svg width="12" height="12" viewBox="0 0 16 16" style="vertical-align:-2px"><path fill="currentColor" d="M3.4 4.2a1.4 1.4 0 1 0 0-2.8 1.4 1.4 0 0 0 0 2.8ZM2.2 5.3h2.4v8H2.2v-8Zm4 0h2.3v1.1h.03c.32-.6 1.1-1.24 2.27-1.24 2.43 0 2.88 1.6 2.88 3.68v4.45h-2.4V9.3c0-.87-.02-2-1.22-2-1.22 0-1.4.95-1.4 1.94v4.06h-2.4v-8Z"/></svg>`;
const ICON_COFFEE = `<svg width="11" height="10" viewBox="0 0 11 10" style="vertical-align:-1px"><path d="M2 3h5v3.5A2.5 2.5 0 0 1 4.5 9A2.5 2.5 0 0 1 2 6.5zM7 4h1a1 1 0 0 1 0 2H7" fill="none" stroke="currentColor" stroke-width="1.1" stroke-linecap="round"/></svg>`;
const STAR = `<svg width="13" height="13" viewBox="0 0 16 16" style="vertical-align:-2px"><path fill="currentColor" d="M8 1.2l1.9 4 4.4.5-3.3 3 .9 4.3L8 10.9 4.1 13l.9-4.3-3.3-3 4.4-.5L8 1.2Z"/></svg>`;
const CHECK = `<svg class="ck" width="14" height="14" viewBox="0 0 14 14"><circle cx="7" cy="7" r="6" fill="none" stroke="currentColor" stroke-width="1.3"/><path d="M4.2 7.2l2 2 3.6-4" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></svg>`;
const CROSS = `<svg class="ck" width="14" height="14" viewBox="0 0 14 14"><circle cx="7" cy="7" r="6" fill="none" stroke="currentColor" stroke-width="1.3"/><path d="M4.8 4.8l4.4 4.4M9.2 4.8l-4.4 4.4" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/></svg>`;
// Neutral "pending — not yet, but not broken" glyph (e.g. state.json is
// simply absent on a brand-new install). Never rendered in alarm colors.
const DASH = `<svg class="ck" width="14" height="14" viewBox="0 0 14 14"><circle cx="7" cy="7" r="6" fill="none" stroke="currentColor" stroke-width="1.3" opacity="0.6"/><path d="M4.3 7h5.4" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/></svg>`;

let panel; // singleton tab panel
let sidebarView; // launcher view in the activity-bar sidebar

function esc(s) {
  return String(s ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

// Coerce a contract value that is supposed to be a number into one before it
// reaches the page. A JSON-valid-but-hostile string (e.g. an <img onerror=…>
// smuggled into resume_count) can never survive this, so numeric fields can't
// carry markup (F10).
function num(v, dflt) {
  const n = Number(v);
  return Number.isFinite(n) ? n : dflt;
}

// Only http(s) links may reach an href. About-row URLs come from workspace
// settings, so a javascript:/data: scheme would otherwise be a click-to-XSS
// vector even after HTML-escaping (F10). Returns the (escaped) URL or ''.
function safeUrl(u) {
  const s = String(u ?? '').trim();
  return /^https?:\/\//i.test(s) ? esc(s) : '';
}

// A fresh per-render nonce authorizes exactly our own inline <script> blocks so
// the CSP can drop 'unsafe-inline' from script-src (F10). Styles stay inline.
function makeNonce() {
  return crypto.randomBytes(16).toString('base64');
}

// View state persisted across the 5 s auto-refresh (which rebuilds the
// whole webview HTML). Without this, clicking "Setup" or expanding the CLI
// reference would snap back on the next poll.
let _view = null; // 'setup' | 'dashboard' | null (null => pick by readiness)
let _otherWs = ''; // project selected in the "Other workspaces" composer
let _cliOpen = false;
// While the user is typing in a composer, the 5 s auto-refresh must NOT rebuild
// the HTML — that wiped an in-progress prompt/session/time back to defaults
// (rate.json alone changes constantly, forcing a re-render mid-keystroke). The
// webview reports focus in/out of a composer; we defer refreshes until it's
// done. A forced refresh (the ⟳ button) still goes through.
let _editing = false;

function attach(webview, host) {
  return webview.onDidReceiveMessage(async (msg) => {
    switch (msg.type) {
      case 'schedule':
        await host.schedule(msg.ws, msg.when, msg.tier, msg.session, msg.prompt);
        break;
      case 'cancel':
        await host.cancel(msg.ws);
        break;
      case 'refresh':
        update(host, true);
        break;
      case 'openLog':
        host.openLog();
        break;
      case 'openConfig':
        host.openConfig();
        break;
      case 'install':
        host.installCli();
        break;
      case 'setupSensor':
        await host.setupSensor();
        break;
      case 'editing':
        // Composer gained/lost focus — pause/resume auto-refresh so typing
        // is never clobbered. Refresh once on the way out to catch up.
        _editing = Boolean(msg.active);
        if (!_editing) update(host);
        break;
      case 'openSession':
        host.openSession(msg.ws);
        break;
      case 'goSetup':
        _view = 'setup';
        update(host);
        break;
      case 'goDashboard':
        _view = 'dashboard';
        update(host);
        break;
      case 'selectOther':
        _otherWs = msg.ws || '';
        update(host);
        break;
      case 'toggleCli':
        _cliOpen = Boolean(msg.open);
        break;
      case 'openFull':
        vscode.commands.executeCommand('claudeStandby.openDashboard');
        break;
    }
  });
}

function createOrShow(context, host) {
  if (panel) {
    panel.reveal();
    return panel;
  }
  panel = vscode.window.createWebviewPanel(
    'claudeStandby.dashboard',
    'Claude Standby',
    vscode.ViewColumn.One,
    { enableScripts: true, retainContextWhenHidden: true }
  );
  panel.iconPath = vscode.Uri.file(path.join(context.extensionPath, 'icon.png'));
  attach(panel.webview, host);
  panel.onDidDispose(() => {
    panel = undefined;
    _lastSig = null;
    _editing = false; // don't carry a stuck "editing" flag into the next panel
  });
  const state0 = host.collectState();
  _lastSig = stateSig(state0);
  panel.webview.html = render(state0);
  return panel;
}

// The activity-bar icon opens the FULL dashboard tab, not a sidebar UI.
// VS Code activity-bar icons can only reveal views, so the view is a
// launcher: on every reveal it opens the editor-tab dashboard and closes
// the sidebar again. The tiny fallback button covers the rare case where
// the auto-open is blocked (e.g. during workbench startup).
function resolveSidebar(webviewView, host) {
  sidebarView = webviewView;
  webviewView.webview.options = { enableScripts: true };
  attach(webviewView.webview, host);
  webviewView.onDidDispose(() => {
    sidebarView = undefined;
  });
  const nonce = makeNonce();
  webviewView.webview.html = `<!DOCTYPE html>
<html><head><meta charset="UTF-8">
<meta http-equiv="Content-Security-Policy"
  content="default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-${nonce}';">
<style>
  body { font-family: var(--vscode-font-family); color: var(--vscode-descriptionForeground);
         background: transparent; padding: 16px; font-size: 12px; }
  button { font-family: inherit; font-size: 12.5px; cursor: pointer; border-radius: 6px;
           border: none; padding: 7px 14px; width: 100%;
           background: var(--vscode-button-background); color: var(--vscode-button-foreground); }
</style></head>
<body>
  <p>Opening the dashboard…</p>
  <button id="open">Open Dashboard</button>
  <script nonce="${nonce}">
    const vscode = acquireVsCodeApi();
    document.getElementById('open').addEventListener('click',
      () => vscode.postMessage({ type: 'openFull' }));
  </script>
</body></html>`;

  const openFull = () => {
    vscode.commands.executeCommand('claudeStandby.openDashboard');
    vscode.commands.executeCommand('workbench.action.closeSidebar');
  };
  webviewView.onDidChangeVisibility(() => {
    if (webviewView.visible) openFull();
  });
  openFull();
}

// Signature of everything the page renders from (state + view flags).
// Used to skip the periodic re-render when nothing changed — otherwise
// the 5 s poll would rebuild the HTML and wipe whatever the user is
// typing in the composer (prompt, time, session pick).
let _lastSig = null;
function stateSig(state) {
  return JSON.stringify({
    t: state.tasks,
    s: state.sessionsByWs,
    p: state.projects,
    k: state.stuckWs,
    c: state.cliFound,
    st: state.stateStatus,
    sn: state.sensorRegistered,
    up: state.updatePending,
    // Key on the TAIL, not the length: readLiveOutput caps at the last 8000
    // bytes, so once output passes 8000 the length is pinned and the panel
    // would stop refreshing. The tail changes as new output streams in.
    lo: (state.liveOutput || '').slice(-180),
    rt: state.rate,
    d: state.daemons,
    w: state.currentWs,
    r: state.ready,
    a: state.author,
    v: _view,
    o: _otherWs,
    x: _cliOpen,
  });
}

function update(host, force) {
  if (!panel) return;
  // Never rebuild the HTML out from under someone typing in a composer (unless
  // they explicitly hit refresh) — that was the "extension reset to default
  // while I was entering a time" bug.
  if (!force && _editing) return;
  const state = host.collectState();
  const sig = stateSig(state);
  if (!force && sig === _lastSig) return; // nothing changed — don't clobber input
  _lastSig = sig;
  panel.webview.html = render(state);
}

// ------------------------------------------------------------- helpers ----

// JSON payload embedded in the page; <-escape so conversation text
// can never close the script tag.
function jsonBlock(value) {
  return JSON.stringify(value).replace(/</g, '\\u003c');
}

function pinnedByWs(state) {
  const out = {};
  for (const [ws, t] of Object.entries(state.tasks || {}))
    out[ws] = t.session_id || '';
  return out;
}

// 24h ISO -> "8:30 PM".
function hm12(iso) {
  const m = /T(\d{2}):(\d{2})/.exec(iso || '');
  if (!m) return '';
  let h = parseInt(m[1], 10);
  const suffix = h >= 12 ? 'PM' : 'AM';
  h = h % 12 || 12;
  return `${h}:${m[2]} ${suffix}`;
}

// epoch seconds -> "6:00 PM" in local time.
function hm12Epoch(epoch) {
  const d = new Date(epoch * 1000);
  let h = d.getHours();
  const suffix = h >= 12 ? 'PM' : 'AM';
  h = h % 12 || 12;
  return `${h}:${String(d.getMinutes()).padStart(2, '0')} ${suffix}`;
}

// Honest reset caption from the rate snapshot: the window RESET time — not a
// promise to resume then (that only happens if you actually hit the limit).
function resetInfo(state) {
  const r = state.rate;
  if (!r || !r.resetsAt) return null;
  const pct = r.usedPct != null ? ` · ${r.usedPct}% used` : '';
  return { time: hm12Epoch(r.resetsAt), pct, label: `resets ${hm12Epoch(r.resetsAt)}${pct}` };
}

function sessionTitle(state, ws, id) {
  if (!id) return '';
  const list = (state.sessionsByWs && state.sessionsByWs[ws]) || [];
  const hit = list.find((s) => s.id === id);
  return (hit && hit.summary) || '';
}

// ------------------------------------------------------------- Screen A ---

// Three visual states: ok (green ✓), pending (neutral dash — not yet but
// not broken), and fail (red ✗, optionally with an action button). A
// pending row is never shown in alarm colors so a fresh install stays calm.
function setupRow(ok, title, mono, action, pending, pendingLabel, pendingAct) {
  let glyphCls, glyph, status;
  if (ok) {
    glyphCls = 'c-green';
    glyph = CHECK;
    status = `<span class="c-green ck-lab">✓ ${esc(action || 'ready')}</span>`;
  } else if (pending) {
    // Neutral, never alarming; pendingAct makes the row actionable (an
    // optional-but-recommended step) instead of just informational.
    glyphCls = 'dim';
    glyph = DASH;
    status = pendingAct
      ? `<button class="btn-pri" data-act="${esc(pendingAct)}">${esc(pendingLabel || 'Enable')}</button>`
      : `<span class="dim ck-lab">${esc(pendingLabel || 'pending')}</span>`;
  } else {
    glyphCls = 'c-red';
    glyph = CROSS;
    status = action
      ? `<button class="btn-pri" data-act="${esc(action)}">Install</button>`
      : `<span class="dim ck-lab">checking…</span>`;
  }
  return `<div class="ck-row">
    <span class="${glyphCls}">${glyph}</span>
    <span>${esc(title)}</span>
    ${mono ? `<span class="dim mono ck-mono">${esc(mono)}</span>` : ''}
    <span class="spacer"></span>
    ${status}
  </div>`;
}

function setupScreen(state) {
  const cliOk = state.cliFound;
  const claudeOk = state.claudeFound;
  const stateStatus = state.stateStatus || (state.stateHealthy ? 'ok' : 'absent');
  const stateOk = stateStatus === 'ok';
  const statePending = stateStatus === 'absent';
  const ready = cliOk;
  return `<div class="scr scr-setup">
    <div class="brandline">
      ${BRAND_SVG}
      <span class="name">Claude Standby</span>
      <span class="dim ver">v${esc(state.extVersion || '')}</span>
    </div>
    <p class="lead">When a Claude Code task dies on a usage limit, this tool
      waits for the reset and resumes the exact same conversation —
      automatically.</p>

    <div class="steps">
      <div class="step">
        <div class="step-hd"><span class="step-n">1</span> You hit a usage limit</div>
        <div class="dim step-cap">Claude Code pauses your task. You schedule a resume with one command (or from here).</div>
      </div>
      <div class="step">
        <div class="step-hd"><span class="step-n">2</span> The tool waits for the reset</div>
        <div class="dim step-cap">It checks in the background until the limit lifts, or waits until a time you set.</div>
      </div>
      <div class="step">
        <div class="step-hd"><span class="step-n">3</span> Your conversation continues</div>
        <div class="dim step-cap"><span class="mono">claude --resume</span> picks up where it stopped.</div>
      </div>
    </div>

    <h3 class="section-title">Setup checklist</h3>
    <div class="checklist">
      ${setupRow(cliOk, 'Terminal CLI installed', 'claude-standby', cliOk ? 'installed' : 'install')}
      ${setupRow(claudeOk, 'Claude Code detected', '~/.claude', claudeOk ? 'found' : '')}
      ${setupRow(stateOk, 'State file', '~/.claude/auto-resume/state.json', stateOk ? 'healthy' : '', statePending, 'created on first schedule')}
      ${setupRow(state.sensorRegistered, 'Status-line sensor — exact reset times ("At reset")', 'claude-standby setup-statusline', state.sensorRegistered ? 'registered' : '', !state.sensorRegistered, 'Enable', 'sensor')}
    </div>

    ${
      ready
        ? `<div class="ready-row">
            <span class="c-green">${CHECK}</span>
            <span><b>Ready.</b> <span class="dim">The terminal tool is installed.</span></span>
            <span class="spacer"></span>
            <button class="go" id="go-dashboard">Open dashboard →</button>
          </div>`
        : `<p class="dim mixed-note">Install the terminal tool to get started — it does all the work.</p>
          <p class="skip-line"><a id="go-dashboard">Skip to dashboard →</a></p>`
    }
  </div>`;
}

// ------------------------------------------------------------- Screen B ---

function composerCard(idPrefix, ws, state, primary) {
  const pinned = ws && state.tasks[ws] ? state.tasks[ws].session_id : '';
  const task = ws ? state.tasks[ws] : undefined;
  const promptVal =
    task && task.resume_prompt_template ? task.resume_prompt_template : DEFAULT_PROMPT;
  const ri = resetInfo(state);
  const hasReset = !!ri;
  const resetHint = ri
    ? `you hit a limit → resume at your exact 5-hour reset, <b>${esc(ri.time)}</b>${esc(ri.pct)} — no probing, you've confirmed the limit`
    : '';
  const autoHint = ri
    ? `arm and watch: resume whenever you hit the limit — it'll use your reset time (<b>${esc(ri.time)}</b>) when the moment comes`
    : "arm and watch: checks periodically until a limit hits and lifts, then resumes — it doesn't know your reset time in advance. <b>At reset</b> unlocks once the status-line sensor (Setup) has captured your reset time.";
  return `<div class="composer card" data-ws="${esc(ws || '')}" data-pinned="${esc(pinned || '')}" id="${idPrefix}">
    <div class="field">
      <label>Conversation</label>
      <select class="session-select"></select>
    </div>
    <div class="field">
      <div class="lbl-row">
        <label>Resume prompt</label>
        <span class="spacer"></span>
        <button class="link-btn reset-prompt" style="display:none">reset to default</button>
      </div>
      <input class="prompt-input" value="${esc(promptVal)}" />
    </div>
    <div class="field">
      <label>When</label>
      <div class="when-row">
        ${
          hasReset
            ? `<button class="chip selected" data-when="reset">At reset</button>`
            : `<button class="chip" data-when="reset" disabled title="Needs the status-line sensor: it captures your exact reset time locally. Enable it from Setup (top right), then hit a limit once.">At reset</button>`
        }
        <button class="chip${hasReset ? '' : ' selected'}" data-when="auto">Auto-detect</button>
        <button class="chip" data-when="30m">30m</button>
        <button class="chip" data-when="1h">1h</button>
        <button class="chip" data-when="2h">2h</button>
        <span class="when-sep"></span>
        <input class="t-hour" aria-label="Hour" value="8" maxlength="2" />
        <span class="dim">:</span>
        <input class="t-min" aria-label="Minute" value="30" maxlength="2" />
        <span class="ampm">
          <button class="seg" data-ap="AM">AM</button>
          <button class="seg on" data-ap="PM">PM</button>
        </span>
      </div>
      <div class="when-hint dim hint-reset"${hasReset ? '' : ' style="display:none"'}>${resetHint}</div>
      <div class="when-hint dim hint-auto"${hasReset ? ' style="display:none"' : ''}>${autoHint}</div>
      <div class="when-err c-red" style="display:none">Enter a valid time (hour 1–12, minute 00–59) or pick a preset above.</div>
    </div>
    <div class="c-actions">
      <label class="imp-lbl dim">On reset</label>
      <select class="tier">
        ${
          task
            ? `<option value="" selected>keep current (${esc(task.importance || 'normal')})</option>`
            : ''
        }
        <option value="critical">critical — resume immediately</option>
        <option value="normal"${task ? '' : ' selected'}>normal — 5 min grace</option>
        <option value="low">low — notify only</option>
      </select>
      <span class="spacer"></span>
      <button class="${primary ? 'go' : 'go-outline'} submit">Schedule resume</button>
    </div>
  </div>`;
}

function scheduledList(state, ws) {
  const task = ws ? state.tasks[ws] : undefined;
  if (!task) {
    return `<p class="empty-line dim">Nothing scheduled — the composer above is all you need.</p>`;
  }
  // A "resuming" task whose daemon is gone was interrupted mid-resume — the
  // extension flags it in state.stuckWs. Surface it clearly instead of a
  // forever-spinning "resuming" dot.
  const stuck = (state.stuckWs || []).includes(ws);
  const hue = stuck ? 'red' : STATUS_HUE[task.status] || 'desc';
  const auto = task.resume_mode === 'auto';
  const title =
    sessionTitle(state, ws, task.session_id) ||
    (task.session_id ? task.session_id.slice(0, 8) : 'new chat');
  // For an auto task we know the exact window reset (from rate.json): show it.
  // Armed (no limit seen yet) => "armed · resets 6:00 PM" (it won't resume at
  // that reset unless a limit is actually hit). Limited => "resumes 6:00 PM".
  const ri = resetInfo(state);
  const autoLabel =
    auto && ri
      ? task.limit_seen === '1' || task.limit_seen === 1
        ? `resumes ${ri.time}`
        : `armed · resets ${ri.time}`
      : 'auto-detect';
  const whenLabel = stuck
    ? 'resume interrupted — reschedule'
    : task.status === 'waiting'
      ? auto
        ? autoLabel
        : `resumes ${hm12(task.resume_at)}`
      : (STATUS_LABEL[task.status] || task.status).toLowerCase();
  const promptKind =
    task.resume_prompt_template && task.resume_prompt_template !== DEFAULT_PROMPT
      ? 'custom'
      : 'default';
  // In auto mode resume_at is the NEXT POLL time, not a resume ETA — label
  // it "next check" so it isn't misread as "resumes in Xm". In fixed-time
  // mode it really is the resume countdown, so it stands alone.
  const cd =
    task.status === 'waiting' && task.resume_at
      ? `<span class="cd mono">${
          auto && !stuck ? '<span class="dim">next check </span>' : ''
        }<span class="countdown" data-deadline="${esc(task.resume_at)}">—</span></span>`
      : '';
  return `<div class="sched-row">
    <span class="dot bg-${hue} ${task.status === 'resuming' && !stuck ? 'pulse' : ''}"></span>
    <span class="sched-title ellip">${esc(title)} <span class="dim mono">${esc(
      (task.session_id || '').slice(0, 8)
    )}</span></span>
    <span class="spacer"></span>
    <span class="${stuck ? 'c-red' : 'dim'} when-lab">${esc(whenLabel)}</span>
    <span class="badge">${promptKind}</span>
    <span class="dim mono att">${esc(num(task.resume_count, 0))}/${esc(num(task.max_resumes, 3))}</span>
    ${cd}
    <button class="x-btn act-cancel" data-ws="${esc(ws)}" title="Cancel this resume" aria-label="Cancel">✕</button>
  </div>`;
}

function otherSection(state) {
  const others = (state.projects || []).filter((ws) => ws !== state.currentWs);
  const options = ['<option value="">Select a project to schedule…</option>']
    .concat(
      others.map((ws) => {
        const n = (state.tasks[ws] && state.tasks[ws].status === 'waiting')
          ? ' · 1 scheduled'
          : '';
        return `<option value="${esc(ws)}" ${ws === _otherWs ? 'selected' : ''}>${esc(
          path.basename(ws)
        )} — ${esc(ws)}${n}</option>`;
      })
    )
    .join('');

  const composer =
    _otherWs && others.includes(_otherWs)
      ? composerCard('composer-other', _otherWs, state, false)
      : '';

  // Compact rows for other workspaces that already have an active schedule.
  const rows = others
    .filter((ws) => {
      const t = state.tasks[ws];
      return t && ['waiting', 'resuming', 'running', 'limit-hit'].includes(t.status);
    })
    .map((ws) => {
      const t = state.tasks[ws];
      const stuck = (state.stuckWs || []).includes(ws);
      const hue = stuck ? 'red' : STATUS_HUE[t.status] || 'desc';
      const when = stuck
        ? 'resume interrupted'
        : t.status === 'waiting'
          ? t.resume_mode === 'auto'
            ? 'resumes auto-detect'
            : `resumes ${hm12(t.resume_at)}`
          : (STATUS_LABEL[t.status] || t.status).toLowerCase();
      return `<div class="wsrow">
        <span class="dot bg-${hue} ${t.status === 'resuming' && !stuck ? 'pulse' : ''}"></span>
        <span class="ellip">${esc(path.basename(ws))}</span>
        <span class="dim mono ellip ws-path">${esc(ws)}</span>
        <span class="spacer"></span>
        <span class="${stuck ? 'c-red' : 'dim'}">${esc(when)}</span>
        <button class="x-btn act-cancel" data-ws="${esc(ws)}" aria-label="Cancel">✕</button>
      </div>`;
    })
    .join('');

  return `<h3 class="section-title">Other workspaces</h3>
    <select class="other-select" aria-label="Select another project to schedule">${options}</select>
    ${composer ? `<div class="other-composer">${composer}</div>` : ''}
    ${rows ? `<div class="wsrows">${rows}</div>` : ''}`;
}

function timelineSection(state, ws) {
  const task = ws ? state.tasks[ws] : undefined;
  if (!task || !(task.journal || []).length) {
    return `<h3 class="section-title">Activity</h3>
      <p class="dim empty-line">No activity yet — schedule your first resume above and the story shows up here.</p>`;
  }
  const rows = task.journal
    .slice(-12)
    .reverse()
    .map((e) => {
      const [glyph, hue] = EVENT_GLYPH[e.event] || ['·', 'desc'];
      return `<div class="tl-row">
        <span class="tl-glyph c-${hue}">${glyph}</span>
        <span class="dim mono tl-ts">${esc(hm12(e.ts) || '—')}</span>
        <span class="tl-text">${esc(e.event)}${
          e.detail ? ` <span class="dim">— ${esc(e.detail)}</span>` : ''
        }</span>
      </div>`;
    })
    .join('');
  return `<h3 class="section-title">Activity</h3><div class="timeline">${rows}</div>`;
}

function cliReference() {
  const cmds = [
    ['claude-standby resume-at', 'schedule or reschedule a resume'],
    ['claude-standby sessions', 'list conversations in this project'],
    ['claude-standby status', "what's scheduled, everywhere"],
    ['claude-standby cancel', 'cancel a scheduled resume'],
    ['claude-standby doctor', 'check CLI, daemon, and reset detection'],
    ['claude-standby log', 'tail the journal'],
  ];
  const grid = cmds
    .map(
      ([c, d]) =>
        `<span class="cli-cmd">${esc(c)}</span><span class="dim">${esc(d)}</span>`
    )
    .join('');
  return `<details class="cli-ref" ${_cliOpen ? 'open' : ''}>
    <summary>Do all of this from the terminal</summary>
    <div class="cli-grid">${grid}</div>
    <div class="cli-eg mono">$ claude-standby resume-at 8:30pm --session 2 --prompt "Limit reset. Continue…"</div>
    <div class="cli-guide"><a href="https://github.com/0xsaju/claude-standby/blob/main/docs/USER-GUIDE.md">Full user guide →</a></div>
  </details>`;
}

const REPO_URL = 'https://github.com/0xsaju/claude-standby';

function aboutRow(state) {
  const a = state.author || {};
  const links = [];
  const gh = safeUrl(a.github);
  const li = safeUrl(a.linkedin);
  const bmc = safeUrl(a.buyMeACoffee);
  if (gh) links.push(`<a href="${gh}">${ICON_GH}GitHub</a>`);
  if (li) links.push(`<a href="${li}">${ICON_IN}LinkedIn</a>`);
  if (bmc) links.push(`<a href="${bmc}">${ICON_COFFEE}Buy me a coffee</a>`);
  return `<section class="support">
    <div class="support-text">
      <span class="support-title">${STAR} Enjoying Claude Standby?</span>
      <span class="dim">It's free and open source. A star helps other people find it.</span>
    </div>
    <a class="star-btn" href="${REPO_URL}">${STAR} Star on GitHub</a>
  </section>
  <div class="about">
    ${a.name ? `<span>Built by ${esc(a.name)}</span>` : ''}
    ${links.join('')}
    <span class="spacer"></span>
    <span>MIT · v${esc(state.extVersion || '')}</span>
  </div>`;
}

// Things worth a prominent red/amber marker in the header (Ask: "if any update
// pending / any tool misconfigured, show it a little bigger with a red marker").
function headerAlerts(state) {
  const a = [];
  if (!state.cliFound) a.push({ t: 'CLI not found', red: true });
  if (state.stateStatus === 'corrupt') a.push({ t: 'State file broken', red: true });
  if ((state.stuckWs || []).length)
    a.push({ t: `${state.stuckWs.length} resume interrupted`, red: true });
  if (state.updatePending) a.push({ t: 'Update available', red: true });
  if (!state.sensorRegistered) a.push({ t: 'Exact resets off', red: false });
  return a;
}

// stream-json (or plain) resume output -> a few readable lines for the live
// panel. Defensive: unknown/!JSON lines pass through; fake-claude's string
// `content` and real claude's block array are both handled.
function renderLive(raw) {
  const out = [];
  for (const ln of String(raw || '').split('\n')) {
    const s = ln.trim();
    if (!s) continue;
    let o;
    try { o = JSON.parse(s); } catch { out.push(s); continue; }
    // A bare `null`/number/string JSON line parses fine but has no `.type`;
    // guard before property access so one odd line can't throw and break the
    // whole webview render.
    if (!o || typeof o !== 'object') continue;
    if (o.type === 'assistant' && o.message) {
      const c = o.message.content;
      if (typeof c === 'string') out.push(c.trim());
      else if (Array.isArray(c))
        for (const b of c) {
          if (b.type === 'text' && b.text) out.push(String(b.text).trim());
          else if (b.type === 'tool_use') out.push('· ' + (b.name || 'tool'));
        }
    } else if (o.type === 'result') {
      out.push(o.result ? String(o.result).trim() : '· ' + (o.subtype || 'done'));
    } else if (o.type === 'system' && o.message) {
      out.push(String(o.message).trim());
    }
  }
  return out.filter(Boolean).slice(-30).join('\n');
}

// A card that makes a running/finished resume visible: live output while it
// runs, and a one-click open into the real Claude Code session (D44).
function resumeCard(state, ws, task) {
  if (!task || !['resuming', 'done', 'failed'].includes(task.status)) return '';
  const running = task.status === 'resuming';
  const label = running
    ? 'Resuming now — running headless in the background'
    : task.status === 'done'
      ? '✓ Resumed & finished'
      : '✗ Resume failed';
  const hue = running ? 'blue' : task.status === 'done' ? 'green' : 'red';
  const body = renderLive(state.liveOutput);
  const panel = body ? `<pre class="live-out">${esc(body)}</pre>` : '';
  const openBtn = task.session_id
    ? `<button class="btn-open act-open" data-ws="${esc(ws)}" title="Continue this conversation in Claude Code">▶ Open in Claude Code</button>`
    : '';
  const armed = running
    ? `<p class="dim armed-note">Running this session in the background — don't resume it manually too, or both run at once.</p>`
    : '';
  return `<div class="resume-card card">
    <div class="rc-head">
      <span class="dot bg-${hue}${running ? ' pulse' : ''}"></span>
      <b>${esc(label)}</b>
      <span class="spacer"></span>
      ${openBtn}
    </div>
    ${panel}
    ${armed}
  </div>`;
}

function dashboardScreen(state) {
  const ws = state.currentWs;
  const task = ws ? state.tasks[ws] : undefined;
  const healthOk = state.cliFound;
  const alerts = headerAlerts(state);
  const anyRed = alerts.some((x) => x.red);
  const alertPill = alerts.length
    ? `<a id="go-setup-alert" class="alert-pill ${anyRed ? 'red' : 'amber'}" title="${esc(
        alerts.map((x) => x.t).join(' · ')
      )}">⚠ ${esc(alerts[0].t)}${alerts.length > 1 ? ` +${alerts.length - 1}` : ''}</a>`
    : '';

  const current = ws
    ? `<div class="ws-head">
         <span class="section-title nomargin">Current workspace</span>
         <span class="spacer"></span>
         <span class="ws-name">${esc(path.basename(ws))}</span>
         <span class="dim mono ws-path ellip" title="${esc(ws)}">${esc(ws)}</span>
       </div>
       ${composerCard('composer-current', ws, state, true)}
       <h3 class="section-title">Scheduled resumes</h3>
       ${scheduledList(state, ws)}
       ${resumeCard(state, ws, task)}
       ${timelineSection(state, ws)}`
    : `<div class="no-folder card">
         <b>No folder open.</b>
         <p class="dim">Open a workspace folder to schedule a resume for it — or pick another project below.</p>
       </div>`;

  return `<div class="scr scr-dash">
    <header class="top">
      ${BRAND_SVG}
      <span class="name">Claude Standby</span>
      <span class="dim ver">v${esc(state.extVersion || '')}</span>
      <span class="spacer"></span>
      ${alertPill}
      <span class="health" title="CLI ${state.cliFound ? 'found' : 'missing'} · ${state.daemons} daemon(s)">
        <span class="dot bg-${healthOk ? 'green' : 'orange'}"></span>${
    healthOk ? 'healthy' : 'setup needed'
  }</span>
      <a id="go-setup">Setup</a>
      <button id="refresh" title="Refresh">⟳</button>
    </header>

    ${current}

    ${otherSection(state)}

    ${cliReference()}

    ${aboutRow(state)}

    <footer>
      <span class="statefile mono">~/.claude/auto-resume/state.json · <span class="c-green">live</span></span>
      <span class="spacer"></span>
      <a id="openLog">Log</a>
      <a id="openConfig">Config</a>
    </footer>
  </div>`;
}

// ------------------------------------------------------------- render -----

function render(state) {
  const view = _view || (state.ready ? 'dashboard' : 'setup');
  const body = view === 'setup' ? setupScreen(state) : dashboardScreen(state);
  const nonce = makeNonce();
  return `<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<meta http-equiv="Content-Security-Policy"
  content="default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-${nonce}';">
<style>
  :root { color-scheme: light dark; }
  * { box-sizing: border-box; }
  body {
    font-family: var(--vscode-font-family);
    font-size: 13px; line-height: 1.5;
    color: var(--vscode-foreground);
    background: var(--vscode-editor-background);
    margin: 0;
  }
  .scr { max-width: 680px; margin: 0 auto; padding: 24px 28px 44px; }
  .mono { font-family: var(--vscode-editor-font-family, ui-monospace, Menlo, Consolas, monospace); font-size: .92em; }
  .dim { color: var(--vscode-descriptionForeground); }
  .spacer { flex: 1; }
  .ellip { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; min-width: 0; }
  a { color: var(--vscode-textLink-foreground); text-decoration: none; cursor: pointer; }
  a:hover { text-decoration: underline; }
  b { font-weight: 600; }
  h3.section-title, .section-title {
    font-size: 11px; font-weight: 600; letter-spacing: .5px; text-transform: uppercase;
    color: var(--vscode-descriptionForeground); margin: 26px 0 9px;
  }
  .section-title.nomargin { margin: 0; }

  .c-yellow { color: var(--vscode-charts-yellow, #cca700); }
  .c-blue   { color: var(--vscode-charts-blue, #3794ff); }
  .c-green  { color: var(--vscode-charts-green, #89d185); }
  .c-red    { color: var(--vscode-charts-red, #f48771); }
  .c-orange { color: var(--vscode-charts-orange, #d18616); }
  .bg-yellow { background: var(--vscode-charts-yellow, #cca700); }
  .bg-blue   { background: var(--vscode-charts-blue, #3794ff); }
  .bg-green  { background: var(--vscode-charts-green, #89d185); }
  .bg-red    { background: var(--vscode-charts-red, #f48771); }
  .bg-orange { background: var(--vscode-charts-orange, #d18616); }
  .bg-desc   { background: var(--vscode-descriptionForeground); }
  .dot { width: 7px; height: 7px; border-radius: 50%; display: inline-block; flex: none; }
  .pulse { animation: pulse 1.6s infinite; }
  @keyframes pulse { 0%,100% { opacity: 1; } 50% { opacity: .35; } }

  .card {
    background: var(--vscode-editorWidget-background);
    border: 1px solid var(--vscode-widget-border, rgba(128,128,128,.35));
    border-radius: 4px; padding: 16px;
  }
  .badge {
    font-size: 10.5px; padding: 1px 7px; border-radius: 8px; white-space: nowrap;
    background: var(--vscode-badge-background); color: var(--vscode-badge-foreground);
  }

  /* buttons */
  button { font-family: inherit; cursor: pointer; }
  .go {
    font-size: 12.5px; font-weight: 600; padding: 6px 18px; border: none; border-radius: 3px;
    background: #F59E0B; color: #1a1200;
  }
  .go:hover { background: #e08e06; }
  .go-outline {
    font-size: 12.5px; font-weight: 600; padding: 6px 18px; border-radius: 3px;
    background: transparent; border: 1px solid #F59E0B; color: #F59E0B;
  }
  .btn-pri {
    font-size: 12px; padding: 4px 14px; border: none; border-radius: 3px;
    background: var(--vscode-button-background); color: var(--vscode-button-foreground);
  }
  .link-btn { font-size: 11px; border: none; background: transparent; color: var(--vscode-textLink-foreground); padding: 0; }
  .x-btn { font-size: 11px; border: none; background: transparent; color: var(--vscode-descriptionForeground); padding: 2px 5px; }
  .x-btn:hover { color: var(--vscode-charts-red, #f48771); }
  #refresh { background: none; border: none; opacity: .6; padding: 2px 4px; color: var(--vscode-foreground); font-size: 14px; }
  #refresh:hover { opacity: 1; }

  /* ---- Screen A: setup ---- */
  .brandline { display: flex; align-items: center; gap: 10px; }
  .brandline .name { font-size: 15px; font-weight: 600; }
  .ver { font-size: 11px; }
  .lead { margin: 10px 0 0; color: var(--vscode-descriptionForeground); max-width: 540px; }
  .steps { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 16px; margin-top: 22px; }
  .step-hd { display: flex; align-items: center; gap: 8px; font-weight: 600; font-size: 12.5px; }
  .step-n {
    width: 18px; height: 18px; border-radius: 50%; flex: none;
    border: 1px solid var(--vscode-widget-border, rgba(128,128,128,.35));
    display: inline-flex; align-items: center; justify-content: center;
    font-size: 10px; font-weight: 400; color: var(--vscode-descriptionForeground);
  }
  .step-cap { font-size: 11.5px; padding-left: 26px; margin-top: 5px; }
  .checklist {
    border: 1px solid var(--vscode-widget-border, rgba(128,128,128,.35));
    border-radius: 4px; background: var(--vscode-editorWidget-background);
  }
  .ck-row { display: flex; align-items: center; gap: 10px; padding: 11px 14px; }
  .ck-row + .ck-row { border-top: 1px solid var(--vscode-widget-border, rgba(128,128,128,.35)); }
  .ck { vertical-align: -2px; }
  .ck-mono { font-size: 11px; }
  .ck-lab { font-size: 11.5px; }
  .ready-row {
    display: flex; align-items: center; gap: 12px; margin-top: 14px;
    padding: 12px 14px; border: 1px solid var(--vscode-charts-green, #89d185); border-radius: 4px;
  }
  .mixed-note { margin-top: 14px; font-size: 11.5px; }
  .skip-line { margin-top: 6px; font-size: 11.5px; }

  /* ---- Screen B: dashboard ---- */
  header.top { display: flex; align-items: center; gap: 9px; padding-bottom: 14px; border-bottom: 1px solid var(--vscode-widget-border, rgba(128,128,128,.35)); }
  header.top .name { font-weight: 600; font-size: 13px; }
  .health { display: inline-flex; align-items: center; gap: 5px; font-size: 11.5px; color: var(--vscode-descriptionForeground); }
  header.top a { font-size: 11.5px; }

  .ws-head { display: flex; align-items: baseline; gap: 8px; margin-top: 22px; }
  .ws-name { font-weight: 600; font-size: 12.5px; }
  .ws-path { font-size: 11px; max-width: 46%; }
  .ws-head + .composer { margin-top: 10px; }
  .no-folder { margin-top: 20px; }
  .no-folder p { margin: 6px 0 0; }

  /* composer */
  .field { display: flex; flex-direction: column; gap: 5px; }
  .field + .field { margin-top: 14px; }
  .field > label, .lbl-row label { font-size: 11px; font-weight: 600; color: var(--vscode-descriptionForeground); }
  .lbl-row { display: flex; align-items: baseline; gap: 8px; }
  select, input[type=text], .prompt-input, .t-hour, .t-min, .session-select, .tier, .other-select {
    font-family: inherit; font-size: 12.5px; padding: 6px 8px; border-radius: 3px;
    border: 1px solid var(--vscode-input-border, var(--vscode-widget-border, rgba(128,128,128,.35)));
    background: var(--vscode-input-background); color: var(--vscode-input-foreground);
  }
  .session-select, .prompt-input, .other-select { width: 100%; }
  .prompt-input { box-sizing: border-box; }
  .when-row { display: flex; align-items: center; gap: 6px; flex-wrap: wrap; }
  .chip {
    font-size: 12px; padding: 5px 12px; border-radius: 4px; background: transparent;
    border: 1px solid var(--vscode-input-border, var(--vscode-widget-border, rgba(128,128,128,.35)));
    color: var(--vscode-foreground);
  }
  .alert-pill {
    font-size: 12px; font-weight: 600; padding: 3px 10px; border-radius: 11px;
    text-decoration: none; margin-right: 6px; white-space: nowrap;
  }
  .alert-pill.red { color: #fff; background: var(--vscode-charts-red, #d64545); }
  .alert-pill.amber { color: #1c1c1c; background: var(--vscode-charts-yellow, #e0a500); }
  .resume-card { margin-top: 12px; }
  .rc-head { display: flex; align-items: center; gap: 8px; }
  .btn-open {
    font-size: 12px; padding: 4px 12px; border: 1px solid #F59E0B; border-radius: 4px;
    background: rgba(245,158,11,.10); color: #F59E0B; cursor: pointer;
  }
  .btn-open:hover { background: rgba(245,158,11,.18); }
  .live-out {
    margin: 10px 0 0; padding: 10px 12px; max-height: 220px; overflow: auto;
    background: var(--vscode-textCodeBlock-background, rgba(128,128,128,.10));
    border-radius: 4px; font-family: var(--vscode-editor-font-family, ui-monospace, Menlo, monospace);
    font-size: 12px; line-height: 1.45; white-space: pre-wrap; word-break: break-word;
  }
  .armed-note { margin: 8px 0 0; font-size: 11.5px; }
  .chip:hover { border-color: var(--vscode-descriptionForeground); }
  .chip:disabled { opacity: .45; cursor: not-allowed; }
  .chip:disabled:hover { border-color: var(--vscode-input-border, var(--vscode-widget-border, rgba(128,128,128,.35))); }
  .chip.selected { border-color: #F59E0B; color: #F59E0B; background: rgba(245,158,11,.10); }
  .when-sep { width: 1px; height: 18px; background: var(--vscode-widget-border, rgba(128,128,128,.35)); margin: 0 4px; }
  .when-row.chip-active .t-hour, .when-row.chip-active .t-min, .when-row.chip-active .ampm { opacity: .4; }
  .t-hour, .t-min { width: 34px; text-align: center; padding: 5px 0; font-variant-numeric: tabular-nums; }
  .ampm { display: inline-flex; border: 1px solid var(--vscode-input-border, var(--vscode-widget-border, rgba(128,128,128,.35))); border-radius: 3px; overflow: hidden; }
  .seg { font-size: 12px; padding: 5px 9px; border: none; background: var(--vscode-input-background); color: var(--vscode-descriptionForeground); }
  .seg.on { background: #F59E0B; color: #1a1200; font-weight: 600; }
  .when-hint { font-size: 11.5px; }
  .when-err { font-size: 11.5px; margin-top: 5px; }
  .c-actions { display: flex; align-items: center; gap: 10px; margin-top: 16px; }
  .imp-lbl { font-size: 11px; }
  .tier { font-size: 12px; padding: 4px 8px; }

  /* scheduled rows */
  .sched-row, .wsrow {
    display: flex; align-items: center; gap: 10px; padding: 9px 12px; font-size: 12px;
    border: 1px solid var(--vscode-widget-border, rgba(128,128,128,.35)); border-radius: 4px;
    background: var(--vscode-editorWidget-background);
  }
  .sched-row + .sched-row, .wsrow + .wsrow { margin-top: 6px; }
  .sched-title { max-width: 44%; }
  .when-lab { white-space: nowrap; }
  .att { white-space: nowrap; }
  .cd { font-size: 11.5px; font-variant-numeric: tabular-nums; white-space: nowrap; }
  .empty-line { margin: 9px 0 0; font-size: 12px; }
  .other-select { margin-top: 9px; }
  .other-composer { margin-top: 8px; }
  .wsrows { display: flex; flex-direction: column; gap: 6px; margin-top: 8px; }
  .wsrow .ws-path { max-width: 40%; }

  /* timeline */
  .timeline { display: flex; flex-direction: column; gap: 8px; font-size: 12px; margin-top: 10px; }
  .tl-row { display: flex; gap: 9px; align-items: baseline; }
  .tl-glyph { width: 14px; text-align: center; flex: none; }
  .tl-ts { width: 62px; flex: none; font-variant-numeric: tabular-nums; }
  .tl-text { min-width: 0; }

  /* cli reference */
  .cli-ref { margin-top: 26px; border-top: 1px solid var(--vscode-widget-border, rgba(128,128,128,.35)); padding-top: 14px; }
  .cli-ref summary { cursor: pointer; font-size: 12px; list-style: none; }
  .cli-ref summary::-webkit-details-marker { display: none; }
  .cli-ref summary::before { content: '▸'; color: var(--vscode-descriptionForeground); margin-right: 7px; }
  .cli-ref[open] summary::before { content: '▾'; }
  .cli-grid { display: grid; grid-template-columns: auto 1fr; gap: 5px 18px; margin-top: 12px; font-family: var(--vscode-editor-font-family, ui-monospace, Menlo, Consolas, monospace); font-size: 11.5px; }
  .cli-cmd { color: var(--vscode-foreground); }
  .cli-eg { margin-top: 10px; padding: 8px 10px; background: var(--vscode-input-background); border: 1px solid var(--vscode-input-border, var(--vscode-widget-border, rgba(128,128,128,.35))); border-radius: 3px; color: var(--vscode-descriptionForeground); overflow-x: auto; white-space: nowrap; }
  .cli-guide { margin-top: 8px; font-size: 11.5px; }

  /* support + about + footer */
  .support {
    display: flex; align-items: center; gap: 14px; margin-top: 28px; padding: 14px 16px;
    border: 1px solid var(--vscode-widget-border, rgba(128,128,128,.35)); border-radius: 6px;
    background: var(--vscode-editorWidget-background);
  }
  .support-text { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
  .support-title { font-size: 12.5px; font-weight: 600; color: var(--vscode-foreground); }
  .support-title svg { color: #F59E0B; }
  .support-text .dim { font-size: 11.5px; }
  .star-btn {
    display: inline-flex; align-items: center; gap: 6px; white-space: nowrap; flex: none;
    font-size: 12px; font-weight: 600; padding: 6px 14px; border-radius: 4px;
    color: #1a1200; background: #F59E0B;
  }
  .star-btn:hover { background: #e08e06; text-decoration: none; }
  .about { display: flex; align-items: center; gap: 16px; margin-top: 14px; font-size: 11.5px; color: var(--vscode-descriptionForeground); flex-wrap: wrap; }
  .about a { display: inline-flex; align-items: center; gap: 5px; }
  footer { display: flex; align-items: center; gap: 12px; margin-top: 14px; padding-top: 12px; border-top: 1px solid var(--vscode-widget-border, rgba(128,128,128,.35)); font-size: 11px; color: var(--vscode-descriptionForeground); }

  @media (max-width: 520px) {
    .scr { padding: 18px 16px 36px; }
    .steps { grid-template-columns: 1fr; gap: 12px; }
    .ws-path { display: none; }
    .sched-title { max-width: 100%; }
    .support { flex-direction: column; align-items: stretch; }
    .star-btn { justify-content: center; }
  }
</style>
</head>
<body>
${body}
<script type="application/json" id="data-sessions" nonce="${nonce}">${jsonBlock(state.sessionsByWs || {})}</script>
<script nonce="${nonce}">
  const vscode = acquireVsCodeApi();
  const $ = (s, el) => (el || document).querySelector(s);
  const $$ = (s, el) => Array.from((el || document).querySelectorAll(s));
  const DEFAULT_PROMPT = ${JSON.stringify(DEFAULT_PROMPT)};
  const SESSIONS = JSON.parse(document.getElementById('data-sessions').textContent);

  const send = (type, extra) => vscode.postMessage(Object.assign({ type }, extra || {}));
  const on = (id, ev, fn) => { const e = $('#' + id); if (e) e.addEventListener(ev, fn); };

  on('refresh', 'click', () => send('refresh'));
  on('go-setup', 'click', () => send('goSetup'));
  on('go-setup-alert', 'click', () => send('goSetup'));
  on('go-dashboard', 'click', () => send('goDashboard'));
  on('openLog', 'click', () => send('openLog'));
  on('openConfig', 'click', () => send('openConfig'));

  // setup checklist action buttons
  $$('[data-act]').forEach((b) => b.addEventListener('click', () => {
    const a = b.dataset.act;
    if (a === 'install') send('install');
    if (a === 'sensor') send('setupSensor');
  }));

  // CLI reference open/close is persisted host-side so the 5s refresh
  // doesn't collapse it while you're reading.
  const cli = $('.cli-ref');
  if (cli) cli.addEventListener('toggle', () => send('toggleCli', { open: cli.open }));

  // other-workspaces project picker
  const other = $('.other-select');
  if (other) other.addEventListener('change', () => send('selectOther', { ws: other.value }));

  function ago(ms) {
    const d = Math.max(0, Math.floor((Date.now() - ms) / 1000));
    if (d < 3600) return Math.floor(d / 60) + 'm ago';
    if (d < 86400) return Math.floor(d / 3600) + 'h ago';
    return Math.floor(d / 86400) + 'd ago';
  }

  // Options built with DOM APIs (never innerHTML) — summaries are
  // user-conversation text and must not be interpreted as markup.
  function fillSessions(comp) {
    const sel = $('.session-select', comp);
    if (!sel) return;
    const ws = comp.dataset.ws;
    const pinned = comp.dataset.pinned;
    sel.textContent = '';
    const list = SESSIONS[ws] || [];
    list.forEach((s) => {
      const o = document.createElement('option');
      o.value = s.id;
      const label = (s.summary ? s.summary.slice(0, 52) : s.id.slice(0, 8));
      o.textContent = label + ' — ' + s.id.slice(0, 8) + ' · ' + ago(s.mtime);
      sel.append(o);
    });
    const n = document.createElement('option');
    n.value = 'new';
    n.textContent = '＋ New chat (starts fresh — no history)';
    sel.append(n);
    // The session list is capped (6 newest), but the pinned session must stay
    // selectable even when it's older than that window — otherwise submitting
    // silently swaps the user's pin for the newest visible chat (F06). If the
    // pin isn't among the visible options, inject it at the top.
    if (pinned && !list.some((s) => s.id === pinned)) {
      const po = document.createElement('option');
      po.value = pinned;
      po.textContent = 'pinned · ' + pinned.slice(0, 8) + ' (keep current)';
      sel.insertBefore(po, sel.firstChild);
    }
    sel.value = pinned ? pinned : (list[0] ? list[0].id : 'new');
  }

  function wireComposer(comp) {
    fillSessions(comp);
    const chips = $$('.chip', comp);
    const whenRow = $('.when-row', comp);
    const hour = $('.t-hour', comp);
    const min = $('.t-min', comp);
    const segs = $$('.seg', comp);
    const hintReset = $('.hint-reset', comp);
    const hintAuto = $('.hint-auto', comp);
    const whenErr = $('.when-err', comp);
    const prompt = $('.prompt-input', comp);
    const resetBtn = $('.reset-prompt', comp);
    const hideTimeErr = () => { if (whenErr) whenErr.style.display = 'none'; };

    // Each mode shows its own one-line hint; a relative/clock chip shows none.
    const showHint = (when) => {
      if (hintReset) hintReset.style.display = when === 'reset' ? '' : 'none';
      if (hintAuto) hintAuto.style.display = when === 'auto' ? '' : 'none';
    };
    const selectChip = (c) => {
      chips.forEach((x) => x.classList.toggle('selected', x === c));
      if (whenRow) whenRow.classList.add('chip-active'); // dim the time fields
      showHint(c && c.dataset.when);
      hideTimeErr();
    };
    const clearChips = () => {
      chips.forEach((x) => x.classList.remove('selected'));
      if (whenRow) whenRow.classList.remove('chip-active');
      showHint(null);
      hideTimeErr();
    };
    chips.forEach((c) => c.addEventListener('click', () => selectChip(c)));
    [hour, min].forEach((el) => el && el.addEventListener('focus', clearChips));
    segs.forEach((s) => s.addEventListener('click', () => {
      segs.forEach((x) => x.classList.toggle('on', x === s));
      clearChips();
    }));
    // initial state: a chip is preselected server-side, so reflect it.
    const sel0 = $('.chip.selected', comp);
    if (sel0 && whenRow) whenRow.classList.add('chip-active');
    showHint(sel0 ? sel0.dataset.when : null);

    if (prompt && resetBtn) {
      const sync = () => { resetBtn.style.display = (prompt.value.trim() !== DEFAULT_PROMPT) ? '' : 'none'; };
      prompt.addEventListener('input', sync);
      resetBtn.addEventListener('click', () => { prompt.value = DEFAULT_PROMPT; sync(); });
      sync();
    }

    const submit = $('.submit', comp);
    submit.addEventListener('click', () => {
      const chip = $('.chip.selected', comp);
      let when;
      if (chip) {
        when = chip.dataset.when;
      } else {
        let h = parseInt(hour.value, 10);
        const m = parseInt(min.value, 10);
        if (isNaN(h) || isNaN(m) || h < 1 || h > 12 || m < 0 || m > 59) {
          // Never silently downgrade a bad clock time to auto-detect — that
          // starts real quota-bearing probing the user didn't ask for (F06).
          // Surface it and refuse to submit until it's fixed or a chip is used.
          if (whenErr) whenErr.style.display = '';
          return;
        }
        const ap = ($('.seg.on', comp) || {}).dataset ? $('.seg.on', comp).dataset.ap : 'PM';
        if (ap === 'PM' && h < 12) h += 12;
        if (ap === 'AM' && h === 12) h = 0;
        when = String(h).padStart(2, '0') + ':' + String(m).padStart(2, '0');
      }
      const p = prompt ? prompt.value.trim() : '';
      send('schedule', {
        ws: comp.dataset.ws,
        when: when,
        tier: $('.tier', comp).value,
        session: $('.session-select', comp).value || undefined,
        prompt: (p && p !== DEFAULT_PROMPT) ? p : undefined,
      });
    });
  }
  $$('.composer').forEach(wireComposer);

  // Pause auto-refresh while a composer is focused so a poll can't rebuild the
  // HTML mid-typing and reset the fields. focusout fires as focus MOVES; only
  // treat it as "done" when focus actually left this composer.
  $$('.composer').forEach((c) => {
    c.addEventListener('focusin', () => send('editing', { active: true }));
    c.addEventListener('focusout', (e) => {
      if (!c.contains(e.relatedTarget)) send('editing', { active: false });
    });
  });

  // cancel buttons
  $$('.act-cancel').forEach((b) => b.addEventListener('click', () => send('cancel', { ws: b.dataset.ws })));
  // open the resumed conversation in Claude Code
  $$('.act-open').forEach((b) => b.addEventListener('click', () => send('openSession', { ws: b.dataset.ws })));

  // live countdown
  function tick() {
    $$('.countdown[data-deadline]').forEach((el) => {
      const t = Date.parse(el.dataset.deadline);
      if (isNaN(t)) return;
      let d = Math.floor((t - Date.now()) / 1000);
      if (d <= 0) { el.textContent = 'due'; return; }
      const h = Math.floor(d / 3600); d %= 3600;
      const m = Math.floor(d / 60); const s = d % 60;
      el.textContent = (h ? h + 'h ' : '') + m + 'm ' + String(s).padStart(2, '0') + 's';
    });
  }
  tick();
  setInterval(tick, 1000);
</script>
</body>
</html>`;
}

module.exports = { createOrShow, resolveSidebar, update, render };
