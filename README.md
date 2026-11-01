# gitum

Git User Manager: the directory a repository lives in decides which git account authors its commits and which SSH key reaches its remote.

gitum is a bash command for people with more than one git account, on one platform or on several. It sets up one source root with one directory per account. Every repository under an account directory commits as that account and authenticates with that account's key. Every repository anywhere else has no identity and no key: a commit fails instead of guessing a name, and SSH offers no key at all. Nothing is configured per repository.

## The layout

One source root per machine, chosen when `gitum init` runs (for example `~/src`). Directly under it: `apps`, `contrib`, `my` and `view`, for repositories that belong to no account. One directory per account at `<root>/<platform>/<username>/`, with the same four subdirectories plus any you add by hand, such as a client name:

```text
~/src
├── apps                     no identity, no key
├── contrib
├── my
├── view
├── github
│   ├── blbynum              commits as blbynum, key ~/.ssh/gitum/github_blbynum
│   │   ├── apps
│   │   ├── contrib
│   │   ├── my
│   │   └── view
│   └── HexWrench            commits as HexWrench, key ~/.ssh/gitum/github_HexWrench
└── forgejo
    └── blbynum              the same username on another platform
```

The platform layer exists because one username can exist on several platforms. The platform directory is always the platform type, so each account directory is `<type>/<username>` under the root. Two accounts with the same type and username share one directory, so gitum refuses the second account, also when its host is different.

## How selection works

Git configuration, nothing else.

`gitum init` makes two edits to `~/.gitconfig`, after a timestamped backup: it removes the global `user.name` and `user.email`, and it appends one line, `[include] path = ~/.config/gitum/gitconfig`. Everything else in the file stays. If the file has `includeIf` rules of its own, gitum prints them so that you can clean them up by hand. If `~/.config/git/config` also sets an identity, gitum warns, because git reads that file too.

`~/.config/gitum/gitconfig` belongs to gitum. It holds the strict defaults, then one `includeIf` rule per account:

```ini
[user]
	useConfigOnly = true
[core]
	sshCommand = ssh -o PubkeyAuthentication=no -o IdentityAgent=none
[credential]
	helper =
[includeIf "gitdir/i:/Users/me/src/github/blbynum/"]
	path = ~/.config/gitum/accounts/github/blbynum.gitconfig
```

Later entries win in git, so the settings of an account override the defaults for repositories under its directory. The `/i` form matches case-insensitively, which APFS and NTFS need and which is harmless on Linux. The defaults do three things:

- `user.useConfigOnly` makes a commit outside an account directory fail with "no email was given and auto-detection is disabled", instead of a name derived from the OS account.
- `core.sshCommand` with `PubkeyAuthentication=no` and `IdentityAgent=none` offers no key at all, not `~/.ssh/id_ed25519` and not an agent key. The server answers "Permission denied (publickey)". Anonymous HTTPS reads still work.
- The empty `credential.helper` clears helpers inherited from the system configuration, such as `osxkeychain` on macOS, so HTTPS does not authenticate either.

Each account config (`~/.config/gitum/accounts/<platform>/<username>.gitconfig`) sets the identity, the key and a URL rewrite:

```ini
[user]
	name = Ben Bynum
	email = ben@example.com
[core]
	sshCommand = ssh -i ~/.ssh/gitum/github_blbynum -o IdentitiesOnly=yes -o AddKeysToAgent=yes -o UseKeychain=yes
[url "git@github.com:"]
	insteadOf = https://github.com/
[gitum]
	type = github
	host = github.com
	dir = github
	user = blbynum
	key = ~/.ssh/gitum/github_blbynum
```

`-o UseKeychain=yes` is present on macOS only. The `url` rewrite turns a pasted HTTPS clone URL into an SSH clone with the account key. The `[gitum]` section is the record of the account; read it with `git config -f <file> --get gitum.host`.

gitum does not edit `~/.ssh/config`, and remote URLs stay canonical (`git@github.com:user/repo.git`). Your ssh configuration stays in force, because a self-hosted platform can depend on it for a jump host or a port. The section "Overlap with ~/.ssh/config" describes the cost.

## Install

Prerequisites:

- bash 3.2 or later (the macOS `/bin/bash` is enough)
- git
- OpenSSH (`ssh` and `ssh-keygen`)
- macOS or Linux

Clone the repository and run the installer:

```bash
git clone https://github.com/blbynum/gitum.git
cd gitum
./install.sh
```

The installer symlinks `~/.local/bin/gitum` to the script in the clone, so `git pull` updates the tool. It adds a guarded line to `~/.zshrc` or `~/.bashrc` (by `$SHELL`) that puts `~/.local/bin` on the PATH, only when the directory is not on the PATH already; for another shell it prints the line to add. Then it runs `gitum init`, which asks for the source root:

```text
gitum keeps every account directory under one source root.
Source root [~/src]:
~/src does not exist. Create it? [Y/n]
Create the recommended directories apps, contrib, my, view under ~/src? [Y/n]
Created apps, contrib, my, view.
Backed up ~/.gitconfig to ~/.gitconfig.gitum-backup-20261028190009
Removed user.name (Ben Bynum) from ~/.gitconfig
Removed user.email (ben@example.com) from ~/.gitconfig
Appended '[include] path = ~/.config/gitum/gitconfig' to ~/.gitconfig

gitum state
  root:      ~/src
  config:    ~/.config/gitum
  accounts:  0
  ~/.gitconfig includes ~/.config/gitum/gitconfig: yes

Next: add an account with: gitum add
```

From this point, repositories outside account directories have no identity and no key. That is the intended state. Add an account, then adopt the repositories that must commit as it.

The installer is safe to re-run. Re-run it after you move the clone, for example into an account directory once one exists.

## Add an account

`gitum add` asks for the platform type, the host (for self-hosted types), the username, and the commit name and email. Pass the type and the username as arguments to skip those prompts:

```bash
gitum add github blbynum
```

```text
Commit author name: Ben Bynum
Commit author email: ben@example.com
Added account github/blbynum
  directory: ~/src/github/blbynum
  config:    ~/.config/gitum/accounts/github/blbynum.gitconfig

Generate the SSH key now? ssh-keygen asks for an optional passphrase. [Y/n]
Generating public/private ed25519 key pair.
Enter passphrase for "/Users/me/.ssh/gitum/github_blbynum" (empty for no passphrase):
...
Copied ~/.ssh/gitum/github_blbynum.pub to the clipboard with pbcopy.

The public key is on the clipboard.
Register the key on GitHub as blbynum:
  1. Open https://github.com/settings/keys and sign in as blbynum.
  2. Click "New SSH key".
  3. Title: a name for this machine, for example "gitum github".
  4. Key type: "Authentication Key".
  5. Key: paste the public key.
  6. Click "Add SSH key". Confirm access if GitHub asks.
Then run: gitum test github blbynum

Run the connection test now? [Y/n]
```

gitum runs `ssh-keygen` interactively, so ssh-keygen itself asks for the passphrase. A passphrase is your choice. gitum never asks for one, never stores one and never passes one. If you decline the key, the guide prints the `ssh-keygen` command to run by hand. The public key goes to the clipboard when `pbcopy`, `wl-copy` or `xclip` exists. Azure DevOps gets an RSA key, because that is the only type Azure DevOps accepts. Every other platform gets ed25519.

Then clone into the account directory, or move existing repositories with `gitum adopt`.

## Commands

Conventions: plain text, no color; errors on stderr; exit status 1 for a failed operation and 2 for a usage error. `gitum` alone and `gitum help` print the usage. `gitum --version` prints the version. Before `init` has run, every other command says to run `install.sh`.

In the synopses, `<platform>` is the platform directory name under the root (`github`, `forgejo`). `<type>` is a type from the platform table: `github`, `gitlab`, `bitbucket`, `forgejo`, `codeberg`, `gitea`, `azure-devops`, `sourcehut` or `other`.

### gitum init [--root <path>]

Sets up the root and the git configuration, as described under "Install". Run it again with the same root and it reports the state and changes nothing.

Run it again with a different root while accounts exist and it refuses. To move the root: move the tree by hand, then run `gitum init --root <new>`. That rewrites every `includeIf` rule to the new root and moves no files.

### gitum add [<type>] [<username>]

Adds an account, as described under "Add an account". If the account's directory tree and config both exist, it warns and stops. If only the directory tree exists, it continues and uses it.

### gitum update <platform> <username> [name|email|key]

Replaces the commit author name, the commit author email or the SSH key of an account. Without a field, gitum asks for all three, as `gitum add` does. Each prompt shows the current value; press Enter to keep it. The key prompt defaults to no when a key exists. With a field, gitum asks only for that one:

```bash
gitum update github blbynum key
```

```text
Changes to github/blbynum:
  SSH key:      new key pair at ~/.ssh/gitum/github_blbynum
gitum: warning: gitum deletes the old key pair. SSH access to github.com as blbynum fails until you register the new public key.
Apply these changes? [y/N] y
Generating public/private ed25519 key pair.
...
Replaced the key pair ~/.ssh/gitum/github_blbynum
Copied ~/.ssh/gitum/github_blbynum.pub to the clipboard with pbcopy.

The public key is on the clipboard.
Register the key on GitHub as blbynum:
...
Then run: gitum test github blbynum
The old public key stays registered on github.com until you remove it there.

Run the connection test now? [Y/n]
```

gitum lists the changes, warns, and asks for one confirmation, default no. The new values replace the old ones. Commits you already made keep their author. ssh-keygen writes the new key pair beside the old one, and gitum moves it into place only when ssh-keygen succeeds. A failed or cancelled ssh-keygen leaves the old key pair as it was. After the test passes, remove the old public key from the platform.

### gitum test [<platform> <username>]

Runs `ssh -T` against the account's host with the account's key and options. With no arguments it tests every account. Pass means that the server accepted the gitum key of the account. gitum runs ssh with `-v` and reads which key the server accepted. If the server accepted another key, for example one that `~/.ssh/config` adds, the test fails and names that key. gitum prints the server greeting and, where the platform table has a greeting pattern, checks that the greeting names the username, so a key registered to the wrong account is reported. Azure DevOps answers that shell access is unsupported, so there the pass is authentication alone.

```text
github/blbynum: ssh -T git@github.com with key ~/.ssh/gitum/github_blbynum
  | Hi blbynum! You've successfully authenticated, but GitHub does not provide shell access.
github/blbynum: PASS
```

The test adds `PasswordAuthentication=no` and `KbdInteractiveAuthentication=no`, so that a rejected key fails instead of a password prompt. It also adds `ControlPath=none`, so that ssh authenticates again instead of reusing a shared connection. The first connection to a host still asks you to confirm the host key.

### gitum list [<platform>]

One line per account, grouped by platform directory, with a marker when the key file is missing:

```text
forgejo/benb             Ben Bynum <ben@example.com>              ~/.ssh/gitum/forgejo_benb  (key missing)

github/blbynum           Ben Bynum <ben@example.com>              ~/.ssh/gitum/github_blbynum
```

### gitum search <term>...

Finds projects under the root. A project is a directory that contains `.git`; the search does not descend into a repository once found. Each term is a case-insensitive substring, and every term must match the path relative to the root, so a platform or username narrows the search. One absolute path per line, sorted:

```bash
gitum search github mc
```

```text
/Users/me/src/github/blbynum/contrib/mcfly
```

### gitum adopt <platform> <username> <path>...

Moves repositories into an account directory, one path at a time. For each path, gitum:

1. Refuses if the path is not a git repository.
2. Shows the origin remote.
3. If the remote uses an SSH host alias such as `git@github-work:`, offers to rewrite it to the canonical host.
4. If the remote is HTTPS, offers to convert it to SSH, because HTTPS authentication no longer works.
5. Suggests `my` when the remote owner is the username and `contrib` otherwise, and asks for the subdirectory from the ones under the account.
6. Refuses if the destination name exists.
7. Moves the repository.
8. If the repository has linked worktrees, runs `git worktree repair`, because the move breaks their links. Worktrees inside the repository move with it. Worktrees outside it stay where they are.

Nothing changes without a yes. To move a repository from one account to another, run the same command.

```text
Repository: ~/projects/oldproj
  origin: https://github.com/blbynum/oldproj.git
  HTTPS remotes no longer authenticate under gitum.
  Convert origin to git@github.com:blbynum/oldproj.git? [Y/n] y
  origin is now git@github.com:blbynum/oldproj.git
  Subdirectories of ~/src/github/blbynum: apps contrib my view
  Destination subdirectory [my]:
  Move ~/projects/oldproj to ~/src/github/blbynum/my/oldproj? [Y/n] y
  Moved to ~/src/github/blbynum/my/oldproj
```

### gitum delete <platform> <username>

Removes an account. If the account directory holds anything but empty directories, gitum lists the repositories and files in the way and stops. Move or delete them first: gitum never deletes a repository.

```text
gitum: warning: ~/src/github/blbynum is not empty. Move or delete these first (repositories and files, at most 20 shown):
  contrib/mcfly
  my/oldproj
```

After one confirmation, gitum removes the account config, its `includeIf` rule and the username directory. It removes the platform directory only when that was its last account and nothing else is in it. Then it asks separately whether to delete the key pair, default no, and prints the key paths when you keep them. The public key stays registered on the platform either way.

## Overlap with ~/.ssh/config

gitum leaves `~/.ssh/config` alone. If that file has an `IdentityFile` or `IdentityAgent` entry that applies to an account's host, ssh offers that key too. ssh offers the keys that ssh-agent holds before the keys that it reads from files. So when ssh-agent holds the other key and not the gitum key, ssh offers the other key first. If the platform accepts the other key, ssh authenticates as whichever account owns it, with no error. `gitum test` then fails and names the key that the platform accepted. `gitum add` and `gitum test` warn when such an entry exists, with the file and the line:

```text
gitum: warning: ~/.ssh/config:2 applies to github.com: IdentityFile ~/.ssh/id_ed25519
```

Move those entries under a `Host` alias that git does not use, or remove them.

## State

| Path | Content |
|---|---|
| `~/.config/gitum/config` | `root=<path>`. Plain key=value lines, parsed, never sourced. |
| `~/.config/gitum/gitconfig` | The strict defaults and one `includeIf` rule per account. |
| `~/.config/gitum/accounts/<platform>/<username>.gitconfig` | One account. |
| `~/.ssh/gitum/<platform>_<username>` and `.pub` | The key pair of the account. |

`XDG_CONFIG_HOME` replaces `~/.config` when it is set. An account exists when both its directory tree and its config file exist.

## Platforms

`resources/platforms.tsv` has one row per type: type, host, ssh user, key type, settings URL and greeting pattern. `resources/guides/<type>.txt` is the registration guide that `gitum add` and `gitum update` print, at most 15 lines so that it fits a small terminal window. To add a platform, add one row and one guide.

## Limits in 0.1.0

- Commit signing is not configured.
- The `gh` and `glab` CLIs use their own active account regardless of directory; gitum does not scope them.
- Keys are not uploaded through platform APIs; the guide shows the web steps.
- `gitum add` and `gitum update` are interactive; they have no non-interactive flags.
- An Azure DevOps HTTPS URL (`https://dev.azure.com/<org>/<project>/_git/<repo>`) is not rewritten by the account's URL rule. Clone with the SSH URL from the Clone dialog. `gitum adopt` converts such URLs.

## Tests

`tests/run.sh` runs the installer and every command against a temporary HOME, with `ssh`, `ssh-keygen` and `pbcopy` replaced by stubs; it needs no network, and it touches nothing in your own home directory. The GitHub Actions workflow runs it on ubuntu-latest and macos-latest, on macOS also under bash 3.2.

```bash
bash tests/run.sh
```

## License

MIT. See [LICENSE](LICENSE).
