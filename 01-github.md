# Step 01: GitHub side

| | |
|---|---|
| Required | yes |
| Depends on | none |
| If you skip it: security | The agent keeps whatever your current `gh` login and SSH key allow, which may include creating and deleting repos. |
| If you skip it: operations | [Step 02](02-agent-routing.md) has no tokens to install. |
| If you skip it: change elsewhere | nothing |

Browser work: two kinds of fine-grained personal access token (PAT),
and rulesets on the repos that matter. All tokens belong to your own
account, so the agent works as you. GitHub refuses admin calls because
none of the tokens is allowed to make them.

A fine-grained PAT covers one resource owner: your account, or one org.
Some orgs require an owner to approve fine-grained PATs before they
work; GitHub shows the token as pending until then.

## Restrict your own `gh` login

The agent runs as your macOS user, and your `gh` login sits in the
macOS keychain. [Step 04](04-claude-code-sandbox.md#known-limits) shows
the agent can probably read the keychain, so whatever your login can
do, the agent can do too. Make your own login unable to administer
anything. Check what you have:

```zsh
gh auth status
```

- **`Token: gho_…`** is a browser OAuth login. It can create and delete
  repos. Replace it.
- **`Token: github_pat_…`** is already a fine-grained PAT. Keep it only
  if it matches [The token recipe](#the-token-recipe): no Administration,
  and no Workflows, Secrets or Webhooks write. Otherwise replace it.

To replace it, create a token as in [The token
recipe](#the-token-recipe) for the owner you use `gh` with most, then
log in from the clipboard so it never appears in history. Pause any
clipboard manager and turn off Handoff first, or the token lands in
clipboard history:

```zsh
pbpaste | gh auth login --with-token
pbcopy < /dev/null
gh auth status
```

If `gh auth status` lists more than one account, log out of each one
you are not keeping:

```zsh
gh auth logout --hostname github.com --user LOGIN
```

Logging in with a token leaves the old browser login valid on GitHub.
Revoke it: GitHub → **Settings → Applications → Authorized OAuth Apps
→ GitHub CLI → Revoke**.

A PAT covers one owner, so your own `gh` stops working on every other
owner. Use the browser there, or a `gh-admin` token for that owner.

Admin work then goes in the browser, or through
[`gh-admin`](elevated-gh-access.md), which keeps a stronger token
locked in Bitwarden and uses it for one command at a time.

## Find other GitHub credentials

Your `gh` login is not the only GitHub credential the agent could
reach. Find the others and remove what you do not need. These commands
print names and counts, never a secret:

```zsh
security dump-keychain 2>/dev/null | grep -iE '"(svce|srvr)"<blob>=.*github'
grep -c github.com ~/.git-credentials ~/.netrc 2>/dev/null
grep -lE 'GH_TOKEN|GITHUB_TOKEN' ~/.zshenv ~/.zprofile ~/.zshrc ~/.zlogin ~/.bash_profile ~/.bashrc ~/.profile 2>/dev/null
grep -rlE 'gh[pousr]_[A-Za-z0-9]{36}|github_pat_' ~/.npmrc ~/.docker ~/.config 2>/dev/null
jq -r '[.. | objects | .mcpServers? // empty | keys[]] | unique[]' ~/.claude.json
```

- **A keychain item** that names GitHub holds a token: one git stored
  for HTTPS, or an app's, such as GitHub Desktop's. Delete the ones you
  do not need in Keychain Access. `security` without `-d` prints item
  names only.
- **A file that holds a token**, such as `~/.npmrc` or
  `~/.docker/config.json`. Remove the token, and revoke it if it is
  classic. The agent's own tokens under `~/.config/agent-git/tokens`
  match too, once step 02 has run.
- **A GitHub MCP server or connector.** The last command lists the MCP
  servers in `~/.claude.json` by name; also check claude.ai's
  connectors. An MCP server runs outside the sandbox and the routing,
  and often holds a classic token. Remove it, or give it a token made
  by [The token recipe](#the-token-recipe).
- **`~/.git-credentials` or `~/.netrc`** with a `github.com` line holds
  a token in plain text. Delete that line.
- **A startup file that sets `GH_TOKEN` or `GITHUB_TOKEN`** hands that
  token to every shell. Remove the line and revoke the token. The
  agent's env file clears both, but a bypass still finds the file.
- **A signed-in browser** keeps your GitHub session cookie, and the
  Bitwarden extension's vault copy, in its profile folder.
  [Step 04](04-claude-code-sandbox.md#settings) denies the agent those
  folders.
- **Old tokens and grants** stay live until you revoke them. Review
  [github.com/settings/tokens](https://github.com/settings/tokens) and
  [github.com/settings/applications](https://github.com/settings/applications).
  A classic token reaches every repo you can reach.

## Find package-registry tokens

Package managers keep registry tokens in your home folder. Agents, and
the install scripts they run, can read these files. This prints each
file and how many auth lines it holds, never a secret:

```zsh
for f in ~/.npmrc ~/.yarnrc.yml ~/.pypirc ~/.cargo/credentials.toml ~/.gem/credentials; do [ -f "$f" ] && printf '%s: %s auth lines\n' "$f" "$(grep -c -i -E 'token|_auth|password' "$f")"; done
```

- **Keep only read-only tokens.** Use granular tokens, limited to the
  packages you install. A token that can publish lets an agent, or a
  bad install script, publish as you.
- **Remove dead ones.** An expired or revoked token makes every request
  fail with 401, even for public packages.
  [Step 05](05-living-with-the-sandbox.md#package-installs) covers the
  errors that follow.

## Create the agent's token for each owner

Create one PAT per owner the agent works in, such as `ExampleOrg` and
`alice`, following the recipe below. Name each one so you can tell it
apart, for example `agent-ExampleOrg`. Keep them separate from your
own login's token, so you can revoke the agent's without touching
yours.

Do not create them all up front. GitHub shows each token once. Never
save one yourself, in a file or in notes; the installer stores it. Run
[the installer](02-agent-routing.md#run-the-installer) first. At each
"Paste the agent's PAT for OWNER" prompt, create that owner's token in
the browser and paste it straight in.

## The token recipe

GitHub → **Settings → Developer settings → Personal access tokens →
Fine-grained tokens → Generate new token.**

| Field | Value |
|---|---|
| Resource owner | the org, or your account |
| Expiration | a date, at most a year out; set a reminder to replace it |
| Repository access | **Only select repositories**: the repos the agent works on |

Repository permissions (everything else stays No access):

| Permission | Level | Why |
|---|---|---|
| Contents | Read and write | clone, fetch, push branches |
| Pull requests | Read and write | open, update, comment on and review PRs |
| Issues | Read and write | issues, labels, PR conversation comments |
| Actions | Read | inspect runs and logs |
| Commit statuses | Read | see commit statuses |
| Metadata | Read | mandatory, auto-selected |

Organization permissions and Account permissions: all No access.

Fine-grained tokens have no Checks permission, so `gh pr checks` and
other check-run reads fail with 403. The agent reads CI through Actions
instead: `gh run list --branch BRANCH` and `gh run view N`.

Deliberately absent:

- **Administration.** No creating, deleting or archiving repos, no
  settings, no rulesets, no collaborators.
- **Workflows.** The token cannot push a commit that touches
  `.github/workflows/*`. CI still runs scripts the agent can edit, such
  as `package.json` or a `Makefile`, so a workflow that holds secrets
  should not run on agent branches without review. Contents write also
  allows `repository_dispatch`, so a workflow on that event runs when
  the agent asks.
- **Commit statuses write.** The token cannot mark a required check as
  passed.
- **Secrets, Variables, Environments, Deployments, Webhooks, Pages.**

## Rulesets

Server-side and identity-agnostic. Rulesets are the only guard on
protected branches: local hooks are bypassed by `--no-verify` and by
repo-local `core.hooksPath`.

Per repo: **Settings → Rules → Rulesets → New ruleset → New branch
ruleset.**

| Field | Value |
|---|---|
| Name | `protected-branches` |
| Enforcement | Active |
| Bypass list | **empty**. The agent's tokens are yours, so if you are a bypass actor, so is the agent. For an emergency, edit the ruleset in the browser |
| Target branches | the default branch, plus any release branches (`Include by pattern`: `release/*` if used) |

Rules to tick:

- Restrict deletions
- Block force pushes
- Require a pull request before merging, with required approvals: 1,
  dismiss stale approvals on push, and **require approval of the most
  recent reviewable push**. The agent pushes as you, so this makes
  someone other than you approve what it pushed last.
- Require status checks to pass. Pick the CI jobs that already run,
  and set each one's source to **GitHub Actions**, so nothing else can
  report them.
- Require linear history, if the team rebases (skip otherwise)

Add a **tag ruleset** too. Contents write includes creating and moving
tags, so without one the agent can cut a release in any repo that
builds from tag pushes. Target `v*`, or your release tag pattern. Tick
Restrict creations, Restrict updates and Restrict deletions. Leave the
bypass list **empty**, for the same reason as branches. Never add a
team or role you belong to.

To cut a release, do one of these:

- Switch the tag ruleset to **Evaluate** in the browser, push the tag,
  then switch it back to **Active**.
- Push tags from a workflow you start in the browser
  (`workflow_dispatch`). Bypass actors can be roles, teams, GitHub Apps
  or Dependabot. `GITHUB_TOKEN` and deploy keys cannot be one. So the
  workflow must push the tag with a GitHub App's token, and that App is
  the only bypass actor.

Contents write also edits releases and their assets. Turn on immutable
releases in the repo's Settings, so a published release cannot change.

On a repo only you work on, a required approval would block you, since
the agent's PRs are yours. There, keep deletion, force-push and tag
rules, and skip the pull request rule.

Org-level alternative: ExampleOrg → Settings → Repository → Rulesets
applies one ruleset across all repos. On private repos this needs a
paid GitHub plan.

## Checks

After [step 02](02-agent-routing.md) has stored the tokens:

```zsh
./install.sh --check
./check-github.sh --repo ExampleOrg/repo
./check-github.sh --solo --repo alice/dotfiles
```

`install.sh --check` checks each stored token: that it is a
fine-grained PAT, that GitHub accepts it, how long until it expires,
and that an admin-only call is refused. `check-github.sh` checks each
`--repo`'s default branch rules and tag rules against
[Rulesets](#rulesets). Repeat `--repo` for each repo you protect. `--solo` skips the pull
request checks on every repo in that call, so run the repos only you
work on in a separate call.
Both change nothing, print no token, and exit non-zero on a problem.

`check-github.sh` cannot see bypass lists with these tokens. Check them
in the browser.

## Rollback

- Rulesets: delete them, or set them to **Evaluate** (logs, no
  enforcement).
- Tokens: Settings → Developer settings → Personal access tokens →
  Fine-grained tokens → revoke each agent token.
- Your own `gh`: `gh auth login` in a browser restores an OAuth login.
