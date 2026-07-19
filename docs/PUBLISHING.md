# Publishing the VS Code extension

The cockpit (`vscode-extension/`) ships to **two** registries, because
VS Code and Cursor/Windsurf/VSCodium use different ones:

- **Microsoft Marketplace** — VS Code (`marketplace.visualstudio.com`)
- **Open VSX** — Cursor, Windsurf, VSCodium (`open-vsx.org`)

Publisher id is **`0xsaju`** (set in `package.json`); it must exist on each
registry under an account you control. Tokens are personal — never commit
them, and prefer running the publish commands yourself (they take a secret).

## One-time build

```sh
cd vscode-extension
rm -f *.vsix
npx @vscode/vsce package --no-dependencies -o claude-auto-resume-cockpit-<version>.vsix
```

The `.vsix` is gitignored (build artifact). `.vscodeignore` keeps dev files
(DESIGN-BRIEF.md, other vsix) out of the package.

## A. Microsoft Marketplace (VS Code)

1. Create a free Azure DevOps org: https://dev.azure.com
2. Create the `0xsaju` publisher: https://marketplace.visualstudio.com/manage
3. Azure DevOps → User Settings → **Personal Access Tokens** → New:
   scope **Marketplace → Manage**, organization **All accessible**.
4. Publish:
   ```sh
   npx @vscode/vsce publish -p <AZURE_PAT>
   # or: vsce login 0xsaju   (paste PAT once), then: vsce publish
   ```

## B. Open VSX (Cursor / Windsurf / VSCodium)

1. Sign in at https://open-vsx.org with GitHub; create an access token
   (Settings → Access Tokens).
2. First time only, claim the namespace:
   ```sh
   npx ovsx create-namespace 0xsaju -p <OVSX_TOKEN>
   ```
3. Publish the built vsix:
   ```sh
   npx ovsx publish claude-auto-resume-cockpit-<version>.vsix -p <OVSX_TOKEN>
   ```

## Automated publishing (CI)

`.github/workflows/publish-extension.yml` publishes to **both** registries
when you push a tag matching `ext-v*` (or via the Actions tab's
"Run workflow" button). It publishes whatever version is in
`vscode-extension/package.json` — that is the source of truth; the tag only
triggers the run.

One-time setup — add two repo secrets (GitHub → Settings → Secrets and
variables → Actions → New repository secret):

- **`VSCE_PAT`** — Azure DevOps PAT, scope **Marketplace: Manage**,
  organization **All accessible organizations**.
- **`OVSX_TOKEN`** — Open VSX access token (open-vsx.org → Settings →
  Access Tokens). Create the `0xsaju` namespace once first
  (`npx ovsx create-namespace 0xsaju -p <token>`).

A missing secret skips that registry, so you can start with just one.

Cutting a release once the secrets exist:

```sh
# 1. bump the version (source of truth)
#    edit vscode-extension/package.json -> "version": "0.8.7"
git commit -am "Extension 0.8.7: <what changed>"
# 2. tag and push — this fires the workflow
git tag ext-v0.8.7
git push origin main --tags
```

The workflow packages the vsix and pushes it to the Marketplace and Open VSX.
No manual upload, no local token handling.

## Release checklist

- [ ] `bash test/run-tests.sh` green
- [ ] bump `vscode-extension/package.json` `version`
- [ ] rebuild the `.vsix` (above)
- [ ] `vsce publish` (Marketplace) and `ovsx publish` (Open VSX)
- [ ] tag the release in git and note the version in `PROGRESS.md`

## Requirements already satisfied

`displayName`, `description`, `publisher`, `icon` (256×256 ≥ the 128 min),
`license`, `repository`, `homepage`, `bugs`, `engines.vscode`, `categories`
(`AI`, `Other`), `keywords`, a non-trivial `README.md`, and a `.vscodeignore`.
`vsce package` builds with no warnings.
