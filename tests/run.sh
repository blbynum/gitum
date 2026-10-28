#!/usr/bin/env bash
# tests/run.sh - run install.sh and every gitum command against a temporary HOME.
#
# Plain bash, no network. ssh, ssh-keygen and pbcopy are stubs on the PATH.
# Throwaway keys are generated with an empty passphrase inside the temporary HOME.
# Set GITUM_TEST_BASH to a bash binary to run gitum under that bash (CI uses /bin/bash on macOS).

# shellcheck disable=SC2088
set -u

here=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || exit 1
repo=$(dirname "$here")
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gitum-test.XXXXXX") || exit 1
tmp=$(cd -P "$tmp" && pwd -P)
trap 'rm -rf "${tmp:?}"' EXIT

passes=0
fails=0
pass() { passes=$((passes + 1)); }
fail() { fails=$((fails + 1)); printf 'FAIL: %s\n' "$1" >&2; }
section() { printf '== %s\n' "$*"; }

# ok DESC COMMAND...: pass when COMMAND succeeds.
ok() { local desc=$1; shift; if "$@"; then pass; else fail "$desc"; fi; }
# eq DESC GOT WANT
eq() { if [ "$2" = "$3" ]; then pass; else fail "$1: got [$2], want [$3]"; fi; }
# show TEXT: print TEXT indented on stderr.
show() {
  local line=""
  while IFS= read -r line || [ -n "$line" ]; do printf '    %s\n' "$line" >&2; done <<< "$1"
}
# contains DESC HAYSTACK NEEDLE
contains() {
  case $2 in
    *"$3"*) pass ;;
    *) fail "$1: expected [$3] in:"; show "$2" ;;
  esac
}
# lacks DESC HAYSTACK NEEDLE
lacks() {
  case $2 in
    *"$3"*) fail "$1: did not expect [$3] in:"; show "$2" ;;
    *) pass ;;
  esac
}
# count_backups: the number of ~/.gitconfig backups gitum made.
count_backups() {
  local n=0 f=""
  for f in "$HOME"/.gitconfig.gitum-backup-*; do
    [ -e "$f" ] && n=$((n + 1))
  done
  printf '%s\n' "$n"
}

# ---------------------------------------------------------------- isolated environment

export HOME="$tmp/home"
mkdir -p "$HOME"
unset XDG_CONFIG_HOME GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_DIR GIT_WORK_TREE
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL EMAIL
export GIT_CONFIG_NOSYSTEM=1
export SHELL=/bin/bash
export STUB_SSH_ARGS="$tmp/ssh.args"
export STUB_SSH_MODE=ok

real_keygen=$(command -v ssh-keygen) || { printf 'ssh-keygen is required\n' >&2; exit 1; }
stub="$tmp/stub"
mkdir -p "$stub"
cat > "$stub/ssh-keygen" <<EOF
#!/usr/bin/env bash
# test stub: record the arguments gitum passes, then generate with an empty passphrase
printf '%s\n' "\$@" > "$tmp/keygen.args"
exec "$real_keygen" "\$@" -N ''
EOF
cat > "$stub/pbcopy" <<EOF
#!/usr/bin/env bash
cat > "$tmp/clipboard"
EOF
cat > "$stub/ssh" <<'EOF'
#!/usr/bin/env bash
# test stub: answer like a git host, chosen by STUB_SSH_MODE
printf '%s\n' "$@" > "$STUB_SSH_ARGS"
key=""
while [ $# -gt 0 ]; do
  case $1 in
    -i) key=$2; shift 2 ;;
    *) shift ;;
  esac
done
user=${key##*_}
case ${STUB_SSH_MODE:-ok} in
  ok) printf "Hi %s! You've successfully authenticated, but GitHub does not provide shell access.\n" "$user" >&2; exit 1 ;;
  wronguser) printf "Hi someone-else! You've successfully authenticated, but GitHub does not provide shell access.\n" >&2; exit 1 ;;
  azure) printf 'remote: Shell access is not supported.\nshell request failed on channel 0\n' >&2; exit 255 ;;
  denied) printf 'git@github.com: Permission denied (publickey).\n' >&2; exit 255 ;;
  unreachable) printf 'ssh: Could not resolve hostname github.com: nodename nor servname provided, or not known\n' >&2; exit 255 ;;
  *) exit 255 ;;
esac
EOF
chmod +x "$stub"/*
if [ -n "${GITUM_TEST_BASH:-}" ]; then
  ln -s "$GITUM_TEST_BASH" "$stub/bash"
fi
export PATH="$stub:$PATH"

gitum() { "$HOME/.local/bin/gitum" "$@"; }
mk_repo() {
  mkdir -p "$1" && git -C "$1" -c init.defaultBranch=main init -q &&
    printf 'x\n' > "$1/file" && git -C "$1" add file
}

# ---------------------------------------------------------------- before init

section "before init"
out=$("$repo/gitum" list 2>&1); rc=$?
eq "list before init exits 1" "$rc" 1
contains "list before init points to install.sh" "$out" "install.sh"
out=$("$repo/gitum" add 2>&1); rc=$?
eq "add before init exits 1" "$rc" 1
eq "--version" "$("$repo/gitum" --version 2>&1)" "0.1.0"
out=$("$repo/gitum" 2>&1); rc=$?
eq "no arguments exits 0" "$rc" 0
contains "no arguments prints usage" "$out" "Usage: gitum"
contains "help prints usage" "$("$repo/gitum" help 2>&1)" "Usage: gitum"
out=$("$repo/gitum" bogus 2>&1); rc=$?
eq "unknown command exits 2" "$rc" 2

# ---------------------------------------------------------------- install.sh

section "install.sh"
cat > "$HOME/.gitconfig" <<'EOF'
[user]
	name = Old Name
	email = old@example.com
[core]
	autocrlf = input
[includeIf "gitdir:~/work/"]
	path = ~/.gitconfig-work
[alias]
	st = status
EOF
out=$(printf '~/src\ny\ny\n' | bash "$repo/install.sh" 2>&1); rc=$?
eq "install.sh exits 0" "$rc" 0
ok "symlink created" test -L "$HOME/.local/bin/gitum"
eq "symlink target" "$(readlink "$HOME/.local/bin/gitum")" "$repo/gitum"
ok ".bashrc has the PATH line" grep -qF 'gitum: put ~/.local/bin on the PATH' "$HOME/.bashrc"
root=$(cd -P "$HOME/src" && pwd -P)
eq "config root" "$(cat "$HOME/.config/gitum/config")" "root=$root"
for d in apps contrib my view; do ok "root/$d created" test -d "$root/$d"; done
eq "one backup of ~/.gitconfig" "$(count_backups)" 1
eq "user.name removed" "$(git config -f "$HOME/.gitconfig" --get user.name)" ""
eq "user.email removed" "$(git config -f "$HOME/.gitconfig" --get user.email)" ""
eq "core.autocrlf kept" "$(git config -f "$HOME/.gitconfig" --get core.autocrlf)" "input"
eq "alias kept" "$(git config -f "$HOME/.gitconfig" --get alias.st)" "status"
eq "own includeIf kept" "$(git config -f "$HOME/.gitconfig" --get 'includeIf.gitdir:~/work/.path')" "~/.gitconfig-work"
eq "include appended as the last line" "$(tail -n 1 "$HOME/.gitconfig")" "[include] path = ~/.config/gitum/gitconfig"
contains "existing includeIf printed" "$out" "includeif.gitdir:~/work/.path"
contains "backup announced" "$out" "Backed up"
contains "next step announced" "$out" "gitum add"
gcfg=$(cat "$HOME/.config/gitum/gitconfig")
contains "useConfigOnly" "$gcfg" "useConfigOnly = true"
contains "no-key sshCommand" "$gcfg" "sshCommand = ssh -o PubkeyAuthentication=no -o IdentityAgent=none"
contains "empty credential helper" "$gcfg" "helper ="

section "init and install.sh re-run"
out=$(printf '\n' | gitum init 2>&1); rc=$?
eq "init re-run exits 0" "$rc" 0
contains "init re-run reports the root" "$out" "root:      ~/src"
eq "still one backup" "$(count_backups)" 1
out=$(printf '\n' | bash "$repo/install.sh" 2>&1); rc=$?
eq "install.sh re-run exits 0" "$rc" 0
eq "PATH line not duplicated" "$(grep -cF 'gitum: put ~/.local/bin on the PATH' "$HOME/.bashrc")" 1

# ---------------------------------------------------------------- add

section "add github alice"
out=$(printf '\nAlice Example\nalice@example.com\ny\nn\n' | gitum add github alice 2>&1); rc=$?
eq "add exits 0" "$rc" 0
for d in apps contrib my view; do ok "github/alice/$d" test -d "$root/github/alice/$d"; done
acfg="$HOME/.config/gitum/accounts/github/alice.gitconfig"
ok "account config written" test -f "$acfg"
eq "user.name" "$(git config -f "$acfg" --get user.name)" "Alice Example"
eq "user.email" "$(git config -f "$acfg" --get user.email)" "alice@example.com"
sshcmd=$(git config -f "$acfg" --get core.sshCommand)
contains "sshCommand options" "$sshcmd" "ssh -i ~/.ssh/gitum/github_alice -o IdentitiesOnly=yes -o AddKeysToAgent=yes"
if [ "$(uname -s)" = Darwin ]; then
  contains "UseKeychain on macOS" "$sshcmd" "-o UseKeychain=yes"
else
  lacks "no UseKeychain on Linux" "$sshcmd" "UseKeychain"
fi
eq "insteadOf" "$(git config -f "$acfg" --get 'url.git@github.com:.insteadOf')" "https://github.com/"
eq "gitum.type" "$(git config -f "$acfg" --get gitum.type)" github
eq "gitum.host" "$(git config -f "$acfg" --get gitum.host)" github.com
eq "gitum.dir" "$(git config -f "$acfg" --get gitum.dir)" github
eq "gitum.user" "$(git config -f "$acfg" --get gitum.user)" alice
eq "gitum.key" "$(git config -f "$acfg" --get gitum.key)" "~/.ssh/gitum/github_alice"
gcfg=$(cat "$HOME/.config/gitum/gitconfig")
contains "includeIf rule" "$gcfg" "[includeIf \"gitdir/i:$root/github/alice/\"]"
contains "includeIf path" "$gcfg" "path = ~/.config/gitum/accounts/github/alice.gitconfig"
ok "private key generated" test -f "$HOME/.ssh/gitum/github_alice"
ok "public key generated" test -f "$HOME/.ssh/gitum/github_alice.pub"
args=$(tr '\n' ' ' < "$tmp/keygen.args")
contains "keygen type" "$args" "-t ed25519 "
contains "keygen file" "$args" "-f $HOME/.ssh/gitum/github_alice "
contains "keygen comment" "$args" "-C alice@github (gitum) "
lacks "keygen never passes -N" "$args" "-N"
eq "clipboard holds the public key" "$(cat "$tmp/clipboard")" "$(cat "$HOME/.ssh/gitum/github_alice.pub")"
contains "clipboard announced" "$out" "clipboard with pbcopy"
contains "guide: settings URL" "$out" "https://github.com/settings/keys"
contains "guide: username" "$out" "sign in as alice"
contains "guide: test command" "$out" "gitum test github alice"
contains "guide: clipboard line" "$out" "The public key is on the clipboard."
lacks "guide hides keygen after generation" "$out" "ssh-keygen -t"
lacks "guide hides cat after clipboard copy" "$out" "cat ~/.ssh/gitum/github_alice.pub"
contains "connection test offered" "$out" "Run the connection test now?"

section "add forgejo bob, key declined"
out=$(printf 'forgejo-work\ngit.example.com\nBob Builder\nbob@example.com\nn\n' | gitum add forgejo bob 2>&1); rc=$?
eq "add exits 0" "$rc" 0
bcfg="$HOME/.config/gitum/accounts/forgejo-work/bob.gitconfig"
eq "gitum.host" "$(git config -f "$bcfg" --get gitum.host)" git.example.com
eq "gitum.dir" "$(git config -f "$bcfg" --get gitum.dir)" forgejo-work
eq "insteadOf" "$(git config -f "$bcfg" --get 'url.git@git.example.com:.insteadOf')" "https://git.example.com/"
ok "bob directory tree" test -d "$root/forgejo-work/bob/my"
contains "guide shows keygen" "$out" 'ssh-keygen -t ed25519 -f ~/.ssh/gitum/forgejo-work_bob -C "bob@forgejo-work (gitum)"'
contains "guide shows cat" "$out" "cat ~/.ssh/gitum/forgejo-work_bob.pub"
contains "guide: host settings URL" "$out" "https://git.example.com/user/settings/keys"
contains "guide: test command" "$out" "gitum test forgejo-work bob"
lacks "no connection test without a key" "$out" "Run the connection test now?"
out=$(gitum list 2>&1)
contains "list shows bob" "$out" "forgejo-work/bob"
contains "list marks the missing key" "$out" "(key missing)"
mkdir -p "$HOME/.ssh/gitum"
"$real_keygen" -q -t ed25519 -N '' -f "$HOME/.ssh/gitum/forgejo-work_bob" -C test

section "duplicate accounts"
out=$(printf '\nX\nx@example.com\n' | gitum add github alice 2>&1); rc=$?
eq "duplicate add exits 1" "$rc" 1
contains "duplicate add warns" "$out" "already exists"
out=$(printf '\nX\nx@example.com\n' | gitum add github Alice 2>&1); rc=$?
eq "case clash exits 1" "$rc" 1
out=$(gitum add nope 2>&1); rc=$?
eq "unknown type exits 2" "$rc" 2
out=$(printf '\n1\n' | gitum add 2>&1 </dev/null); rc=$?
eq "add without input aborts with exit 1" "$rc" 1

# ---------------------------------------------------------------- list

section "list"
out=$(gitum list 2>&1); rc=$?
eq "list exits 0" "$rc" 0
contains "list alice" "$out" "github/alice"
contains "list alice identity" "$out" "Alice Example <alice@example.com>"
contains "list alice key" "$out" "~/.ssh/gitum/github_alice"
contains "list bob" "$out" "forgejo-work/bob"
lacks "no missing marker once the key exists" "$out" "(key missing)"
out=$(gitum list github 2>&1)
contains "filtered list has alice" "$out" "github/alice"
lacks "filtered list lacks bob" "$out" "bob"
eq "unknown platform list" "$(gitum list nothing 2>&1)" "No accounts under nothing."
out=$(gitum list a b 2>&1); rc=$?
eq "list with two arguments exits 2" "$rc" 2

# ---------------------------------------------------------------- identity

section "identity follows the directory"
mk_repo "$root/github/alice/my/proj"
eq "name inside the account directory" "$(git -C "$root/github/alice/my/proj" config user.name)" "Alice Example"
ok "commit inside the account directory" git -C "$root/github/alice/my/proj" commit -q -m init
contains "author ident" "$(git -C "$root/github/alice/my/proj" var GIT_AUTHOR_IDENT)" "Alice Example <alice@example.com>"
contains "sshCommand inside" "$(git -C "$root/github/alice/my/proj" config core.sshCommand)" "github_alice"
git -C "$root/github/alice/my/proj" remote add origin https://github.com/alice/proj.git
eq "insteadOf rewrites HTTPS" "$(git -C "$root/github/alice/my/proj" ls-remote --get-url origin)" "git@github.com:alice/proj.git"
mk_repo "$root/github/alice/contrib/deeper/nested"
eq "name at any depth" "$(git -C "$root/github/alice/contrib/deeper/nested" config user.name)" "Alice Example"
mk_repo "$root/my/tool"
eq "no name outside an account directory" "$(git -C "$root/my/tool" config user.name)" ""
out=$(git -C "$root/my/tool" commit -q -m init 2>&1); rc=$?
ok "commit outside fails" test "$rc" -ne 0
contains "commit outside: no identity guessed" "$out" "auto-detection is disabled"
eq "sshCommand outside" "$(git -C "$root/my/tool" config core.sshCommand)" "ssh -o PubkeyAuthentication=no -o IdentityAgent=none"
eq "credential.helper outside is empty" "$(git -C "$root/my/tool" config credential.helper)" ""
ok "credential.helper outside is set" git -C "$root/my/tool" config credential.helper
mk_repo "$HOME/projects/elsewhere"
eq "no name outside the root" "$(git -C "$HOME/projects/elsewhere" config user.name)" ""
mk_repo "$root/GITHUB/ALICE/my/caseproj"
eq "includeIf matches case-insensitively" "$(git -C "$root/GITHUB/ALICE/my/caseproj" config user.name)" "Alice Example"

# ---------------------------------------------------------------- search

section "search"
mk_repo "$root/github/alice/my/mcproj"
mk_repo "$root/github/alice/my/mcproj/vendor/mcnested"
mk_repo "$root/github/alice/contrib/other"
mk_repo "$root/my/mctool"
mk_repo "$root/apps/thing"
eq "search one term" "$(gitum search mc)" "$root/github/alice/my/mcproj
$root/my/mctool"
eq "search narrows by every term" "$(gitum search github mc)" "$root/github/alice/my/mcproj"
eq "search is case-insensitive" "$(gitum search MC)" "$(gitum search mc)"
eq "search with no match prints nothing" "$(gitum search zzzz)" ""
out=$(gitum search 2>&1); rc=$?
eq "search without terms exits 2" "$rc" 2

# ---------------------------------------------------------------- test

section "test"
out=$(STUB_SSH_MODE=ok gitum test github alice 2>&1); rc=$?
eq "test pass exits 0" "$rc" 0
contains "test PASS" "$out" "github/alice: PASS"
contains "greeting printed" "$out" "Hi alice!"
args=$(tr '\n' ' ' < "$STUB_SSH_ARGS")
contains "ssh -i key" "$args" "-i $HOME/.ssh/gitum/github_alice "
contains "ssh IdentitiesOnly" "$args" "-o IdentitiesOnly=yes "
contains "ssh AddKeysToAgent" "$args" "-o AddKeysToAgent=yes "
contains "ssh -T target" "$args" "-T git@github.com"
out=$(STUB_SSH_MODE=denied gitum test github alice 2>&1); rc=$?
eq "denied exits 1" "$rc" 1
contains "denied explained" "$out" "did not accept the key"
out=$(STUB_SSH_MODE=wronguser gitum test github alice 2>&1); rc=$?
eq "wrong user exits 1" "$rc" 1
contains "wrong user explained" "$out" "does not name alice"
out=$(STUB_SSH_MODE=unreachable gitum test github alice 2>&1); rc=$?
eq "unreachable exits 1" "$rc" 1
contains "unreachable explained" "$out" "could not connect"
out=$(STUB_SSH_MODE=ok gitum test 2>&1); rc=$?
eq "test all exits 1 when one account fails" "$rc" 1
contains "test all: alice passes" "$out" "github/alice: PASS"
contains "test all: bob fails on the greeting" "$out" "forgejo-work/bob: FAIL"
contains "test all: summary" "$out" "1 of 2 account(s) passed."
out=$(gitum test github nobody 2>&1); rc=$?
eq "unknown account exits 1" "$rc" 1
out=$(gitum test github 2>&1); rc=$?
eq "one argument exits 2" "$rc" 2

section "ssh config overlap warning"
mkdir -p "$HOME/.ssh/conf.d"
cat > "$HOME/.ssh/config" <<'EOF'
Host github.com
  IdentityFile ~/.ssh/id_ed25519
Host other.example.com
  IdentityFile ~/.ssh/other
Match host git.example.com
  IdentityAgent none
Include conf.d/*
EOF
printf 'Host *.example.com\n  IdentityFile ~/.ssh/wild\n' > "$HOME/.ssh/conf.d/extra"
out=$(STUB_SSH_MODE=ok gitum test github alice 2>&1)
contains "overlap names file and line" "$out" "~/.ssh/config:2 applies to github.com"
lacks "unrelated Host block not reported" "$out" "config:4"
contains "overlap explained" "$out" "after the gitum key"
out=$(STUB_SSH_MODE=ok gitum test forgejo-work bob 2>&1)
contains "Match block reported" "$out" "~/.ssh/config:6 applies to git.example.com"
contains "Include file reported" "$out" "~/.ssh/conf.d/extra:2 applies to git.example.com"
lacks "github block not reported for bob" "$out" "config:2"
out=$(printf '\nEve E\neve@example.com\nn\n' | gitum add github eve 2>&1)
contains "add warns about overlap" "$out" "~/.ssh/config:2 applies to github.com"
rm -f "${HOME:?}/.ssh/config"

# ---------------------------------------------------------------- adopt

section "adopt"
mk_repo "$HOME/projects/aliceproj"
git -C "$HOME/projects/aliceproj" remote add origin git@github-alias:alice/aliceproj.git
out=$(printf 'y\n\ny\n' | gitum adopt github alice "$HOME/projects/aliceproj" 2>&1); rc=$?
eq "adopt alias exits 0" "$rc" 0
contains "adopt shows origin" "$out" "origin: git@github-alias:alice/aliceproj.git"
contains "adopt suggests my for own repos" "$out" "Destination subdirectory [my]"
ok "moved into my" test -d "$root/github/alice/my/aliceproj/.git"
ok "old path gone" test ! -e "$HOME/projects/aliceproj"
eq "alias rewritten to the canonical host" "$(git -C "$root/github/alice/my/aliceproj" remote get-url origin)" "git@github.com:alice/aliceproj.git"
mk_repo "$HOME/projects/lib"
git -C "$HOME/projects/lib" remote add origin https://github.com/someone/lib.git
out=$(printf 'y\n\ny\n' | gitum adopt github alice '~/projects/lib' 2>&1); rc=$?
eq "adopt https exits 0" "$rc" 0
contains "adopt suggests contrib for others' repos" "$out" "Destination subdirectory [contrib]"
eq "https converted to ssh" "$(git -C "$root/github/alice/contrib/lib" remote get-url origin)" "git@github.com:someone/lib.git"
mkdir -p "$HOME/projects/notrepo"
out=$(gitum adopt github alice "$HOME/projects/notrepo" 2>&1); rc=$?
eq "adopt non-repo exits 1" "$rc" 1
contains "adopt non-repo message" "$out" "not a git repository"
mk_repo "$HOME/projects/aliceproj"
out=$(printf 'my\n' | gitum adopt github alice "$HOME/projects/aliceproj" 2>&1); rc=$?
eq "adopt onto an existing destination exits 1" "$rc" 1
contains "destination exists message" "$out" "destination exists"
ok "source untouched" test -d "$HOME/projects/aliceproj/.git"
mk_repo "$HOME/projects/keep"
out=$(printf '\nn\n' | gitum adopt github alice "$HOME/projects/keep" 2>&1); rc=$?
eq "declined move exits 0" "$rc" 0
ok "declined move leaves the repo" test -d "$HOME/projects/keep/.git"
out=$(printf 'n\n\ny\n' | gitum adopt forgejo-work bob "$root/github/alice/contrib/lib" 2>&1); rc=$?
eq "adopt between accounts exits 0" "$rc" 0
ok "moved to bob/contrib" test -d "$root/forgejo-work/bob/contrib/lib/.git"
eq "remote kept when the rewrite is declined" "$(git -C "$root/forgejo-work/bob/contrib/lib" remote get-url origin)" "git@github.com:someone/lib.git"
eq "identity follows the move" "$(git -C "$root/forgejo-work/bob/contrib/lib" config user.name)" "Bob Builder"
mkdir -p "$root/github/alice/clientco"
mk_repo "$HOME/projects/clientwork"
out=$(printf 'clientco\ny\n' | gitum adopt github alice "$HOME/projects/clientwork" 2>&1); rc=$?
eq "adopt into a custom subdirectory exits 0" "$rc" 0
contains "custom subdirectory listed" "$out" "apps clientco contrib my view"
ok "moved into clientco" test -d "$root/github/alice/clientco/clientwork/.git"
out=$(gitum adopt github nobody "$HOME/projects/keep" 2>&1); rc=$?
eq "adopt into an unknown account exits 1" "$rc" 1
out=$(gitum adopt github alice 2>&1); rc=$?
eq "adopt without paths exits 2" "$rc" 2

section "azure-devops"
out=$(printf '\nDana Dev\ndana@example.com\nn\n' | gitum add azure-devops dana 2>&1); rc=$?
eq "add azure exits 0" "$rc" 0
contains "azure keygen is rsa" "$out" 'ssh-keygen -t rsa -b 4096 -f ~/.ssh/gitum/azure-devops_dana -C "dana@azure-devops (gitum)"'
contains "azure settings url" "$out" "https://dev.azure.com/<organization>/_usersSettings/keys"
mk_repo "$HOME/projects/azrepo"
git -C "$HOME/projects/azrepo" remote add origin https://dev.azure.com/org/proj/_git/azrepo
out=$(printf 'y\n\ny\n' | gitum adopt azure-devops dana "$HOME/projects/azrepo" 2>&1); rc=$?
eq "adopt azure exits 0" "$rc" 0
eq "azure https converted" "$(git -C "$root/azure-devops/dana/contrib/azrepo" remote get-url origin)" "git@ssh.dev.azure.com:v3/org/proj/azrepo"
out=$(STUB_SSH_MODE=azure gitum test azure-devops dana 2>&1); rc=$?
eq "azure test passes on authentication alone" "$rc" 0
contains "azure PASS" "$out" "azure-devops/dana: PASS"

# ---------------------------------------------------------------- delete

section "delete"
out=$(gitum delete github nobody 2>&1); rc=$?
eq "delete unknown exits 1" "$rc" 1
out=$(printf 'y\n' | gitum delete github alice 2>&1); rc=$?
eq "delete non-empty exits 1" "$rc" 1
contains "delete lists what is in the way" "$out" "aliceproj"
ok "alice config survives" test -f "$acfg"
printf '\nCarol C\ncarol@example.com\nn\n' | gitum add gitlab carol >/dev/null 2>&1
"$real_keygen" -q -t ed25519 -N '' -f "$HOME/.ssh/gitum/gitlab_carol" -C test
out=$(printf 'n\n' | gitum delete gitlab carol 2>&1); rc=$?
eq "delete declined exits 0" "$rc" 0
contains "nothing deleted" "$out" "Nothing deleted."
ok "carol config kept" test -f "$HOME/.config/gitum/accounts/gitlab/carol.gitconfig"
out=$(printf 'y\nn\n' | gitum delete gitlab carol 2>&1); rc=$?
eq "delete exits 0" "$rc" 0
ok "carol config removed" test ! -e "$HOME/.config/gitum/accounts/gitlab/carol.gitconfig"
ok "carol directory removed" test ! -e "$root/gitlab/carol"
ok "empty platform directory removed" test ! -e "$root/gitlab"
lacks "includeIf removed" "$(cat "$HOME/.config/gitum/gitconfig")" "carol"
ok "key kept" test -f "$HOME/.ssh/gitum/gitlab_carol"
contains "kept key path printed" "$out" "~/.ssh/gitum/gitlab_carol.pub"
contains "registration reminder" "$out" "stays registered on gitlab.com"
printf '\nCarol C\ncarol@example.com\nn\n' | gitum add gitlab carol >/dev/null 2>&1
out=$(printf 'y\ny\n' | gitum delete gitlab carol 2>&1); rc=$?
eq "delete with keys exits 0" "$rc" 0
ok "private key deleted" test ! -e "$HOME/.ssh/gitum/gitlab_carol"
ok "public key deleted" test ! -e "$HOME/.ssh/gitum/gitlab_carol.pub"
printf '\nCarol C\ncarol@example.com\nn\n' | gitum add gitlab carol >/dev/null 2>&1
printf 'keep\n' > "$root/gitlab/README"
printf 'y\n' | gitum delete gitlab carol >/dev/null 2>&1
ok "platform directory with other content stays" test -f "$root/gitlab/README"
ok "account directory removed anyway" test ! -e "$root/gitlab/carol"
out=$(gitum delete gitlab 2>&1); rc=$?
eq "delete with one argument exits 2" "$rc" 2

# ---------------------------------------------------------------- init --root

section "init --root"
mv "$HOME/src" "$HOME/code"
out=$(gitum init --root '~/code' 2>&1); rc=$?
eq "init --root exits 0" "$rc" 0
newroot=$(cd -P "$HOME/code" && pwd -P)
eq "config root updated" "$(cat "$HOME/.config/gitum/config")" "root=$newroot"
contains "includeIf rewritten" "$(cat "$HOME/.config/gitum/gitconfig")" "gitdir/i:$newroot/github/alice/"
lacks "old root gone" "$(cat "$HOME/.config/gitum/gitconfig")" "$root/"
eq "identity at the new root" "$(git -C "$newroot/github/alice/my/aliceproj" config user.name)" "Alice Example"
contains "no files moved" "$out" "No files were moved"
out=$(printf '~/elsewhere\n' | gitum init 2>&1); rc=$?
eq "interactive root change with accounts is refused" "$rc" 1
contains "refusal names --root" "$out" "gitum init --root ~/elsewhere"
out=$(gitum init --root '~/missing' 2>&1); rc=$?
eq "init --root to a missing directory exits 1" "$rc" 1
out=$(printf '\n' | gitum init 2>&1); rc=$?
eq "init re-run after the move exits 0" "$rc" 0
contains "reports the new root" "$out" "root:      ~/code"
out=$(gitum init --bogus 2>&1); rc=$?
eq "init with an unknown option exits 2" "$rc" 2

# ---------------------------------------------------------------- summary

printf '\n%d checks passed, %d failed\n' "$passes" "$fails"
[ "$fails" -eq 0 ]
