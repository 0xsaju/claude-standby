// Out-of-tree cockpit render smoke test — run by run-tests.sh when node exists
// (the suite stays green on machines without node). Stubs the `vscode` module
// and exercises dashboard.render(), including the stream-json parser
// (renderLive) which must NEVER throw — a throw there breaks the whole webview.
const Module = require('module');
const path = require('path');
const orig = Module._load;
Module._load = function (req, ...rest) {
  if (req === 'vscode') return {}; // render() is pure HTML; no vscode needed
  return orig.call(this, req, ...rest);
};
const dash = require(path.join(__dirname, '..', 'vscode-extension', 'dashboard.js'));

let fails = 0;
function check(cond, name) {
  console.log((cond ? 'ok   - ' : 'FAIL - ') + name);
  if (!cond) fails++;
}

const ws = '/Users/x/proj';
const base = {
  extVersion: '0.9.4', currentWs: ws, projects: [ws], stuckWs: [],
  sessionsByWs: { [ws]: [] }, cliFound: true, daemons: 1, author: {},
  claudeFound: true, sensorRegistered: true, stateStatus: 'ok',
  updatePending: false, liveOutput: '', rate: null, ready: true, tasks: {},
};

// 1) renderLive must not throw on bare `null` / number / non-JSON lines
//    (regression guard: JSON.parse('null') === null, then null.type threw).
const nasty = [
  'null',
  '123',
  'not json at all',
  '{"type":"assistant","message":{"content":"hi there"}}',            // fake-claude string content
  '{"type":"assistant","message":{"content":[{"type":"text","text":"edited file"},{"type":"tool_use","name":"Edit"}]}}', // real-claude blocks
  '{"type":"result","subtype":"success","result":"done cleanly"}',
].join('\n');
let html = '';
try {
  html = dash.render({
    ...base, liveOutput: nasty,
    tasks: { [ws]: { status: 'resuming', session_id: 'fa66afd7-1111', importance: 'critical', journal: [] } },
  });
  check(true, 'render survives null/garbage stream-json lines (no throw)');
} catch (e) {
  check(false, 'render survives null/garbage stream-json lines (no throw): ' + e.message);
}
check(html.includes('hi there'), 'live: fake-claude string content parsed');
check(html.includes('edited file'), 'live: real-claude block text parsed');
check(html.includes('· Edit'), 'live: tool_use rendered');
check(html.includes('done cleanly'), 'live: result parsed');
check(html.includes('▶ Open in Claude Code'), 'resuming: open-in-claude button');

// 2) header alert pill surfaces update-pending + interrupted resume
html = dash.render({
  ...base, updatePending: true, stuckWs: [ws],
  tasks: { [ws]: { status: 'waiting', resume_at: '2026-07-24T18:00:00+0600', session_id: 'a', importance: 'normal', journal: [] } },
});
check(html.includes('alert-pill'), 'alerts: pill rendered');
check(html.includes('Update available'), 'alerts: update-pending label');

// 3) done task still offers the open button and does not crash on empty output
html = dash.render({
  ...base, liveOutput: '',
  tasks: { [ws]: { status: 'done', session_id: 'b', importance: 'critical', journal: [] } },
});
check(html.includes('Resumed &amp; finished'), 'done: finished label');

console.log(fails ? `COCKPIT SMOKE FAILED (${fails})` : 'COCKPIT SMOKE OK');
process.exit(fails ? 1 : 0);
