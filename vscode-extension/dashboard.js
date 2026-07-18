// Dashboard webview for Claude Auto-Resume Cockpit.
// Pure presentation: receives a state snapshot from extension.js, renders
// the page, and posts user intents back — all writes still go through the
// CLI. Visual direction: option 1a ("VS Code native") of the Claude
// design project "Claude Auto-Resume Dashboard", with 1d's narrow-width
// collapse and 1b's colored timeline glyphs.
'use strict';

const vscode = require('vscode');
const path = require('path');

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
  'limit-hit': ['▲', 'orange'],
  'limit-lifted': ['●', 'green'],
  'reset-detected': ['◔', 'blue'],
  'reset-reached': ['●', 'yellow'],
  resumed: ['▶', 'blue'],
  'resume-failed': ['↻', 'red'],
  'resume-finished': ['■', 'desc'],
  done: ['✓', 'green'],
  failed: ['✗', 'red'],
  cancelled: ['⃠', 'desc'],
  'task-started': ['●', 'blue'],
};

const DEFAULT_PROMPT =
  'Limit reset. Continue from where you stopped. Check PROGRESS.md first.';

const BRAND_SVG = `<svg width="18" height="18" viewBox="0 0 18 18"><circle cx="9" cy="9" r="8" fill="#0B1220"/><path d="M9 4a5 5 0 1 0 5 5" fill="none" stroke="#F59E0B" stroke-width="1.8" stroke-linecap="round"/><path d="M14 3.5v3h-3z" fill="#F59E0B"/></svg>`;

let panel; // singleton tab panel
let sidebarView; // launcher view in the activity-bar sidebar

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
        await host.schedule(msg.ws, msg.when, msg.tier, msg.session, msg.prompt);
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
  panel.webview.html = render(host.collectState());
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
  webviewView.webview.html = `<!DOCTYPE html>
<html><head><meta charset="UTF-8">
<meta http-equiv="Content-Security-Policy"
  content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline';">
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
  <script>
    const vscode = acquireVsCodeApi();
    document.getElementById('open').addEventListener('click',
      () => vscode.postMessage({ type: 'openFull' }));
  </script>
</body></html>`;

  const openFull = () => {
    vscode.commands.executeCommand('claudeAutoResume.openDashboard');
    vscode.commands.executeCommand('workbench.action.closeSidebar');
  };
  webviewView.onDidChangeVisibility(() => {
    if (webviewView.visible) openFull();
  });
  openFull();
}

function update(host) {
  if (panel) panel.webview.html = render(host.collectState());
}

// ------------------------------------------------------------- fragments --

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

function shortHM(iso) {
  const m = /T(\d{2}:\d{2})/.exec(iso || '');
  return m ? m[1] : '';
}

function attemptSegs(used, max) {
  let segs = '';
  for (let i = 0; i < Math.max(1, max); i++)
    segs += `<span class="seg ${i < used ? 'on' : ''}"></span>`;
  return `<div class="attempts"><div class="segs">${segs}</div>
    <span class="dim">attempt ${used} of ${max}</span></div>`;
}

const BRAND_SVG_LG = `<svg width="44" height="44" viewBox="0 0 18 18"><circle cx="9" cy="9" r="8" fill="#0B1220"/><path d="M9 4a5 5 0 1 0 5 5" fill="none" stroke="#F59E0B" stroke-width="1.8" stroke-linecap="round"/><path d="M14 3.5v3h-3z" fill="#F59E0B"/></svg>`;

function heroCard(ws, task, state) {
  if (!ws || !task) {
    return `<section class="welcome">
      ${BRAND_SVG_LG}
      <h1>Claude Auto-Resume</h1>
      <p class="dim tagline">Your Claude Code task survives the usage limit —<br>schedule a resume once and walk away.</p>
      ${
        ws
          ? `<p class="dim mono wsline">${esc(ws)}</p>`
          : `<p class="dim wsline">${
              (state.projects || []).length
                ? 'No folder open — you can still schedule for any project below.'
                : 'Open a workspace folder to get started.'
            }</p>`
      }
    </section>`;
  }
  const hue = STATUS_HUE[task.status] || 'desc';
  const label = STATUS_LABEL[task.status] || task.status;
  const auto = task.resume_mode === 'auto';
  const active = ['waiting', 'resuming', 'running'].includes(task.status);
  let timing = '';
  if (task.status === 'waiting' && task.resume_at) {
    timing = `<div class="count-row countdown" data-deadline="${esc(task.resume_at)}">
      <span class="count">—</span>
      <span class="dim">${auto ? 'until next probe' : 'until resume'} · ${esc(
        shortHM(task.resume_at)
      )}</span>
    </div>`;
  } else if (task.status === 'resuming') {
    timing = `<div class="count-row"><span class="resuming-pulse c-blue">● session running</span></div>`;
  } else if (task.status === 'failed') {
    timing = `<div class="count-row"><span class="dim">Gave up after ${
      task.resume_count ?? 0
    } attempt(s) — reschedule below to retry.</span></div>`;
  }
  const wsSessions = (state.sessionsByWs && state.sessionsByWs[ws]) || [];
  const pinnedInfo = wsSessions.find((s) => s.id === task.session_id);
  const sessionLine = task.session_id
    ? `<div class="session-line dim" title="${esc(task.session_id)}">↻ continues “${esc(
        (pinnedInfo && pinnedInfo.summary) || task.session_id.slice(0, 8)
      )}” <span class="mono">${esc(task.session_id.slice(0, 8))}</span></div>`
    : active
      ? `<div class="session-line c-orange">⚠ no session pinned — resume starts a new chat</div>`
      : '';
  return `<section class="card hero">
    <div class="hd">
      <span class="dot bg-${hue}"></span>
      <span class="status-word c-${hue}">${esc(label)}</span>
      <span class="badge">${esc(task.importance)}</span>
      ${auto ? '<span class="badge auto">auto-detect</span>' : ''}
      <span class="spacer"></span>
      <span class="dim mono ellip" title="${esc(ws)}">${esc(ws)}</span>
    </div>
    ${timing}
    ${attemptSegs(task.resume_count ?? 0, task.max_resumes ?? 3)}
    ${
      task.original_prompt
        ? `<div class="quote dim">“${esc(task.original_prompt.slice(0, 160))}”</div>`
        : ''
    }
    ${sessionLine}
    <div class="actions">
      <button class="primary act-schedule" data-ws="${esc(ws)}">${
        active ? 'Reschedule' : 'Schedule resume'
      }</button>
      ${
        active
          ? `<button class="outline-danger act-cancel" data-ws="${esc(ws)}">Cancel…</button>`
          : ''
      }
    </div>
  </section>`;
}

function composerSection(state, defaultWs, hasTask) {
  if (!(state.projects || []).length) return '';
  const options = state.projects
    .map(
      (ws) =>
        `<option value="${esc(ws)}" ${ws === defaultWs ? 'selected' : ''}>${esc(
          path.basename(ws)
        )}${ws === state.currentWs ? ' (current)' : ''}</option>`
    )
    .join('');
  return `<section class="card composer">
    <div class="c-title">${hasTask ? 'Reschedule' : 'Schedule a resume'}</div>
    <div class="field">
      <label>Project</label>
      <select class="ws-select">${options}</select>
    </div>
    <div class="field">
      <label>Conversation to continue</label>
      <select class="session-select"></select>
    </div>
    <div class="field">
      <label>Prompt on resume <span class="opt">optional</span></label>
      <input class="prompt-input" placeholder="${esc(DEFAULT_PROMPT)}" />
    </div>
    <div class="field">
      <label>When</label>
      <div class="chips">
        <button class="chip selected" data-when="auto" title="Probe until the limit lifts, then resume">Auto-detect reset</button>
        <button class="chip" data-when="30m">30m</button>
        <button class="chip" data-when="1h">1h</button>
        <button class="chip" data-when="2h30m">2h30m</button>
        <button class="chip" data-when="now">Now</button>
        <input class="custom-when" placeholder="20:00 · 45m · ISO" />
      </div>
    </div>
    <div class="c-actions">
      <select class="tier">
        <option value="">tier: keep</option>
        <option value="critical">critical</option>
        <option value="normal">normal</option>
        <option value="low">low</option>
      </select>
      <span class="spacer"></span>
      <button class="go">Schedule resume</button>
    </div>
  </section>`;
}

function otherRows(state) {
  const others = Object.entries(state.tasks || {}).filter(
    ([ws]) => ws !== state.currentWs
  );
  if (!others.length) return '';
  const rows = others
    .map(([ws, t]) => {
      const hue = STATUS_HUE[t.status] || 'desc';
      const active = ['waiting', 'resuming', 'running'].includes(t.status);
      const when =
        t.status === 'waiting' && t.resume_at ? ` · ${shortHM(t.resume_at)}` : '';
      return `<div class="wsrow">
        <span class="dot bg-${hue} ${t.status === 'resuming' ? 'pulse' : ''}"></span>
        <span class="ellip" title="${esc(ws)}">${esc(ws)}</span>
        <span class="spacer"></span>
        <span class="dim">${esc((STATUS_LABEL[t.status] || t.status).toLowerCase())}${when}</span>
        <a class="act-schedule" data-ws="${esc(ws)}">schedule</a>
        ${active ? `<a class="c-red act-cancel" data-ws="${esc(ws)}">cancel</a>` : ''}
      </div>`;
    })
    .join('');
  return `<h3 class="section-title">Other workspaces</h3><div class="wsrows">${rows}</div>`;
}

function timelineSection(task) {
  if (!task || !(task.journal || []).length) return '';
  const rows = task.journal
    .slice(-12)
    .reverse()
    .map((e) => {
      const [glyph, hue] = EVENT_GLYPH[e.event] || ['·', 'desc'];
      return `<div class="tl-row">
        <span class="tl-glyph c-${hue}">${glyph}</span>
        <span class="dim mono tl-ts">${esc(shortHM(e.ts) || '—')}</span>
        <span class="tl-text">${esc(e.event)}${
          e.detail ? ` <span class="dim">— ${esc(e.detail)}</span>` : ''
        }</span>
      </div>`;
    })
    .join('');
  return `<h3 class="section-title">Activity</h3><div class="timeline">${rows}</div>`;
}

function render(state) {
  const task = state.currentWs ? state.tasks[state.currentWs] : undefined;
  const hooksOk = state.hooksVia !== null;
  const healthOk = state.cliFound && hooksOk;
  const composerWs =
    state.currentWs && (state.projects || []).includes(state.currentWs)
      ? state.currentWs
      : (state.projects || [])[0];
  return `<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<meta http-equiv="Content-Security-Policy"
  content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline';">
<style>
  :root { color-scheme: light dark; }
  * { box-sizing: border-box; }
  html, body { height: 100%; }
  body {
    font-family: var(--vscode-font-family);
    font-size: 13px;
    color: var(--vscode-foreground);
    background: var(--vscode-editor-background);
    margin: 0;
    display: flex; flex-direction: column;
  }
  .wrap {
    width: min(620px, calc(100% - 48px));
    margin: 0 auto; padding: 28px 0 24px;
    flex: 1; display: flex; flex-direction: column;
  }
  body.centered .wrap { justify-content: center; padding-bottom: 9vh; }
  .wrap > section + section { margin-top: 20px; }
  .mono { font-family: var(--vscode-editor-font-family, ui-monospace, Menlo, monospace); font-size: .92em; }
  .dim { color: var(--vscode-descriptionForeground); }
  .spacer { flex: 1; }
  .ellip { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; min-width: 0; }
  a { color: var(--vscode-textLink-foreground); text-decoration: none; cursor: pointer; }
  .c-yellow { color: var(--vscode-charts-yellow, #cca700); }
  .c-blue   { color: var(--vscode-charts-blue, #3794ff); }
  .c-green  { color: var(--vscode-charts-green, #89d185); }
  .c-red    { color: var(--vscode-charts-red, #f48771); }
  .c-orange { color: var(--vscode-charts-orange, #d18616); }
  .c-desc   { color: var(--vscode-descriptionForeground); }
  .bg-yellow { background: var(--vscode-charts-yellow, #cca700); }
  .bg-blue   { background: var(--vscode-charts-blue, #3794ff); }
  .bg-green  { background: var(--vscode-charts-green, #89d185); }
  .bg-red    { background: var(--vscode-charts-red, #f48771); }
  .bg-orange { background: var(--vscode-charts-orange, #d18616); }
  .bg-desc   { background: var(--vscode-descriptionForeground); }

  header.top {
    display: flex; align-items: center; gap: 8px;
    padding: 10px 16px; margin: 0 -16px 16px;
    border-bottom: 1px solid var(--vscode-widget-border, rgba(128,128,128,.35));
  }
  header.top .name { font-weight: 600; font-size: 12px; letter-spacing: .2px; }
  .health { display: flex; align-items: center; gap: 5px; font-size: 11px; color: var(--vscode-descriptionForeground); }
  .dot { width: 7px; height: 7px; border-radius: 50%; display: inline-block; flex: none; }
  #refresh {
    background: none; border: none; cursor: pointer; opacity: .6; padding: 2px 4px;
    color: var(--vscode-foreground); font-size: 14px;
  }
  #refresh:hover { opacity: 1; }

  .card {
    background: var(--vscode-editorWidget-background);
    border: 1px solid var(--vscode-widget-border, rgba(128,128,128,.35));
    border-radius: 6px; padding: 18px 20px;
  }
  .hero .hd { display: flex; align-items: center; gap: 8px; }
  .dot { width: 8px; height: 8px; }
  .status-word { font-size: 11px; font-weight: 600; letter-spacing: .6px; text-transform: uppercase; }
  .badge {
    font-size: 11px; padding: 1px 7px; border-radius: 9px;
    background: var(--vscode-badge-background); color: var(--vscode-badge-foreground);
  }
  .badge.auto { background: transparent; border: 1px solid #F59E0B; color: #F59E0B; }
  .hd .mono { font-size: 11px; max-width: 40%; }
  .count-row { display: flex; align-items: baseline; gap: 12px; margin-top: 12px; flex-wrap: wrap; }
  .count { font-size: 40px; font-weight: 600; font-variant-numeric: tabular-nums; letter-spacing: -.5px; line-height: 1.1; }
  .count.due { font-size: 16px; font-weight: 500; }
  .resuming-pulse { font-size: 16px; animation: pulse 1.6s infinite; }
  .attempts { display: flex; align-items: center; gap: 10px; margin-top: 10px; font-size: 11px; }
  .segs { display: flex; gap: 3px; }
  .seg { width: 22px; height: 4px; border-radius: 2px; background: var(--vscode-widget-border, rgba(128,128,128,.35)); }
  .seg.on { background: #F59E0B; }
  .quote {
    margin-top: 12px; font-size: 12px;
    border-left: 2px solid var(--vscode-widget-border, rgba(128,128,128,.35));
    padding-left: 10px;
  }
  .session-line { font-size: 12px; margin-top: 10px; }
  .actions { display: flex; gap: 8px; margin-top: 16px; }
  button {
    font-family: inherit; font-size: 12px; cursor: pointer; border-radius: 3px;
    border: 1px solid transparent; padding: 5px 14px;
    background: var(--vscode-button-secondaryBackground);
    color: var(--vscode-button-secondaryForeground);
  }
  button.primary { background: var(--vscode-button-background); color: var(--vscode-button-foreground); border: none; }
  button.outline-danger {
    background: transparent; color: var(--vscode-charts-red, #f48771);
    border: 1px solid var(--vscode-widget-border, rgba(128,128,128,.35));
  }
  button:hover { filter: brightness(1.12); }
  .welcome { text-align: center; padding: 8px 0 4px; }
  .welcome h1 { font-size: 17px; font-weight: 600; margin: 12px 0 6px; letter-spacing: .2px; }
  .welcome .tagline { font-size: 12.5px; margin: 0; line-height: 1.6; }
  .welcome .wsline { font-size: 11px; margin: 12px 0 0; }

  .section-title {
    font-size: 11px; font-weight: 600; letter-spacing: .6px; text-transform: uppercase;
    color: var(--vscode-descriptionForeground); margin: 22px 0 8px;
  }
  .composer .c-title { font-size: 13px; font-weight: 600; margin-bottom: 14px; }
  .field { margin-bottom: 14px; }
  .field > label {
    display: block; font-size: 11px; font-weight: 600; letter-spacing: .5px;
    text-transform: uppercase; color: var(--vscode-descriptionForeground);
    margin-bottom: 6px;
  }
  .field .opt { font-weight: 400; text-transform: none; letter-spacing: 0; opacity: .7; }
  select, .custom-when, .prompt-input {
    font-family: inherit; font-size: 12.5px; padding: 6px 10px; border-radius: 4px;
    border: 1px solid var(--vscode-input-border, var(--vscode-widget-border, rgba(128,128,128,.35)));
    background: var(--vscode-input-background); color: var(--vscode-input-foreground);
  }
  .ws-select, .session-select, .prompt-input { width: 100%; }
  .chips { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; }
  .chip {
    font-size: 12px; padding: 5px 12px; border-radius: 12px; background: transparent;
    border: 1px solid var(--vscode-widget-border, rgba(128,128,128,.35));
    color: var(--vscode-foreground); cursor: pointer;
  }
  .chip:hover { border-color: var(--vscode-descriptionForeground); }
  .chip.selected { border-color: #F59E0B; color: #F59E0B; background: rgba(245,158,11,.08); }
  .custom-when { width: 130px; }
  .c-actions {
    display: flex; align-items: center; gap: 10px; margin-top: 4px; padding-top: 14px;
    border-top: 1px solid var(--vscode-widget-border, rgba(128,128,128,.35));
  }
  .go {
    background: #F59E0B; color: #1a1200; font-weight: 600; border: none;
    padding: 6px 18px; border-radius: 4px;
  }
  .go:hover { filter: brightness(1.08); }

  .wsrows { display: flex; flex-direction: column; gap: 6px; }
  .wsrow {
    display: flex; align-items: center; gap: 10px; padding: 8px 12px; font-size: 12px;
    border: 1px solid var(--vscode-widget-border, rgba(128,128,128,.35)); border-radius: 5px;
    background: var(--vscode-editorWidget-background);
  }
  .wsrow .dot { width: 7px; height: 7px; }
  .wsrow a { font-size: 11px; margin-left: 4px; }
  .pulse { animation: pulse 1.6s infinite; }

  .timeline { display: flex; flex-direction: column; gap: 7px; font-size: 12px; }
  .tl-row { display: flex; gap: 8px; align-items: baseline; }
  .tl-glyph { width: 14px; text-align: center; flex: none; }
  .tl-ts { width: 40px; flex: none; font-variant-numeric: tabular-nums; }
  .tl-text { min-width: 0; }

  footer {
    display: flex; gap: 14px; margin-top: 28px; padding-top: 12px; font-size: 11px;
    border-top: 1px solid var(--vscode-widget-border, rgba(128,128,128,.35));
    color: var(--vscode-descriptionForeground); align-items: center;
  }
  body:not(.centered) footer { margin-top: auto; padding-top: 20px; }
  @keyframes pulse { 0%,100% { opacity: 1; } 50% { opacity: .35; } }

  @media (max-width: 480px) {
    .wrap { width: calc(100% - 24px); padding-top: 16px; }
    .card { padding: 14px; }
    .hd .mono { display: none; }
    .count { font-size: 28px; }
    .actions button { flex: 1; }
    .c-actions { flex-wrap: wrap; }
    footer .statefile { display: none; }
  }
</style>
</head>
<body class="${task ? '' : 'centered'}">
<header class="top">
  ${BRAND_SVG}
  <span class="name">Claude Auto-Resume</span>
  <span class="spacer"></span>
  <span class="health" title="CLI ${state.cliFound ? 'found' : 'missing'} · hooks ${
    hooksOk ? `via ${state.hooksVia}` : 'not set up'
  } · ${state.daemons} daemon(s) running">
    <span class="dot bg-${healthOk ? 'green' : 'orange'}"></span>
    CLI · hooks · ${state.daemons} daemon${state.daemons === 1 ? '' : 's'}
  </span>
  <button id="refresh" title="Refresh">⟳</button>
</header>
<div class="wrap">
  ${
    state.cliFound
      ? ''
      : `<section class="card hero-empty" style="margin-bottom:14px">
          <h2>Terminal tool not installed</h2>
          <p class="dim">The dashboard needs the claude-auto-resume CLI to act.</p>
          <p><button class="primary" id="install">Install in terminal</button></p>
        </section>`
  }
  ${heroCard(state.currentWs, task, state)}
  ${composerSection(state, composerWs, Boolean(task))}
  ${otherRows(state)}
  ${timelineSection(task)}
  <footer>
    <a id="openLog">Log</a>
    <a id="openConfig">Config</a>
    <a href="https://github.com/0xsaju/claude-auto-resume">GitHub</a>
    <span class="spacer"></span>
    <span class="statefile mono">~/.claude/auto-resume/state.json · live</span>
  </footer>
</div>
<script type="application/json" id="data-sessions">${jsonBlock(state.sessionsByWs || {})}</script>
<script type="application/json" id="data-pinned">${jsonBlock(pinnedByWs(state))}</script>
<script>
  const vscode = acquireVsCodeApi();
  const $ = (s, el) => (el || document).querySelector(s);
  const $$ = (s, el) => Array.from((el || document).querySelectorAll(s));

  $('#refresh').addEventListener('click', () => vscode.postMessage({ type: 'refresh' }));
  const inst = $('#install'); if (inst) inst.addEventListener('click', () => vscode.postMessage({ type: 'install' }));
  $('#openLog').addEventListener('click', () => vscode.postMessage({ type: 'openLog' }));
  $('#openConfig').addEventListener('click', () => vscode.postMessage({ type: 'openConfig' }));

  // ---- composer: project -> session -> prompt -> when -------------------
  const SESSIONS = JSON.parse(document.getElementById('data-sessions').textContent);
  const PINNED = JSON.parse(document.getElementById('data-pinned').textContent);
  const composer = $('.composer');

  function ago(ms) {
    const d = Math.max(0, Math.floor((Date.now() - ms) / 1000));
    if (d < 3600) return Math.floor(d / 60) + 'm ago';
    if (d < 86400) return Math.floor(d / 3600) + 'h ago';
    return Math.floor(d / 86400) + 'd ago';
  }

  // Options are built with DOM APIs (never innerHTML) — summaries are
  // user-conversation text and must not be interpreted as markup.
  function fillSessions(ws) {
    const sel = $('.session-select', composer);
    if (!sel) return;
    sel.textContent = '';
    const list = SESSIONS[ws] || [];
    const pinned = PINNED[ws];
    list.forEach((s) => {
      const o = document.createElement('option');
      o.value = s.id;
      o.textContent =
        (s.summary ? s.summary.slice(0, 46) : s.id.slice(0, 8)) +
        ' · ' + ago(s.mtime) + ' · ' + s.id.slice(0, 8);
      sel.append(o);
    });
    const n = document.createElement('option');
    n.value = 'new';
    n.textContent = list.length ? 'New chat (start fresh)' : 'New chat — no sessions here yet';
    sel.append(n);
    sel.value = pinned && list.some((s) => s.id === pinned) ? pinned : (list[0] ? list[0].id : 'new');
  }

  if (composer) {
    const wsSelect = $('.ws-select', composer);
    fillSessions(wsSelect.value);
    wsSelect.addEventListener('change', () => fillSessions(wsSelect.value));

    // "When" chips behave like radio buttons; typing a custom time
    // deselects them. One primary button submits the whole form.
    const customWhen = $('.custom-when', composer);
    $$('.chip', composer).forEach((c) =>
      c.addEventListener('click', () => {
        $$('.chip', composer).forEach((x) => x.classList.remove('selected'));
        c.classList.add('selected');
        customWhen.value = '';
      })
    );
    customWhen.addEventListener('input', () => {
      if (customWhen.value.trim())
        $$('.chip', composer).forEach((x) => x.classList.remove('selected'));
    });

    $('.go', composer).addEventListener('click', () => {
      const chip = $('.chip.selected', composer);
      const when = customWhen.value.trim() || (chip ? chip.dataset.when : 'auto');
      const prompt = $('.prompt-input', composer).value.trim();
      vscode.postMessage({
        type: 'schedule',
        ws: wsSelect.value,
        when,
        tier: $('.tier', composer).value,
        session: $('.session-select', composer).value || undefined,
        prompt: prompt || undefined,
      });
    });
  }

  // schedule buttons target the composer at their workspace
  $$('.act-schedule').forEach((b) =>
    b.addEventListener('click', () => {
      if (!composer) return;
      const wsSelect = $('.ws-select', composer);
      if (b.dataset.ws && [...wsSelect.options].some((o) => o.value === b.dataset.ws)) {
        wsSelect.value = b.dataset.ws;
        fillSessions(b.dataset.ws);
      }
      composer.scrollIntoView({ behavior: 'smooth', block: 'center' });
    })
  );
  $$('.act-cancel').forEach((b) =>
    b.addEventListener('click', () => vscode.postMessage({ type: 'cancel', ws: b.dataset.ws }))
  );

  // live countdown
  function tick() {
    $$('.countdown[data-deadline]').forEach((el) => {
      const t = Date.parse(el.dataset.deadline);
      if (isNaN(t)) return;
      let d = Math.floor((t - Date.now()) / 1000);
      const out = $('.count', el);
      if (d <= 0) { out.textContent = 'due — daemon acts within 60s'; out.classList.add('due'); return; }
      out.classList.remove('due');
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

module.exports = { createOrShow, resolveSidebar, update, render };
