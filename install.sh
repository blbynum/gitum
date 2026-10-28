#!/usr/bin/env bash
# install.sh - link gitum into ~/.local/bin, put that directory on the PATH, run gitum init.
# Safe to re-run. Re-run it after you move this repository.

set -u

repo=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || exit 1
bin_dir="$HOME/.local/bin"
link="$bin_dir/gitum"
marker='# gitum: put ~/.local/bin on the PATH'
# shellcheck disable=SC2016
path_line='case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac'
rc=""

[ -f "$repo/gitum" ] || { printf 'install.sh: %s/gitum not found\n' "$repo" >&2; exit 1; }
mkdir -p "$bin_dir" || exit 1
if [ -e "$link" ] && [ ! -L "$link" ]; then
  printf 'install.sh: %s exists and is not a symlink. Move it away first.\n' "$link" >&2
  exit 1
fi
ln -sf "$repo/gitum" "$link" || exit 1
printf 'Linked %s -> %s\n' "$link" "$repo/gitum"

case ":$PATH:" in
  *":$bin_dir:"*)
    printf '%s is on the PATH.\n' "$bin_dir"
    ;;
  *)
    case ${SHELL:-} in
      */zsh) rc="$HOME/.zshrc" ;;
      */bash) rc="$HOME/.bashrc" ;;
    esac
    if [ -n "$rc" ]; then
      if [ -f "$rc" ] && grep -qF -- "$marker" "$rc"; then
        printf '%s already puts %s on the PATH. Open a new shell to pick it up.\n' "$rc" "$bin_dir"
      else
        printf '\n%s\n%s\n' "$marker" "$path_line" >> "$rc" || exit 1
        printf 'Added %s to the PATH in %s. Open a new shell to pick it up.\n' "$bin_dir" "$rc"
      fi
    else
      printf '%s is not on the PATH. Add this line to the startup file of your shell:\n  %s\n' "$bin_dir" "$path_line"
    fi
    ;;
esac

printf '\n'
exec "$link" init
