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
