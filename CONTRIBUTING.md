# Contributing to claude-standby

Thanks for considering a contribution. This project values small, honest,
well-tested changes over big ambitious ones.

## The most valuable contribution needs no code

Detection leans on a few **measured** formats (`docs/HOOK-FINDINGS.md`): the
limit-hit message wording, the session-store layout, and the status-line
rate stream. Real-world confirmation on hardware/accounts we can't test is
gold — especially the exact `used_percentage` value the status line reports
when Claude Code actually blocks (our `AR_LIMIT_PCT=100` default is
unverified). If you hit a real limit, `claude-standby doctor` shows what
the tool read; a sanitized paste of that (and the limit message wording) in
an issue directly improves detection.

Also valuable, takes ten seconds: the exit code of a limited headless
call — `claude -p "ok" --model haiku >/dev/null 2>&1; echo $?`.

## Ground rules (the short version of CLAUDE.md)

- **C1 — No invented formats.** Detection code may only match formats
  measured in `docs/HOOK-FINDINGS.md`, and must cite them.
- **C2 — Portable bash.** macOS (BSD userland) + Linux (GNU). No hard
  `jq` dependency — the state library degrades jq → python3 → awk/sed.
- **C4 — Never break the host.** The status-line sensor always `exit 0`,
  finishes fast, chains any existing status line, never writes stderr noise.
- **C6 — Real quota is precious.** All iterative testing runs against
  `test/fake-claude.sh`. Tests must never invoke the real `claude` or
  touch real user config (`~/.claude/settings.json` is isolated via
  `CLAUDE_SETTINGS_FILE` in tests — keep it that way).
- **Don't over-engineer.** This project has repeatedly chosen less: no
  package managers until asked, no features without a driver. If in
  doubt, open an issue before building.

## Development setup

```sh
git clone https://github.com/0xsaju/claude-standby
cd claude-standby
bash test/run-tests.sh     # must print "… 0 failed"
```

That's the whole setup — plain bash, no build step. The VS Code extension
(`vscode-extension/`) is plain JavaScript with zero dependencies: open the
folder in VS Code and press F5 to run it.

## Making changes

1. Keep the test suite green, and **add tests for what you change** —
   `test/run-tests.sh` is plain bash with `t_eq` / `t_contains` helpers;
   follow the existing sections.
2. State manipulation goes through `plugin/scripts/lib.sh`'s public API
   (`ar_task_get/upsert/set`, `ar_journal_append`, …) — never edit
   `state.json` by hand in code.
3. Changing the `state.json` schema? Bump `version` and add a
   `docs/DECISIONS.md` entry.
4. Any non-obvious decision gets a numbered entry in
   `docs/DECISIONS.md` (append-only, newest last, include the *why*).
5. Behavior changes must update `docs/USER-GUIDE.md` in the same PR.
6. Update `PROGRESS.md` if your change completes or adds a roadmap item.

## Pull requests

- One focused change per PR; explain the *why* in the description.
- `bash test/run-tests.sh` output (last line) in the PR description.
- No AI-attribution trailers in commit messages.

## Reporting bugs

`claude-standby doctor` output plus the relevant `log` lines
(`~/.claude/auto-resume/logs/plugin.log`) make almost any report
actionable. State is in `~/.claude/auto-resume/state.json` — sanitize
before pasting.

## License

By contributing you agree your contributions are licensed under the
[MIT License](LICENSE).
