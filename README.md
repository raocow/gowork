# rigor

Opt-in shell environment helpers for a fresh Mac. Small zsh features you enable
à la carte — no dotfile spelunking, just `brew install` and one command per
feature you want.

Basically, I don't like typing `3` after `python` or `pip`, and I especially don't
like typing `source .venv/bin/activate`. Let's skip that step.

## Install

```bash
brew tap raocow/tap      # once
brew install rigor
```

Then enable the features you want (this writes a line to your `~/.zshrc` — an
extra step by design, since you may not want auto-venv in every repo):

```bash
rigor enable autovenv        # per-repo .venv auto-activation
rigor enable pyf             # bare python/pip -> python3/pip3
rigor enable                 # everything
exec zsh                     # apply to the current shell
```

`rigor status` shows what's enabled; `rigor disable <feature>` turns one off;
`rigor doctor` shows the resolved python/pip/venv. (`install`/`uninstall` still
work as aliases for `enable`/`disable`.)

Two commands are not zsh features and touch nothing in your rc file:
`rigor push` (agent notifications on your phone) and `rigor sleep`.

<details>
<summary>Manual / advanced</summary>

`rigor enable` just appends a `source` line. To wire it up yourself instead:

```sh
eval "$(rigor init autovenv)"                      # in ~/.zshrc
source "$(brew --prefix)/share/rigor/rigor.zsh"    # or source directly (all features)
```
</details>

## Features

| Feature | What it does |
|---|---|
| `autovenv` | On every `cd`, activates the nearest `.venv` found walking up from the current dir, and deactivates on leaving. Opt-in by presence of a `.venv`, so it only fires in repos where you created one. The current directory wins: leaving every `.venv` scope deactivates whatever is active — including a venv auto-activated by your editor. **On `enable`, it offers to turn off VSCode/Cursor's own terminal venv auto-activation** (`python.terminal.activateEnvironment`, user-level) so autovenv is the sole manager and no venv leaks into dirs that have none; `disable` offers to undo it. Edits are backed up (`.rigor-bak`). |
| `pyf` | Symlinks `python`→`python3` and `pip`→`pip3` in a managed shim dir appended to `PATH`. Real interpreters and active virtualenvs always take precedence. (Formerly `py-fallback`, still accepted as an alias.) |
| `envup` | Adds an `envup` command that exports a `.env` into the current shell — `envup` loads `./.env`, `envup path/to/file` a specific one. Shorthand for `set -a; source <file>; set +a`. (A sourced function, not a `rigor` subcommand — a subprocess can't export back into your shell. Named `envup`, not `dotenv`, to avoid shadowing the python-dotenv CLI.) |

## Accounts moved to gitplus

Per-directory git/ssh/GitHub identities used to live here as `devrig account`.
They are now `gp account`, part of [gitplus](https://github.com/raocow/gitplus).

They moved because every `gp-*` command needs to resolve the bound account
before calling `gh`, which made this package a hard runtime dependency of the
git tooling and forced the two to be released together. The rest of rigor has
nothing to do with git, so only the git-shaped parts went — `ghswitch` with them.

**Nothing to redo.** `gp account` reads the config this wrote, so existing
accounts and bindings keep working untouched.

## Push

Notify your phone when a Claude Code or Codex turn ends, so you stop
babysitting a terminal that is going to take four minutes.

```bash
rigor push setup             # wire this machine, print the topic to subscribe to
rigor push test              # send one and confirm it arrived
rigor push status            # what's wired, and where
rigor push off                # unwire, restoring whatever was there before
```

Install the [ntfy](https://ntfy.sh) app on your phone and subscribe to the topic
`setup` prints. On your other machines, join the same topic so one subscription
covers all of them:

```bash
rigor push setup --topic <the-topic> --device work-mini
```

Every notification is titled with the project, the agent, and the machine
(`myrepo · Claude @ work-mini`), in that order. A phone truncates a title to
about one line, so the project comes first, where it survives the cut, and the
machine last. If you only run one machine the suffix is pure overhead — drop it
and get the width back:

```bash
rigor push setup --device ''      # titles become: myrepo · Claude
```

Claude Code notifies when a turn ends **and** whenever it is blocked waiting on
you; Codex notifies when a turn ends. Turns shorter than 60 seconds stay quiet,
on the theory that you had not walked away yet (`RIGOR_PUSH_MIN_SECONDS` in
`~/.config/rigor/push.env`).

**A turn that ends in a question always notifies, however fast it was.** The
quiet-under threshold exists to skip turns you never walked away from, but a
question means the agent is stopped and waiting on you — as true after four
seconds as after four minutes, and the one notification you least want dropped.
Questions arrive at high priority with a `question` tag.

Codex turns that answer with a JSON document rather than a sentence are not
forwarded. The ChatGPT desktop app runs background turns of its own — an ambient
pass over each project root that returns a suggestions document — and Codex
fires its `notify` hook for those exactly as it does for yours, which otherwise
put `{"suggestions":[]}` on your phone.

**The topic name is the only thing protecting the feed on public ntfy.sh.** It
lives in `~/.config/rigor/push.env`, mode 600, and `rigor push status` masks
it unless you pass `--show`. Point `--server` at your own ntfy if you would
rather not use the public one.

`setup` edits Claude Code's `~/.claude/settings.json` and Codex's
`~/.codex/config.toml`, backing each up first (`.rigor-bak`). Codex allows one
`notify` program, and on a Mac with the ChatGPT app installed its own desktop
notifier already holds that slot — so rigor parks that command and replays it
before pushing, leaving desktop notifications working. `rigor push off` hands
the slot back. Both are safe to re-run: they replace their own entries instead
of stacking new ones.

Needs `curl` and `perl` (both already on macOS). Deliberately not `jq`, so the
package stays dependency-free for everyone who does not use this feature.

## Identity

Make `gh` and `aws` use the right account for whatever directory they run in —
in agents too, not just your own terminal.

```bash
rigor identity setup                     # install the shims, put them on PATH
rigor identity bind client-dev ~/work/client    # AWS profile for that tree
gp account bind work ~/work/client       # GitHub account (gitplus)
rigor identity status                    # what's wired, and what applies here
rigor identity off                       # unwire; bindings are kept
```

`gh`'s active account and AWS's `[default]` profile are each one machine-wide
setting. A shell hook that switches them on `cd` (gitplus' `ghswitch` does this
for `gh`) only runs in interactive shells, and Claude Code, Codex, git's
credential helper and scripts never get one — so they talk to GitHub or AWS as
whoever was last active, and an agent ends up telling you to log in as somebody
else, or worse, runs `gh auth switch` and changes it for every other session too.

`setup` puts `gh` and `aws` shims first on `PATH`, so the lookup happens on every
call, in every process:

- **gh** takes the account from your `gp account` bindings and passes it to the
  real `gh` as `GH_TOKEN` for that one call. gh's global setting is never
  written. Without gitplus installed it is a plain passthrough.
- **aws** takes the profile from `~/.config/rigor/aws-profiles` — one
  `<dir-glob> <profile>` per line, first match wins; `bind` keeps specific
  directories above their parents. Unbound directories fall through to
  `[default]` as before.
- An explicit `GH_TOKEN`, `AWS_PROFILE` or `AWS_ACCESS_KEY_ID` always wins, and
  `RIGOR_IDENTITY_OFF=1` turns both shims into passthroughs for one command.

`setup` writes one line each to `~/.zshenv` (the only file non-interactive
`zsh -c` reads, which is what agents run) and `~/.zprofile` (macOS's
`path_helper` reorders `PATH` in login shells after `.zshenv`), and points any
`gh auth git-credential` helper in your global git config at the shim so HTTPS
pushes authenticate as the right account. It also adds `gh *`, `aws *` and git's
network commands (`push`, `pull`, `fetch`, `clone`, `ls-remote`) to
`sandbox.excludedCommands` in `~/.claude/settings.json`: inside Claude Code's
Bash sandbox gh can't read its tokens from the keychain or reach GitHub, so it
reports every login "invalid" and agents ask you to log in again. Excluded
commands still go through Claude Code's normal permission prompts. Files are
backed up (`.rigor-bak`), a settings file that isn't valid JSON is refused rather
than rewritten, and `off` restores the git helpers and removes only the
exclusions `setup` added. Restart agent apps afterwards so they pick up
the new `PATH`.

With gitplus installed, `setup` finishes by running `gp account check --fix`,
which asks GitHub whether each account's SSH key still works and fixes any
that don't (one browser approval per account, the first time). Without a
terminal it prints that command instead.

The shims do not log you in: an expired AWS SSO session still needs
`aws sso login`. Code that calls AWS through an SDK rather than the `aws` CLI
does not go through the shim either — set `AWS_PROFILE` in that project's
environment.

## Sleep

```bash
rigor sleep off       # sudo pmset -a disablesleep 1 — keep the Mac awake
rigor sleep on        # sudo pmset -a disablesleep 0 — put it back
rigor sleep status    # what's it set to right now
```

A memorable name for a command that's easy to forget the flag/argument order
of. `off`/`on` needs `sudo` (same as the raw `pmset` call); `status` doesn't.

## Disable / uninstall

```bash
rigor disable autovenv    # turn off one feature
rigor disable all         # remove all rigor lines from ~/.zshrc
brew uninstall rigor
```

A feature (or `all`) is required — a bare `rigor disable` won't wipe everything
by accident. `rigor disable pyf` also removes its shim dir
(`~/.local/share/rigor/shims`, override with `RIGOR_SHIM_DIR`), leaving nothing behind.

## License

MIT
