#!/usr/bin/env bash
#
# Install the git-* commands by symlinking them onto your PATH.
#
#   ./install.sh              # link into ~/.local/bin (default)
#   ./install.sh ~/bin        # or a directory of your choice
#
# Symlinks (not copies), so `git pull` in this repo updates the installed
# commands instantly. Git discovers any `git-<name>` on PATH as `git <name>`.
#
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target="${1:-$HOME/.local/bin}"

mkdir -p "$target"
for f in "$here"/bin/git-*; do
  name="$(basename "$f")"
  chmod +x "$f"
  ln -sf "$f" "$target/$name"
  echo "linked  $name  →  $target/$name"
done

# Man pages: symlink into <target>/../share/man/man1, which `man` derives from a
# bin dir on PATH (e.g. ~/.local/bin → ~/.local/share/man). That's what lets
# `git <cmd> --help` open the page — git turns `--help` into `man git-<cmd>`.
mandir="$(dirname "$target")/share/man/man1"
mkdir -p "$mandir"
for m in "$here"/man/git-*.1; do
  name="$(basename "$m")"
  ln -sf "$m" "$mandir/$name"
  echo "linked  $name  →  $mandir/$name"
done

# zsh completion: symlink into <target>/../share/zsh/site-functions, the
# standard Homebrew/zsh convention — these are plain autoloadable functions
# (one per file, named to match), so they just work once that directory is on
# $fpath. No `source` line, no compinit-ordering requirement, unlike a
# hand-rolled completion script.
fndir="$(dirname "$target")/share/zsh/site-functions"
mkdir -p "$fndir"
if [ -d "$here/share/zsh/site-functions" ]; then
  for c in "$here"/share/zsh/site-functions/*; do
    name="$(basename "$c")"
    ln -sf "$c" "$fndir/$name"
  done
  echo "linked  $(basename "$fndir")/*  →  $fndir/"
fi

case ":$PATH:" in
  *":$target:"*) ;;
  *)
    echo
    echo "⚠  $target is not on your PATH. Add this to your ~/.zshrc (or ~/.bashrc):"
    echo "       export PATH=\"$target:\$PATH\""
    ;;
esac

# `git pr` needs the GitHub CLI (gh). Best-effort install if it's missing —
# never fatal, so `sweep`/`sync` still install fine without it.
if command -v gh >/dev/null 2>&1; then
  echo
  echo "gh (GitHub CLI) found — 'git pr' is good to go."
else
  echo
  echo "gh (GitHub CLI) not found — needed only for 'git pr'."
  if command -v brew >/dev/null 2>&1; then
    echo "Installing via Homebrew…"
    brew install gh || echo "⚠  'brew install gh' failed — install manually: https://cli.github.com"
  elif command -v apt-get >/dev/null 2>&1; then
    echo "   Debian/Ubuntu:  sudo apt-get install gh   (see https://github.com/cli/cli#installation)"
  elif command -v dnf >/dev/null 2>&1; then
    echo "   Fedora:         sudo dnf install gh"
  else
    echo "   Install it from https://cli.github.com"
  fi
  command -v gh >/dev/null 2>&1 && echo "   Now run 'gh auth login' once to authenticate."
fi

# Best-effort check, in a LOGIN shell (which is what Terminal.app runs, and
# what sources ~/.zprofile → `brew shellenv`): does zsh's OWN _git win? These
# commands are `git <subcommand>`, so completing their arguments goes through
# whatever _git is first on fpath. zsh's own _git dispatches to _git-<cmd>
# user functions (which is how ours work); the _git that Homebrew's git
# formula ships does NOT — it sends unknown subcommands' arguments to plain
# file completion. `brew shellenv` prepends Homebrew's site-functions dir, so
# by default brew's _git wins and `git pr list <TAB>` / `git new <TAB>` just
# list files. The snippet below puts zsh's own function dirs back in front
# (so its _git wins) while keeping the completion dir on fpath.
git_ok=0
if command -v zsh >/dev/null 2>&1; then
  # Force-load _git and read where it came from (functions_source is reliable;
  # `whence -v` omits the path for a not-yet-loaded autoload function). A
  # system dir means zsh's own _git — the one that dispatches to _git-<cmd>.
  case "$(zsh -lic 'autoload +X _git 2>/dev/null; print -r -- ${functions_source[_git]}' 2>/dev/null)" in
    /usr/share/zsh/*) git_ok=1 ;;
  esac
fi

echo
if [ "$git_ok" = 1 ]; then
  echo "zsh completion is set up — Tab-completion (incl. 'git new' for short-name"
  echo "cycling, and 'git pr list <TAB>') works with no further action."
else
  echo "For Tab-completion of these commands — including 'git new <TAB>' for"
  echo "cycling through short names — add this to ~/.zshrc. It ensures zsh's OWN"
  echo "git completion wins: Homebrew's git formula ships a different _git that"
  echo "ignores git-<subcommand> completions and, because 'brew shellenv' puts"
  echo "it first on fpath, would otherwise send 'git pr list'/'git new' argument"
  echo "completion to plain file listing. Putting the system function dirs first"
  echo "fixes that while keeping the completion dir (below) on fpath:"
  echo "       typeset -U fpath"
  echo "       fpath=(/usr/share/zsh/\${ZSH_VERSION}/functions /usr/share/zsh/site-functions \"$fndir\" \$fpath)"
  echo "       autoload -Uz compinit && compinit"
fi
echo
echo "Done. Try:  git sweep -h   (or full man page: git sweep --help)"
