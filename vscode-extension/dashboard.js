// Dashboard webview for Claude Auto-Resume Cockpit.
// Pure presentation: receives a state snapshot from extension.js, renders
// cards, and posts user intents back — all writes still go through the CLI.
'use strict';

const vscode = require('vscode');
const path = require('path');

const STATUS_COLOR = {
  waiting: 'var(--vscode-charts-yellow)',
  resuming: 'var(--vscode-charts-blue)',
  running: 'var(--vscode-charts-blue)',
  'limit-hit': 'var(--vscode-charts-orange)',
  done: 'var(--vscode-charts-green)',
  failed: 'var(--vscode-charts-red)',
  cancelled: 'var(--vscode-descriptionForeground)',
};

const STATUS_LABEL = {
  waiting: 'Waiting',
  resuming: 'Resuming…',
  running: 'Tracked',
  'limit-hit': 'Limit hit',
  done: 'Done',
  failed: 'Failed',
  cancelled: 'Cancelled',
};

const EVENT_ICON = {
  scheduled: '📅',
  'limit-hit': '🚧',
  'limit-lifted': '🟢',
  'reset-detected': '🕐',
  resumed: '▶️',
  'resume-failed': '↩️',
  'resume-finished': '⏹',
  'reset-reached': '🔔',
  done: '✅',
  failed: '❌',
  cancelled: '⃠',
  'task-started': '🏁',
  'session-pinned': '📌',
};

let panel; // singleton tab panel
let sidebarView; // webview view in the activity-bar sidebar

function esc(s) {
  return String(s ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function attach(webview, host) {
  return webview.onDidReceiveMessage(async (msg) => {
    switch (msg.type) {
      case 'schedule':
        await host.schedule(msg.ws, msg.when, msg.tier, msg.session);
        break;
      case 'cancel':
        await host.cancel(msg.ws);
        break;
      case 'refresh':
        update(host);
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
      case 'openFull':
        vscode.commands.executeCommand('claudeAutoResume.openDashboard');
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
    'claudeAutoResume.dashboard',
    'Claude Auto-Resume',
    vscode.ViewColumn.One,
    { enableScripts: true, retainContextWhenHidden: true }
  );
  panel.iconPath = vscode.Uri.file(
    path.join(context.extensionPath, 'icon.png')
  );
  attach(panel.webview, host);
  panel.onDidDispose(() => {
    panel = undefined;
  });
  panel.webview.html = render(host.collectState(), { compact: false });
  return panel;
}

// Sidebar webview view: clicking the activity-bar logo shows the dashboard.
function resolveSidebar(webviewView, host) {
  sidebarView = webviewView;
  webviewView.webview.options = { enableScripts: true };
  attach(webviewView.webview, host);
  webviewView.onDidDispose(() => {
    sidebarView = undefined;
  });
  webviewView.webview.html = render(host.collectState(), { compact: true });
}

function update(host) {
  if (panel) panel.webview.html = render(host.collectState(), { compact: false });
  if (sidebarView)
    sidebarView.webview.html = render(host.collectState(), { compact: true });
}

function chip(ok, okText, badText) {
  const color = ok
    ? 'var(--vscode-charts-green)'
    : 'var(--vscode-charts-orange)';
  return `<span class="chip"><span class="dot" style="background:${color}"></span>${esc(
    ok ? okText : badText
  )}</span>`;
}

function progressBar(used, max) {
  const pct = Math.min(100, Math.round((used / Math.max(1, max)) * 100));
  return `
    <div class="meter" title="${used} of ${max} resume attempts used">
      <div class="meter-fill" style="width:${pct}%"></div>
    </div>
    <div class="meter-label">${used} of ${max} resume attempts used</div>`;
}

function ago(ms) {
  const d = Math.max(0, Math.floor((Date.now() - ms) / 1000));
  if (d < 3600) return `${Math.floor(d / 60)}m ago`;
  if (d < 86400) return `${Math.floor(d / 3600)}h ago`;
  return `${Math.floor(d / 86400)}d ago`;
}

// Session plates: pick WHICH conversation the daemon resumes with
// `claude --resume <id>` (the whole point of the tool). Only rendered for
// the current workspace — other workspaces default to their newest session.
function sessionPlates(state, ws, task) {
  if (ws !== state.currentWs || !(state.sessions || []).length) return '';
  const pinned = task && task.session_id;
  const pinnedListed = state.sessions.some((s) => s.id === pinned);
  const plates = state.sessions
    .map((s, i) => {
      const selected = pinned ? s.id === pinned : i === 0;
      return `<button class="plate ${selected ? 'selected' : ''}" data-session="${esc(s.id)}">
        <span class="plate-title">${esc(s.summary || s.id.slice(0, 8))}</span>
        <span class="plate-meta">${esc(s.id.slice(0, 8))} · ${esc(ago(s.mtime))} · ${s.sizeKb} KB</span>
      </button>`;
    })
    .join('');
  return `<div class="plates">
    <div class="plates-label">Continue which conversation?</div>
    ${plates}
    <button class="plate plate-new ${pinned && !pinnedListed ? '' : ''}" data-session="new">
      <span class="plate-title">New chat</span>
      <span class="plate-meta">start fresh instead of resuming</span>
    </button>
  </div>`;
}

function scheduleForm(ws, compact, state, task) {
  return `
  <div class="composer ${compact ? 'compact' : ''}" data-ws="${esc(ws)}">
    ${sessionPlates(state, ws, task)}
    <div class="presets">
      <button class="preset" data-when="auto" title="Probe until the limit lifts, then resume">Auto-detect</button>
      <button class="preset" data-when="30m">30m</button>
      <button class="preset" data-when="1h">1h</button>
      <button class="preset" data-when="2h30m">2h30m</button>
      <button class="preset" data-when="now">Now</button>
    </div>
    <div class="custom-row">
      <input class="custom-when" placeholder="custom: 20:00 · 45m · ISO-8601" />
      <select class="tier">
        <option value="">tier: keep</option>
        <option value="critical">critical</option>
        <option value="normal">normal</option>
        <option value="low">low</option>
      </select>
      <button class="go primary">Schedule</button>
    </div>
  </div>`;
}

function heroCard(ws, task, state) {
  if (!ws) {
    return `<section class="card hero empty">
      <div class="empty-icon">🗂</div>
      <h2>No folder open</h2>
      <p>Open a workspace folder to track and resume tasks in it.</p>
    </section>`;
  }
  if (!task) {
    return `<section class="card hero empty">
      <div class="empty-icon">💤</div>
      <h2>Nothing tracked here yet</h2>
      <p class="ws-path">${esc(ws)}</p>
      <p>Hit a usage limit? Schedule a resume and walk away.</p>
      ${scheduleForm(ws, false, state)}
    </section>`;
  }
  const color = STATUS_COLOR[task.status] || 'var(--vscode-foreground)';
  const label = STATUS_LABEL[task.status] || task.status;
  const auto = task.resume_mode === 'auto';
  const active = ['waiting', 'resuming', 'running'].includes(task.status);
  let timing = '';
  if (task.status === 'waiting' && task.resume_at) {
    timing = `
      <div class="countdown" data-deadline="${esc(task.resume_at)}">
        <span class="count">—</span>
        <span class="count-sub">${
          auto ? 'until the next limit probe' : 'until resume'
        } · ${esc(task.resume_at)}</span>
      </div>`;
  } else if (task.status === 'resuming') {
    timing = `<div class="countdown"><span class="count pulse">● session running</span></div>`;
  }
  const pinnedInfo = (state.sessions || []).find((s) => s.id === task.session_id);
  const sessionLine = task.session_id
    ? `<div class="session-line" title="${esc(task.session_id)}">↻ continues “${esc(
        (pinnedInfo && pinnedInfo.summary) || task.session_id.slice(0, 8)
      )}” <span class="session-id">${esc(task.session_id.slice(0, 8))}</span></div>`
    : active
      ? `<div class="session-line warn">⚠ no session pinned — resume would start a new chat (pick one below)</div>`
      : '';
  return `<section class="card hero">
    <div class="hero-top">
      <div>
        <div class="status-line">
          <span class="status-dot" style="background:${color}"></span>
          <span class="status-word" style="color:${color}">${esc(label)}</span>
          <span class="badge">${esc(task.importance)}</span>
          ${auto ? '<span class="badge alt">auto-detect</span>' : ''}
        </div>
        <div class="ws-path">${esc(ws)}</div>
        ${
          task.original_prompt
            ? `<div class="prompt">“${esc(task.original_prompt.slice(0, 140))}”</div>`
            : ''
        }
        ${sessionLine}
      </div>
      <div class="hero-actions">
        <button class="primary act-schedule" data-ws="${esc(ws)}">${
          active ? 'Reschedule' : 'Schedule resume'
        }</button>
        ${
          active
            ? `<button class="danger act-cancel" data-ws="${esc(ws)}">Cancel</button>`
            : ''
        }
      </div>
    </div>
    ${timing}
    ${progressBar(task.resume_count ?? 0, task.max_resumes ?? 3)}
    <div class="composer-slot" data-ws="${esc(ws)}" hidden>${scheduleForm(ws, true, state, task)}</div>
  </section>`;
}

function otherCards(state) {
  const others = Object.entries(state.tasks).filter(
    ([ws]) => ws !== state.currentWs
  );
  if (!others.length) return '';
  const cards = others
    .map(([ws, t]) => {
      const color = STATUS_COLOR[t.status] || 'var(--vscode-foreground)';
      const active = ['waiting', 'resuming', 'running'].includes(t.status);
      return `<div class="card mini">
        <div class="mini-head">
          <span class="status-dot" style="background:${color}"></span>
          <span class="mini-name" title="${esc(ws)}">${esc(path.basename(ws))}</span>
          <span class="mini-status" style="color:${color}">${esc(
            STATUS_LABEL[t.status] || t.status
          )}</span>
        </div>
        <div class="mini-sub">${esc(t.importance)} · ${t.resume_count ?? 0}/${
          t.max_resumes ?? 3
        } attempts${t.resume_at && t.status === 'waiting' ? ` · ${esc(t.resume_at)}` : ''}</div>
        <div class="mini-actions">
          <button class="linklike act-schedule" data-ws="${esc(ws)}">schedule</button>
          ${active ? `<button class="linklike danger-text act-cancel" data-ws="${esc(ws)}">cancel</button>` : ''}
        </div>
        <div class="composer-slot" data-ws="${esc(ws)}" hidden>${scheduleForm(ws, true, state, t)}</div>
      </div>`;
    })
    .join('');
  return `<h3 class="section-title">Other workspaces</h3><div class="grid">${cards}</div>`;
}

function timeline(task) {
  if (!task || !(task.journal || []).length) return '';
  const rows = task.journal
    .slice(-12)
    .reverse()
    .map(
      (e) => `<li>
        <span class="tl-icon">${EVENT_ICON[e.event] || '·'}</span>
        <span class="tl-body">
          <span class="tl-event">${esc(e.event)}</span>
          ${e.detail ? `<span class="tl-detail">${esc(e.detail)}</span>` : ''}
        </span>
        <span class="tl-ts">${esc((e.ts || '').replace('T', ' ').slice(0, 19))}</span>
      </li>`
    )
    .join('');
  return `<h3 class="section-title">Activity</h3><section class="card"><ul class="timeline">${rows}</ul></section>`;
}

function render(state, opts) {
  const compact = Boolean(opts && opts.compact);
  const task = state.currentWs ? state.tasks[state.currentWs] : undefined;
  const hooksOk = state.hooksVia !== null;
  return `<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<meta http-equiv="Content-Security-Policy"
  content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline';">
<style>
  :root { color-scheme: light dark; }
  * { box-sizing: border-box; }
  body {
    font-family: var(--vscode-font-family);
    color: var(--vscode-foreground);
    background: var(--vscode-editor-background);
    margin: 0; padding: 24px;
  }
  .wrap { max-width: 880px; margin: 0 auto; }
  header.top {
    display: flex; align-items: center; gap: 12px; margin-bottom: 20px;
  }
  .brand { display: flex; align-items: center; gap: 10px; margin-right: auto; }
  .brand svg { width: 28px; height: 28px; color: #F59E0B; }
  .brand h1 { font-size: 16px; font-weight: 600; margin: 0; letter-spacing: .2px; }
  .chips { display: flex; gap: 8px; flex-wrap: wrap; }
  .chip {
    display: inline-flex; align-items: center; gap: 6px;
    font-size: 11px; padding: 3px 10px; border-radius: 99px;
    background: var(--vscode-badge-background);
    color: var(--vscode-badge-foreground);
  }
  .dot { width: 7px; height: 7px; border-radius: 50%; display: inline-block; }
  .card {
    background: var(--vscode-editorWidget-background);
    border: 1px solid var(--vscode-widget-border, rgba(128,128,128,.25));
    border-radius: 10px; padding: 18px 20px; margin-bottom: 14px;
  }
  .hero-top { display: flex; gap: 16px; justify-content: space-between; align-items: flex-start; }
  .status-line { display: flex; align-items: center; gap: 8px; }
  .status-dot { width: 10px; height: 10px; border-radius: 50%; }
  .status-word { font-size: 18px; font-weight: 650; }
  .badge {
    font-size: 10px; text-transform: uppercase; letter-spacing: .6px;
    padding: 2px 8px; border-radius: 99px;
    background: color-mix(in srgb, #F59E0B 18%, transparent);
    color: #F59E0B; border: 1px solid color-mix(in srgb, #F59E0B 40%, transparent);
  }
  .badge.alt {
    background: color-mix(in srgb, var(--vscode-charts-blue) 15%, transparent);
    color: var(--vscode-charts-blue);
    border-color: color-mix(in srgb, var(--vscode-charts-blue) 40%, transparent);
  }
  .ws-path { font-size: 11.5px; color: var(--vscode-descriptionForeground); margin-top: 6px; }
  .prompt { font-size: 12.5px; margin-top: 8px; color: var(--vscode-descriptionForeground); font-style: italic; }
  .hero-actions { display: flex; flex-direction: column; gap: 8px; min-width: 150px; }
  button {
    font-family: inherit; font-size: 12.5px; cursor: pointer;
    border-radius: 6px; border: 1px solid var(--vscode-button-border, transparent);
    padding: 7px 14px;
    background: var(--vscode-button-secondaryBackground);
    color: var(--vscode-button-secondaryForeground);
  }
  button:hover { filter: brightness(1.12); }
  button.primary { background: var(--vscode-button-background); color: var(--vscode-button-foreground); }
  button.danger { background: color-mix(in srgb, var(--vscode-charts-red) 20%, transparent); color: var(--vscode-charts-red); border-color: color-mix(in srgb, var(--vscode-charts-red) 45%, transparent); }
  .countdown { margin: 18px 0 4px; }
  .count { font-size: 30px; font-weight: 700; font-variant-numeric: tabular-nums; letter-spacing: .5px; }
  .count.pulse { color: var(--vscode-charts-blue); font-size: 18px; }
  .count-sub { display: block; font-size: 11.5px; color: var(--vscode-descriptionForeground); margin-top: 2px; }
  .meter { height: 6px; border-radius: 99px; background: var(--vscode-input-background); overflow: hidden; margin-top: 14px; }
  .meter-fill { height: 100%; background: #F59E0B; border-radius: 99px; }
  .meter-label { font-size: 10.5px; color: var(--vscode-descriptionForeground); margin-top: 5px; }
  .section-title { font-size: 12px; text-transform: uppercase; letter-spacing: .8px; color: var(--vscode-descriptionForeground); margin: 22px 0 10px; }
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(240px, 1fr)); gap: 12px; }
  .card.mini { margin: 0; padding: 14px 16px; }
  .mini-head { display: flex; align-items: center; gap: 8px; }
  .mini-name { font-weight: 600; font-size: 13px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .mini-status { margin-left: auto; font-size: 11.5px; }
  .mini-sub { font-size: 11px; color: var(--vscode-descriptionForeground); margin-top: 6px; }
  .mini-actions { margin-top: 8px; display: flex; gap: 12px; }
  .linklike { background: none; border: none; padding: 0; color: var(--vscode-textLink-foreground); font-size: 11.5px; }
  .danger-text { color: var(--vscode-charts-red); }
  .timeline { list-style: none; margin: 0; padding: 0; }
  .timeline li { display: flex; gap: 10px; align-items: baseline; padding: 7px 0; border-bottom: 1px solid var(--vscode-widget-border, rgba(128,128,128,.15)); }
  .timeline li:last-child { border-bottom: none; }
  .tl-icon { width: 20px; text-align: center; }
  .tl-body { flex: 1; }
  .tl-event { font-weight: 600; font-size: 12.5px; }
  .tl-detail { color: var(--vscode-descriptionForeground); font-size: 12px; margin-left: 6px; }
  .tl-ts { font-size: 10.5px; color: var(--vscode-descriptionForeground); font-variant-numeric: tabular-nums; }
  .hero.empty { text-align: center; padding: 36px 24px; }
  .empty-icon { font-size: 34px; margin-bottom: 6px; }
  .hero.empty h2 { margin: 4px 0 6px; font-size: 16px; }
  .hero.empty p { margin: 4px 0; font-size: 12.5px; color: var(--vscode-descriptionForeground); }
  .session-line { font-size: 12px; margin-top: 8px; color: var(--vscode-descriptionForeground); }
  .session-line.warn { color: var(--vscode-charts-orange); }
  .session-id { font-family: var(--vscode-editor-font-family, monospace); font-size: 10.5px; opacity: .8; margin-left: 4px; }
  .plates { display: flex; flex-direction: column; gap: 6px; margin-bottom: 12px; }
  .plates-label { font-size: 11px; text-transform: uppercase; letter-spacing: .6px; color: var(--vscode-descriptionForeground); margin-bottom: 2px; }
  .plate {
    display: flex; flex-direction: column; align-items: flex-start; gap: 2px;
    text-align: left; padding: 8px 12px; border-radius: 8px;
    background: var(--vscode-input-background);
    border: 1px solid var(--vscode-widget-border, rgba(128,128,128,.25));
    color: var(--vscode-foreground);
  }
  .plate:hover { border-color: #F59E0B; filter: none; }
  .plate.selected {
    border-color: #F59E0B;
    background: color-mix(in srgb, #F59E0B 10%, var(--vscode-input-background));
  }
  .plate.selected .plate-title::before { content: '● '; color: #F59E0B; }
  .plate-title { font-size: 12.5px; font-weight: 600; max-width: 100%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .plate-meta { font-size: 10.5px; color: var(--vscode-descriptionForeground); font-variant-numeric: tabular-nums; }
  .composer { margin-top: 16px; text-align: left; }
  .presets { display: flex; gap: 8px; flex-wrap: wrap; margin-bottom: 8px; }
  .preset { padding: 5px 12px; border-radius: 99px; font-size: 12px; }
  .custom-row { display: flex; gap: 8px; }
  .custom-row input, .custom-row select {
    font-family: inherit; font-size: 12px; padding: 6px 10px; border-radius: 6px;
    border: 1px solid var(--vscode-input-border, transparent);
    background: var(--vscode-input-background); color: var(--vscode-input-foreground);
  }
  .custom-row input { flex: 1; }
  footer { display: flex; gap: 16px; margin-top: 26px; font-size: 11.5px; color: var(--vscode-descriptionForeground); align-items: center; flex-wrap: wrap; }
  footer a { color: var(--vscode-textLink-foreground); text-decoration: none; cursor: pointer; }
  footer .spacer { margin-left: auto; }
  ${
    compact
      ? `body { padding: 12px; }
  .wrap { max-width: none; }
  header.top { flex-wrap: wrap; gap: 8px; margin-bottom: 12px; }
  .chips { width: 100%; order: 3; }
  .card { padding: 14px; }
  .hero-top { flex-direction: column; }
  .hero-actions { flex-direction: row; min-width: 0; }
  .count { font-size: 24px; }
  .custom-row { flex-wrap: wrap; }
  .grid { grid-template-columns: 1fr; }
  footer .statefile { display: none; }`
      : ''
  }
</style>
</head>
<body>
<div class="wrap">
  <header class="top">
    <div class="brand">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round">
        <path d="M20.49 15a9 9 0 1 1-2.12-9.36L23 10"/><polyline points="23 4 23 10 17 10"/>
        <circle cx="12" cy="12" r="1.6" fill="currentColor" stroke="none"/>
      </svg>
      <h1>Claude Auto-Resume</h1>
    </div>
    <div class="chips">
      ${chip(state.cliFound, 'CLI ready', 'CLI missing')}
      ${chip(
        hooksOk,
        state.hooksVia === 'plugin' ? 'Hooks via plugin' : 'Hooks registered',
        'Hooks not set up'
      )}
      ${chip(state.daemons > 0, `${state.daemons} daemon${state.daemons === 1 ? '' : 's'} active`, 'No daemon running')}
    </div>
    <button id="refresh" title="Refresh">⟳</button>
  </header>

  ${
    state.cliFound
      ? ''
      : `<section class="card hero empty">
          <div class="empty-icon">⚠️</div>
          <h2>Terminal tool not installed</h2>
          <p>The dashboard needs the claude-auto-resume CLI to act.</p>
          <p><button class="primary" id="install">Install in terminal</button></p>
        </section>`
  }

  ${heroCard(state.currentWs, task, state)}
  ${otherCards(state)}
  ${timeline(task)}

  <footer>
    ${compact ? '<a id="openFull">Open full view</a>' : ''}
    <a id="openLog">Log</a>
    <a id="openConfig">Config</a>
    <a href="https://github.com/0xsaju/claude-auto-resume">GitHub</a>
    <span class="spacer"></span>
    <span class="statefile">state: ~/.claude/auto-resume/state.json · live</span>
  </footer>
</div>
<script>
  const vscode = acquireVsCodeApi();
  const $ = (s, el) => (el || document).querySelector(s);
  const $$ = (s, el) => Array.from((el || document).querySelectorAll(s));

  $('#refresh').addEventListener('click', () => vscode.postMessage({ type: 'refresh' }));
  const full = $('#openFull'); if (full) full.addEventListener('click', () => vscode.postMessage({ type: 'openFull' }));
  const inst = $('#install'); if (inst) inst.addEventListener('click', () => vscode.postMessage({ type: 'install' }));
  $('#openLog').addEventListener('click', () => vscode.postMessage({ type: 'openLog' }));
  $('#openConfig').addEventListener('click', () => vscode.postMessage({ type: 'openConfig' }));

  // schedule/cancel buttons toggle or fire
  $$('.act-cancel').forEach((b) =>
    b.addEventListener('click', () => vscode.postMessage({ type: 'cancel', ws: b.dataset.ws }))
  );
  $$('.act-schedule').forEach((b) =>
    b.addEventListener('click', () => {
      const slot = document.querySelector('.composer-slot[data-ws="' + CSS.escape(b.dataset.ws) + '"]');
      if (slot) slot.hidden = !slot.hidden;
    })
  );
  $$('.composer').forEach((c) => {
    const ws = c.dataset.ws;
    $$('.plate', c).forEach((p) =>
      p.addEventListener('click', () => {
        $$('.plate', c).forEach((x) => x.classList.remove('selected'));
        p.classList.add('selected');
      })
    );
    const send = (when) => {
      const tier = $('.tier', c).value;
      const plate = $('.plate.selected', c);
      const session = plate ? plate.dataset.session : undefined;
      vscode.postMessage({ type: 'schedule', ws, when, tier, session });
    };
    $$('.preset', c).forEach((p) => p.addEventListener('click', () => send(p.dataset.when)));
    $('.go', c).addEventListener('click', () => {
      const v = $('.custom-when', c).value.trim();
      send(v || 'auto');
    });
  });

  // live countdowns
  function tick() {
    $$('.countdown[data-deadline]').forEach((el) => {
      const t = Date.parse(el.dataset.deadline);
      if (isNaN(t)) return;
      let d = Math.floor((t - Date.now()) / 1000);
      const out = $('.count', el);
      if (d <= 0) { out.textContent = 'due — daemon acts within 60s'; out.style.fontSize = '16px'; return; }
      const h = Math.floor(d / 3600); d %= 3600;
      const m = Math.floor(d / 60); const s = d % 60;
      out.textContent = (h ? h + 'h ' : '') + m + 'm ' + String(s).padStart(2, '0') + 's';
    });
  }
  tick();
  setInterval(tick, 1000);
</script>
</body>
</html>`;
}

module.exports = { createOrShow, resolveSidebar, update };
