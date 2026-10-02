#!/usr/bin/env bash
#
# Install gowork from this checkout by symlinking it onto your PATH — the
# alternative to `brew install raocow/tap/gowork`.
#
#   ./install.sh              # link into ~/.local/bin (default)
#   ./install.sh ~/bin        # or a directory of your choice
#
# Symlinks (not copies), so `git pull` in this checkout updates the installed
# commands instantly. Links every command: gowork and gw, plus the gp, gp-*
# and rigor names they grew out of.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target="${1:-$HOME/.local/bin}"

mkdir -p "$target"
for f in "$here"/bin/*; do
  name="$(basename "$f")"
  ln -sfn "$f" "$target/$name"
done
echo "linked  $(cd "$here/bin" && ls | tr '\n' ' ')→  $target/"

# Man pages: <target>/../share/man/man1, which `man` derives from a bin dir on
# PATH (~/.local/bin → ~/.local/share/man).
mandir="$(dirname "$target")/share/man/man1"
mkdir -p "$mandir"
for m in "$here"/man/*.1; do ln -sf "$m" "$mandir/$(basename "$m")"; done
echo "linked  man pages  →  $mandir/"

# zsh completion: plain autoloadable functions, so they work once the
# directory is on $fpath.
fndir="$(dirname "$target")/share/zsh/site-functions"
mkdir -p "$fndir"
for c in "$here"/share/zsh/site-functions/*; do ln -sf "$c" "$fndir/$(basename "$c")"; done
echo "linked  completions  →  $fndir/"

case ":$PATH:" in
  *":$target:"*) ;;
  *) echo; echo "⚠  $target is not on your PATH. Add to ~/.zshrc:  export PATH=\"$target:\$PATH\"" ;;
esac
case " ${FPATH:-} " in
  *"$fndir"*) ;;
  *) echo "   For Tab-completion, add to ~/.zshrc before compinit:  fpath=(\"$fndir\" \$fpath)" ;;
esac

if ! command -v gh >/dev/null 2>&1; then
  echo
  echo "gh (GitHub CLI) not found — needed for gw pr and accounts: https://cli.github.com"
fi

echo
echo "Done. Try: gw help"
echo "Coming from rigor or gitplus? Run: gw migrate"
