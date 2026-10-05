# gowork

One command, `gw` (or `gowork`), for three jobs that kept needing each other:

- **git and GitHub pull requests**: list, check out, merge and clean up PRs
  and branches faster than doing it by hand.
- **identity**: which GitHub account, SSH key and AWS profile a directory
  uses, so terminals, scripts and coding agents all act as the right account.
- **dev-shell setup**: per-repo venvs, python/pip fallbacks, `.env` loading,
  phone notifications when an agent turn ends, keeping the Mac awake.

It is the merge of [gitplus](https://github.com/raocow/gitplus) (`gp`) and
[rigor](https://github.com/raocow/rigor). Both old command names keep working.

## Install

```bash
brew tap raocow/tap
brew install gowork
gw help
```

From a checkout instead: `./install.sh` links everything into `~/.local/bin`.

**Coming from rigor or gitplus?** Run `gw migrate` once. It points everything
they wrote into your config at gowork: rc-file `source` lines and completion
path, Claude Code hooks, Codex's notify program, the identity shims. It also
drops the retired `ghswitch` hook. Every edited file is backed up
(`.gowork-bak`); `gw migrate --dry-run` shows the changes first. Then
`brew uninstall rigor gitplus`. Your config stays where it is
(`~/.config/rigor`, the `# rigor:` rc markers, `RIGOR_*` variables), because
those are gowork's names too.

## Commands

Anything `gw` doesn't know goes to git, so `gw pull` is `git pull` and
`gw log --oneline` is `git log --oneline`. gowork's own commands avoid git's
names for that reason.

| Command | What it does | Was |
|---|---|---|
| `gw pr`, `gw pl`, `gw pm` | pull requests: list, check out, merge, close, unmerge | `gp pr`, `gp pl`, `gp pm` |
| `gw new`, `switch`, `sync`, `done`, `sweep`, `wsweep`, `haspr`, `release` | branch and worktree workflow | `gp …` |
| `gw fork sync\|status\|pr` | forks: catch the base up with upstream, compare with it, open a PR to it | — |
| `gw account setup\|status\|off` | gh/aws shims, git routing, Claude sandbox wiring | `rigor identity …` |
| `gw account add\|bind\|unbind\|list\|key` | per-directory GitHub accounts | `gp account …` |
| `gw account register\|check\|sweep` | SSH keys on GitHub; dead bindings | `gp account …` |
| `gw aws bind\|unbind` | per-directory AWS profiles | `rigor identity bind\|unbind` |
| `gw shell enable\|disable\|status\|doctor\|init` | autovenv, pyf, envup | `rigor enable` … |
| `gw notify setup\|status\|test\|off` | phone notifications for agent turns | `rigor push …` |
| `gw sleep on\|off\|status` | keep the Mac awake | `rigor sleep …` |
| `gw browser setup\|sync\|status\|off` | open GitHub links in the Chrome profile signed in to the right account | — |
| `gw migrate` | move a rigor/gitplus setup over | — |

The git commands are documented in depth in [docs/gp.md](docs/gp.md), and the
shell features and notifications in [docs/rigor.md](docs/rigor.md). Both were
written before the merge, under the old names.

## Identity

`gh`'s active account and AWS's `[default]` profile are each one machine-wide
setting. Anything that switches them per directory with a shell hook only works
in interactive shells. Agents (Claude Code, Codex), git's credential helper and
scripts never run that hook, so they act as whoever was last active.

```bash
gw account setup                              # once per machine
gw account add work --email me@work.com --gh-user me-work --dir ~/work
gw account bind personal ~/code               # GitHub account for a tree
gw aws bind work-dev ~/work                   # AWS profile for a tree
gw account status                             # what applies here
```

`setup` puts `gh` and `aws` shims first on `PATH` (from `~/.zshenv` and
`~/.zprofile`), so every process, not just your terminal, resolves the
directory's account on every call. A worktree follows its main repository
wherever it lives. Without touching gh's global setting, the gh shim passes
the bound account's token to the real gh for that one call. `setup` also:

- routes git's `gh auth git-credential` helper through the shim, so HTTPS
  pushes use the right account;
- adds `gh *`, `aws *` and git's network commands to Claude Code's
  `sandbox.excludedCommands`. Inside its Bash sandbox, gh can't read its
  tokens from the keychain, so it reports every login "invalid" and agents ask
  you to log in again;
- runs `gw account check --fix`, which asks GitHub whether each account's SSH
  key works and registers any that don't. That takes one browser approval per
  account, the first time. After that, repos bound to the account push and
  pull over its SSH alias, HTTPS remotes included, with no remote edited.

`gw account sweep` deals with bindings whose directory is gone. It traces
where each repo went and drops the binding, rebinds it, or asks you.

`gw browser setup` does the same for links you click. A link opened from a
terminal goes to macOS's default browser, in whichever profile was used last.
gowork installs [Finicky](https://github.com/johnste/finicky) (MIT), a small
browser router, asks which Chrome profile each account is signed into, and
writes its rules from your accounts: each account's login, its GitHub orgs,
and the owners of its bound repos. Run `gw browser sync` after binding new
repos. gowork's own browser steps (device approval, SSO authorization) open
straight in the account's profile.

Links that aren't GitHub repos follow your own rules, each sent to an
account's browser:

```bash
gw browser add work '*.sharepoint.com'          # a domain and its subdomains
gw browser add work jira.example.com/browse     # a host with a path prefix
gw browser add work --app Slack                 # anything clicked in that app
gw browser rules                                # list; gw browser remove … to drop
```

The first match wins, in this order: your URL rules, GitHub owners, your app
rules, then the default.

An explicit `GH_TOKEN`, `AWS_PROFILE` or `AWS_ACCESS_KEY_ID` always wins.
`RIGOR_IDENTITY_OFF=1` turns both shims into passthroughs for one command.

## License

MIT
