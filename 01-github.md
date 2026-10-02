# Step 01: GitHub side

| | |
|---|---|
| Required | yes (the App); rulesets recommended; restricting your own `gh` optional |
| Depends on | none |
| If you skip it: security | Without rulesets, protected branches rely only on the agent behaving. Your own `gh` login, OAuth or PAT, sits in the keychain, which the agent can probably reach (see [04, Known limits](04-claude-code-sandbox.md#known-limits)). Leave it broad and the agent can likely borrow it. |
| If you skip it: operations | Skipping rulesets or the `gh` restriction changes nothing in daily use. |
| If you skip it: change elsewhere | nothing |

Browser work, plus two commands. Installing the App on an org needs an
org owner.

## Optional: restrict your own `gh` login

This section is about **your** terminal `gh`, not the agent's. The
agent never uses a PAT; it gets App tokens in [step 02](02-agent-identity.md).

Your own `gh` login lives in the macOS keychain whatever kind it is.
[Step 04](04-claude-code-sandbox.md#known-limits) shows the agent can probably read the keychain. So whatever
that login can do, the agent can likely do too. Check what you have:

```zsh
gh auth status
```

- **`Token: gho_…` with scopes such as `repo`, `delete_repo`,
  `admin:org`:** a browser OAuth login. It can create and delete repos.
  Replace it as below if you want the agent unable to borrow that.
- **`Token: github_pat_…`:** already a fine-grained PAT. Check its
  permissions on GitHub; if Administration is No access, skip this
  section.
- **Keeping the OAuth login** is a valid choice. You accept that the
  agent could reach it through the keychain.

To replace it, create a fine-grained PAT that cannot administer
anything. Admin work then goes in the browser.

GitHub → **Settings → Developer settings → Personal access tokens →
Fine-grained tokens → Generate new token**. Pick the resource owner you
use `gh` with most. A fine-grained PAT covers one owner.

| Permission | Level |
|---|---|
| Contents | Read and write |
| Pull requests | Read and write |
| Issues | Read and write |
| Actions | Read |
| Metadata | Read |
| Administration | No access |

Copy the token, then log in from the clipboard, so it never appears in
history:

```zsh
pbpaste | gh auth login --with-token
pbcopy < /dev/null
gh auth status
```

## Register the App

GitHub → your avatar → **Settings → Developer settings → GitHub Apps →
New GitHub App**.

| Field | Value |
|---|---|
| Name | `alice-agent`. Names are global on GitHub; add a suffix if taken. Put your handle in the name. The App acts as `alice-agent[bot]` in audit logs and on PRs, so each org member's agent is attributable to its operator |
| Homepage URL | any, e.g. your GitHub profile |
| Webhook | **untick Active**. No webhook URL needed |
| Where can this GitHub App be installed? | **Any account**. Required so an App owned by `alice` can install on `ExampleOrg` |

Repository permissions (everything else stays *No access*):

| Permission | Level | Why |
|---|---|---|
| Contents | Read and write | clone, fetch, push branches |
| Pull requests | Read and write | open, update, comment on PRs |
| Issues | Read and write | issues, labels |
| Commit statuses | Read and write | status checks on pushes |
| Actions | Read | inspect runs and logs |
| Metadata | Read | mandatory, auto-selected |
| Checks | Read | read check runs |

Deliberately absent: Administration, Workflows, Secrets, Variables,
Environments, Deployments, Webhooks, Pages, Security events. Without
**Workflows** the App cannot push a commit that touches
`.github/workflows/*`. Workflow changes go through you.

Organization permissions: none. Account permissions: none.

Click **Create GitHub App**. Note the **App ID** on the next page.

## Private key

Same page → **Private keys → Generate a private key**. GitHub downloads
`alice-agent.<date>.private-key.pem` and keeps only the public half.

```zsh
mkdir -p ~/.config/agent-git && chmod 700 ~/.config/agent-git
mv ~/Downloads/alice-agent.*.private-key.pem ~/.config/agent-git/app.pem
chmod 600 ~/.config/agent-git/app.pem
```

This key is the agent's credential. The agent runs as your user and can
read it by design. It grants only what the App has. Rotate by
generating a new key and deleting the old one on the same page.

## Install on each owner

App settings → **Install App** → pick an account → **Only select
repositories** → choose the repos the agent works on → Install.

Repeat for every owner: `ExampleOrg`, `alice`, others. Test one push on
your personal account before relying on it.

Installing on an org needs an **org owner**. If you own ExampleOrg, you
approve it yourself, once, and choose the repos. If not, the install
page submits a request. An owner approves it under the org's Settings →
GitHub Apps. That is one approval per org, not per repo. Adding a repo
later changes the existing installation. An owner or a repo admin can
do it.

## Installation IDs

Each owner gets its own installation ID. You do not need to record
them: the installer in [step 02](02-agent-identity.md#run-the-installer)
asks the App for its installations, writes one helper line per owner,
and tests a token for each.

## Rulesets

Server-side and identity-agnostic. This is the only guard on protected
branches; local hooks are bypassed by `--no-verify` and by repo-local
`core.hooksPath`.

Per repo: **Settings → Rules → Rulesets → New ruleset → New branch
ruleset.**

| Field | Value |
|---|---|
| Name | `protected-branches` |
| Enforcement | Active |
| Bypass list | **empty**, or the `alice-agent` App only if a specific automation needs it. Do **not** add yourself or `Repository admin` while the agent can still act as you ([steps 03](03-ssh-key-to-password-manager.md) and [04](04-claude-code-sandbox.md) not yet done) |
| Target branches | add `stage`, `main`, and any release branches (`Include by pattern`: `release/*` if used) |

Rules to tick:

- Restrict deletions
- Block force pushes
- Require a pull request before merging (required approvals: 1; dismiss
  stale approvals on push)
- Require status checks to pass (pick the CI jobs that already run)
- Require linear history, if the team rebases (skip otherwise)

If you release by tag push, add a tag ruleset on `v*` with Restrict
creations, bypassable only by a team of humans.

Org-level alternative: ExampleOrg → Settings → Repository → Rulesets
applies one ruleset across all repos. Prefer that once it works on one
repo.

After [step 04](04-claude-code-sandbox.md#checks) passes its checks, you may add yourself as a bypass actor
for emergencies. Until then, you and the agent are the same actor to
GitHub.

## Checks

After [step 02](02-agent-identity.md):

- ExampleOrg → Settings → Installed GitHub Apps → alice-agent: selected
  repos only, permissions as in [Register the App](#register-the-app).
- A recent agent PR shows author `alice-agent[bot]`. The Approve button
  is available to you.
- The audit log (org → Settings → Audit log) shows `alice` and the App
  as separate actors.

## Rollback

- Rulesets: delete them, or set them to **Evaluate** (logs, no
  enforcement).
- App: Settings → Developer settings → GitHub Apps → alice-agent →
  Advanced → Delete. Or uninstall per owner under that owner's Installed
  GitHub Apps.
- Your own `gh`: `gh auth login` in a browser restores an OAuth login.
