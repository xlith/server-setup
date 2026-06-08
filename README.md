# server-setup

One idempotent script that turns a fresh **Ubuntu** server into a comfortable
terminal: updates the system, installs modern CLI tools, wires them into `bash`, and
optionally reboots once at the end. Built and tested on Ubuntu 24.04 LTS.

## Usage

```bash
chmod +x setup.sh
./setup.sh            # update + install everything, then reboot (any key cancels)
exec bash             # reload your shell when it's done
```

Runs as **root** or any **sudo-capable user**. Safe to re-run.

| Flag | Effect |
|------|--------|
| `--no-reboot` | Install everything, skip the reboot. |
| `--skip-update` | Skip the apt `full-upgrade`, still install tools. |
| `--update` | Maintenance mode: bring system + tools up to date, no reboot. |
| `--help` | Show usage. |

## What you get

<table>
  <thead>
    <tr><th>Tool</th><th>Description</th></tr>
  </thead>
  <tbody>
    <tr><th colspan="2" align="left">Prompt &amp; shell</th></tr>
    <tr><td><a href="https://github.com/JanDeDobbeleer/oh-my-posh">oh-my-posh</a></td><td>Customizable prompt theme engine</td></tr>
    <tr><td><a href="https://github.com/ajeetdsouza/zoxide">zoxide</a></td><td>Smarter <code>cd</code> — jump with <code>z</code></td></tr>
    <tr><td><a href="https://github.com/junegunn/fzf">fzf</a></td><td>Fuzzy finder for files and history</td></tr>
    <tr><td><a href="https://github.com/atuinsh/atuin">atuin</a></td><td>Searchable shell history (<code>Ctrl-R</code>)</td></tr>
    <tr><th colspan="2" align="left">Editor</th></tr>
    <tr><td><a href="https://github.com/neovim/neovim">Neovim</a></td><td>Latest build, from <code>neovim-ppa/unstable</code></td></tr>
    <tr><th colspan="2" align="left">Files</th></tr>
    <tr><td><a href="https://github.com/eza-community/eza">eza</a></td><td>Modern <code>ls</code> with icons and git status</td></tr>
    <tr><td><a href="https://github.com/sharkdp/fd">fd</a></td><td>Fast, friendly <code>find</code></td></tr>
    <tr><td><a href="https://github.com/sharkdp/bat">bat</a></td><td><code>cat</code> with syntax highlighting</td></tr>
    <tr><td><a href="https://github.com/sxyazi/yazi">yazi</a></td><td>Terminal file manager</td></tr>
    <tr><td><a href="https://github.com/bootandy/dust">dust</a></td><td>Visual disk usage tree</td></tr>
    <tr><td><a href="https://github.com/muesli/duf">duf</a></td><td>Friendly <code>df</code></td></tr>
    <tr><td><a href="https://dev.yorhel.nl/ncdu">ncdu</a></td><td>Interactive disk usage cleanup</td></tr>
    <tr><th colspan="2" align="left">Search &amp; data</th></tr>
    <tr><td><a href="https://github.com/BurntSushi/ripgrep">ripgrep</a></td><td>Fast recursive search (<code>rg</code>)</td></tr>
    <tr><td><a href="https://github.com/jqlang/jq">jq</a></td><td>Command-line JSON processor</td></tr>
    <tr><th colspan="2" align="left">Git</th></tr>
    <tr><td><a href="https://github.com/jesseduffield/lazygit">lazygit</a></td><td>Terminal UI for git (<code>lg</code>)</td></tr>
    <tr><td><a href="https://github.com/dandavison/delta">git-delta</a></td><td>Syntax-highlighted git diffs</td></tr>
    <tr><th colspan="2" align="left">System</th></tr>
    <tr><td><a href="https://github.com/aristocratos/btop">btop</a></td><td>Resource monitor (<code>top</code>)</td></tr>
    <tr><td><a href="https://github.com/dalance/procs">procs</a></td><td>Modern <code>ps</code> replacement</td></tr>
    <tr><td><a href="https://github.com/imsnif/bandwhich">bandwhich</a></td><td>Per-process network usage</td></tr>
    <tr><th colspan="2" align="left">Misc</th></tr>
    <tr><td><a href="https://github.com/zellij-org/zellij">zellij</a></td><td>Terminal multiplexer &amp; workspace</td></tr>
    <tr><td><a href="https://github.com/httpie/cli">HTTPie</a></td><td>Human-friendly HTTP client</td></tr>
    <tr><td><a href="https://github.com/tldr-pages/tlrc">tlrc</a></td><td>Official <code>tldr</code> client — concise example pages</td></tr>
  </tbody>
</table>

Key bindings: `Ctrl-R` atuin · `Ctrl-T` fzf files · `Alt-C` fzf cd · `z`/`zi` zoxide.
Aliases apply to interactive shells only; `find`, `ps`, and `cd` are left untouched.

## Removing tools

Tools are installed three ways; remove them according to where they came from.

**apt packages** (fzf, ripgrep, jq, bat, fd, zoxide, ncdu, duf, btop, httpie, neovim, eza) — and `git-delta`, which installs as a `.deb`:

```bash
sudo apt-get remove --purge -y <package>     # e.g. ripgrep, neovim, eza, git-delta
sudo apt-get autoremove --purge -y
```

> `bat` is the `bat` package (binary `batcat`), `fd` is `fd-find` (binary `fdfind`).
> Also delete the `~/.local/bin/bat` and `~/.local/bin/fd` symlinks if you remove those.

**Standalone binaries** in `/usr/local/bin` (zellij, lazygit, dust, procs, bandwhich, yazi, atuin, tlrc) — and oh-my-posh in `~/.local/bin`:

```bash
sudo rm -f /usr/local/bin/{zellij,lazygit,dust,procs,bandwhich,yazi,ya,atuin,tldr}
rm -f ~/.local/bin/oh-my-posh
```

**Remove everything this script added** (tools + shell integration):

```bash
# 1. Delete the managed block from ~/.bashrc (between the markers)
sed -i '/# >>> server-setup >>>/,/# <<< server-setup <<</d' ~/.bashrc

# 2. Drop the helper/config files it created
rm -rf ~/.bash-preexec.sh ~/.config/oh-my-posh ~/.config/server-setup

# 3. Undo the git-delta pager config
git config --global --unset core.pager
git config --global --unset interactive.diffFilter

# 4. Remove the added apt sources, then remove the packages as shown above
sudo add-apt-repository -r -y ppa:neovim-ppa/unstable
sudo rm -f /etc/apt/sources.list.d/gierens.list /etc/apt/keyrings/gierens.gpg
sudo apt-get update
```

Run `exec bash` afterwards to reload your shell.

## Notes

- **Nerd Font needed for icons** — the prompt, eza, and btop render glyphs using
  *your* terminal's font, not the server's. Install a Nerd Font (e.g. MesloLGS NF)
  locally and select it, or icons show as boxes.
- Supports `x86_64` and `aarch64`. Set `GITHUB_TOKEN` to avoid GitHub API rate limits.
- Override `OMP_THEME` / `BAT_THEME_NAME` via env vars.

## License

MIT
