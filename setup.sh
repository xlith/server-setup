#!/usr/bin/env bash
#
# server-setup — Ubuntu terminal environment bootstrapper
#
# Updates the system, installs a curated set of modern terminal tools, wires
# them into bash, and (optionally) reboots once at the end.
#
# Usage:
#   ./setup.sh                 Full install: update + install everything, then reboot
#   ./setup.sh --no-reboot     Install everything but do not reboot
#   ./setup.sh --skip-update   Skip the apt full-upgrade phase, still install tools
#   ./setup.sh --update        Maintenance mode: bring everything up to date, no reboot
#   ./setup.sh --help          Show usage
#
# Runs as root OR as a normal sudo-capable user. Idempotent — safe to re-run.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
OMP_THEME="${OMP_THEME:-jandedobbeleer}"        # oh-my-posh theme (from upstream themes/)
BAT_THEME_NAME="${BAT_THEME_NAME:-TwoDark}"     # bundled bat theme
VERSIONS_FILE="$HOME/.config/server-setup/versions.env"
LOCAL_BIN="$HOME/.local/bin"

BEGIN_MARK='# >>> server-setup >>>'
END_MARK='# <<< server-setup <<<'

# Make user-installed tools visible to this script's own checks.
export PATH="$LOCAL_BIN:$PATH"

# Runtime state (set in preflight)
SUDO=""
APT=()
RUST_ARCH=""
DEB_ARCH=""
LAZYGIT_ARCH=""

# Defaults overridden by args
MODE="install"      # install | update
DO_REBOOT=1
DO_SYSTEM_UPDATE=1

# Scratch space, cleaned up on exit
TMP_BASE="$(mktemp -d)"
cleanup() { rm -rf "$TMP_BASE"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_BLUE=$'\033[1;34m'; C_YELLOW=$'\033[1;33m'
  C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'; C_BOLD=$'\033[1m'
else
  C_RESET=""; C_BLUE=""; C_YELLOW=""; C_RED=""; C_GREEN=""; C_BOLD=""
fi

info()    { printf '%s[*]%s %s\n'  "$C_BLUE"   "$C_RESET" "$*"; }
warn()    { printf '%s[!]%s %s\n'  "$C_YELLOW" "$C_RESET" "$*" >&2; }
error()   { printf '%s[x]%s %s\n'  "$C_RED"    "$C_RESET" "$*" >&2; }
ok()      { printf '%s[+]%s %s\n'  "$C_GREEN"  "$C_RESET" "$*"; }
section() { printf '\n%s==>%s %s%s%s\n' "$C_BOLD" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; }

usage() {
  sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'
}

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Version tracking (for --update of GitHub-release tools)
# ---------------------------------------------------------------------------
get_recorded_version() {
  [ -f "$VERSIONS_FILE" ] && grep -E "^$1=" "$VERSIONS_FILE" | tail -n1 | cut -d= -f2- || true
}

record_version() {
  mkdir -p "$(dirname "$VERSIONS_FILE")"
  touch "$VERSIONS_FILE"
  if grep -qE "^$1=" "$VERSIONS_FILE"; then
    sed -i "s|^$1=.*|$1=$2|" "$VERSIONS_FILE"
  else
    printf '%s=%s\n' "$1" "$2" >> "$VERSIONS_FILE"
  fi
}

# ---------------------------------------------------------------------------
# Download / GitHub helpers
# ---------------------------------------------------------------------------
download() {
  # download <url> <dest>
  curl -fL --retry 3 --retry-delay 2 -o "$2" "$1"
}

gh_release_json() {
  # gh_release_json <owner/repo> — cached per run
  local repo="$1" safe cache
  safe="$(printf '%s' "$repo" | tr '/' '_')"
  cache="$TMP_BASE/rel_$safe.json"
  if [ ! -s "$cache" ]; then
    curl -fsSL ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
      "https://api.github.com/repos/$repo/releases/latest" -o "$cache" 2>/dev/null || return 1
  fi
  cat "$cache"
}

gh_latest_tag() {
  gh_release_json "$1" 2>/dev/null \
    | grep -oE '"tag_name":[[:space:]]*"[^"]+"' \
    | sed -E 's/.*"tag_name":[[:space:]]*"([^"]+)".*/\1/' \
    | head -n1
}

gh_asset_url() {
  # gh_asset_url <owner/repo> <regex-on-url>
  gh_release_json "$1" 2>/dev/null \
    | grep -oE '"browser_download_url":[[:space:]]*"[^"]+"' \
    | sed -E 's/.*"browser_download_url":[[:space:]]*"([^"]+)".*/\1/' \
    | grep -E "$2" \
    | grep -viE '\.(sha256|sha256sum|sig|asc|sbom|pem)$' \
    | head -n1
}

extract() {
  # extract <archive> <dest-dir>
  case "$1" in
    *.zip) unzip -q -o "$1" -d "$2" ;;
    *)     tar -xf "$1" -C "$2" ;;
  esac
}

install_binaries_from_dir() {
  # install_binaries_from_dir <dir> <bin1> [bin2...]
  local dir="$1"; shift
  local bin found
  for bin in "$@"; do
    found="$(find "$dir" -type f -name "$bin" -perm -u+x 2>/dev/null | head -n1)"
    [ -z "$found" ] && found="$(find "$dir" -type f -name "$bin" 2>/dev/null | head -n1)"
    if [ -z "$found" ]; then
      warn "binary '$bin' not found in extracted archive"
      return 1
    fi
    $SUDO install -m 0755 "$found" "/usr/local/bin/$bin"
  done
}

# Decide whether a GitHub tool needs (re)installing, honouring MODE.
gh_should_install() {
  # gh_should_install <name> <checkbin> <latest> <current>
  local name="$1" checkbin="$2" latest="$3" current="$4"
  if [ "$MODE" = "install" ] && have "$checkbin" && [ -n "$current" ]; then
    info "$name already installed ($current) — skipping"
    return 1
  fi
  if [ "$MODE" = "update" ] && have "$checkbin" && [ -n "$latest" ] && [ "$latest" = "$current" ]; then
    info "$name up to date ($current)"
    return 1
  fi
  return 0
}

install_gh_tarball() {
  # install_gh_tarball <name> <owner/repo> <asset-regex> <bin1> [bin2...]
  local name="$1" repo="$2" regex="$3"; shift 3
  local latest current url tmp archive
  latest="$(gh_latest_tag "$repo")"
  if [ -z "$latest" ]; then warn "$name: could not query latest release (rate limit/network?) — skipping"; return 1; fi
  current="$(get_recorded_version "$name")"
  gh_should_install "$name" "$1" "$latest" "$current" || return 0

  url="$(gh_asset_url "$repo" "$regex")"
  if [ -z "$url" ]; then warn "$name: no asset matched /$regex/ in $latest — skipping"; return 1; fi

  info "Installing $name $latest"
  tmp="$TMP_BASE/$name"; mkdir -p "$tmp"
  archive="$tmp/${url##*/}"
  download "$url" "$archive"        || { warn "$name: download failed"; return 1; }
  extract "$archive" "$tmp"         || { warn "$name: extract failed"; return 1; }
  install_binaries_from_dir "$tmp" "$@" || { warn "$name: install failed"; return 1; }
  record_version "$name" "$latest"
  ok "$name $latest installed"
}

install_gh_deb() {
  # install_gh_deb <name> <owner/repo> <asset-regex> <checkbin>
  local name="$1" repo="$2" regex="$3" checkbin="$4"
  local latest current url f
  latest="$(gh_latest_tag "$repo")"
  if [ -z "$latest" ]; then warn "$name: could not query latest release — skipping"; return 1; fi
  current="$(get_recorded_version "$name")"
  gh_should_install "$name" "$checkbin" "$latest" "$current" || return 0

  url="$(gh_asset_url "$repo" "$regex")"
  if [ -z "$url" ]; then warn "$name: no .deb asset matched /$regex/ — skipping"; return 1; fi

  info "Installing $name $latest"
  f="$TMP_BASE/$name.deb"
  download "$url" "$f" || { warn "$name: download failed"; return 1; }
  "${APT[@]}" install -y "$f" || $SUDO dpkg -i "$f" || { warn "$name: install failed"; return 1; }
  record_version "$name" "$latest"
  ok "$name $latest installed"
}

# ---------------------------------------------------------------------------
# apt helpers
# ---------------------------------------------------------------------------
apt_install() {
  local pkg
  for pkg in "$@"; do
    if [ "$MODE" = "install" ] && dpkg -s "$pkg" >/dev/null 2>&1; then
      info "$pkg already installed"
    else
      "${APT[@]}" install -y "$pkg" || warn "failed to install $pkg"
    fi
  done
}

# ---------------------------------------------------------------------------
# Phase 0: preflight
# ---------------------------------------------------------------------------
preflight() {
  section "Pre-flight checks"

  if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
    info "Running as root."
  else
    SUDO="sudo"
    have sudo || { error "Not root and 'sudo' is not installed. Re-run as root."; exit 1; }
    info "Running as $(id -un); validating sudo..."
    sudo -v || { error "sudo authentication failed."; exit 1; }
  fi

  if [ -n "$SUDO" ]; then
    APT=(sudo env DEBIAN_FRONTEND=noninteractive apt-get)
  else
    APT=(env DEBIAN_FRONTEND=noninteractive apt-get)
  fi

  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
  fi
  if [ "${ID:-}" != "ubuntu" ] && [[ ",${ID_LIKE:-}," != *",ubuntu,"* ]]; then
    warn "This does not look like Ubuntu (ID=${ID:-unknown}). Proceeding anyway, but apt sources are tuned for Ubuntu."
  else
    ok "Ubuntu ${VERSION_ID:-} detected."
  fi

  case "$(uname -m)" in
    x86_64|amd64)  RUST_ARCH=x86_64;  DEB_ARCH=amd64; LAZYGIT_ARCH=x86_64 ;;
    aarch64|arm64) RUST_ARCH=aarch64; DEB_ARCH=arm64; LAZYGIT_ARCH=arm64  ;;
    *) error "Unsupported architecture: $(uname -m)"; exit 1 ;;
  esac
  info "Architecture: $(uname -m) (rust=$RUST_ARCH deb=$DEB_ARCH)"

  info "Installing prerequisites..."
  "${APT[@]}" update -y || warn "initial apt update failed"
  apt_install curl wget git unzip tar ca-certificates gnupg software-properties-common
  $SUDO add-apt-repository -y universe >/dev/null 2>&1 || warn "could not ensure 'universe' repo"
  mkdir -p "$LOCAL_BIN"
}

# ---------------------------------------------------------------------------
# Phase 1: system update
# ---------------------------------------------------------------------------
system_update() {
  section "System update"
  info "Refreshing package lists..."
  "${APT[@]}" update -y
  info "Applying full-upgrade (this can take a while)..."
  "${APT[@]}" -y full-upgrade
  info "Removing unused packages..."
  "${APT[@]}" -y autoremove --purge
  ok "System updated."
}

# ---------------------------------------------------------------------------
# Phase 2: tools from the standard Ubuntu repositories
# ---------------------------------------------------------------------------
APT_TOOLS=(fzf ripgrep jq bat fd-find zoxide ncdu duf btop httpie tealdeer)

install_apt_tools() {
  section "Installing apt tools"
  "${APT[@]}" update -y || warn "apt update failed"
  apt_install "${APT_TOOLS[@]}"
  ensure_local_symlinks
}

ensure_local_symlinks() {
  # On Debian/Ubuntu these ship under alternate names to avoid clashes.
  mkdir -p "$LOCAL_BIN"
  [ -x /usr/bin/batcat ] && ln -sf /usr/bin/batcat "$LOCAL_BIN/bat"
  [ -x /usr/bin/fdfind ] && ln -sf /usr/bin/fdfind "$LOCAL_BIN/fd"
  return 0
}

# ---------------------------------------------------------------------------
# Phase 3: tools from added PPA / apt repositories
# ---------------------------------------------------------------------------
install_repo_tools() {
  section "Installing Neovim (unstable PPA) and eza"

  info "Adding neovim-ppa/unstable..."
  $SUDO add-apt-repository -y ppa:neovim-ppa/unstable || warn "could not add Neovim PPA"

  if [ ! -f /etc/apt/sources.list.d/gierens.list ]; then
    info "Adding eza apt repository..."
    $SUDO mkdir -p /etc/apt/keyrings
    if curl -fsSL https://raw.githubusercontent.com/eza-community/eza/main/deb.asc \
         | $SUDO gpg --dearmor -o /etc/apt/keyrings/gierens.gpg; then
      echo "deb [signed-by=/etc/apt/keyrings/gierens.gpg] http://deb.gierens.de stable main" \
        | $SUDO tee /etc/apt/sources.list.d/gierens.list >/dev/null
      $SUDO chmod 644 /etc/apt/keyrings/gierens.gpg /etc/apt/sources.list.d/gierens.list
    else
      warn "could not add eza repository key"
    fi
  fi

  "${APT[@]}" update -y || warn "apt update failed"
  apt_install neovim eza
}

# ---------------------------------------------------------------------------
# Phase 4: tools from GitHub releases / official installers
# ---------------------------------------------------------------------------
install_gh_tools() {
  section "Installing tools from GitHub releases"

  # oh-my-posh — official installer into ~/.local/bin (handles arch + upgrades).
  if [ "$MODE" = "install" ] && have oh-my-posh; then
    info "oh-my-posh already installed — skipping"
  else
    info "Installing/updating oh-my-posh..."
    curl -fsSL https://ohmyposh.dev/install.sh | bash -s -- -d "$LOCAL_BIN" \
      || warn "oh-my-posh install failed"
  fi
  mkdir -p "$HOME/.config/oh-my-posh"
  if [ ! -f "$HOME/.config/oh-my-posh/theme.omp.json" ] || [ "$MODE" = "update" ]; then
    download "https://raw.githubusercontent.com/JanDeDobbeleer/oh-my-posh/main/themes/${OMP_THEME}.omp.json" \
      "$HOME/.config/oh-my-posh/theme.omp.json" || warn "oh-my-posh theme download failed"
  fi

  # bash-preexec — required by atuin's bash integration.
  if [ ! -f "$HOME/.bash-preexec.sh" ] || [ "$MODE" = "update" ]; then
    download "https://raw.githubusercontent.com/rcaloras/bash-preexec/master/bash-preexec.sh" \
      "$HOME/.bash-preexec.sh" || warn "bash-preexec download failed"
  fi

  # Single-binary tarballs / zips
  install_gh_tarball zellij    zellij-org/zellij    "zellij-${RUST_ARCH}-unknown-linux-musl\.tar\.gz$"        zellij    || true
  install_gh_tarball lazygit   jesseduffield/lazygit "lazygit_.*_Linux_${LAZYGIT_ARCH}\.tar\.gz$"            lazygit   || true
  install_gh_tarball dust      bootandy/dust        "dust-.*-${RUST_ARCH}-unknown-linux-gnu\.tar\.gz$"        dust      || true
  install_gh_tarball procs     dalance/procs        "procs-.*-${RUST_ARCH}-linux\.zip$"                       procs     || true
  install_gh_tarball bandwhich imsnif/bandwhich     "bandwhich-.*-${RUST_ARCH}-unknown-linux-musl\.tar\.gz$"  bandwhich || true
  install_gh_tarball yazi      sxyazi/yazi          "yazi-${RUST_ARCH}-unknown-linux-musl\.zip$"              yazi ya   || true
  install_gh_tarball atuin     atuinsh/atuin        "atuin-.*${RUST_ARCH}-unknown-linux-gnu\.tar\.gz$"        atuin     || true

  # .deb package
  install_gh_deb     git-delta dandavison/delta     "git-delta_.*_${DEB_ARCH}\.deb$"                          delta     || true
}

# ---------------------------------------------------------------------------
# Phase 5: shell integration (managed block in ~/.bashrc)
# ---------------------------------------------------------------------------
bashrc_block() {
  # Single-quoted heredoc keeps $HOME/$(...) literal for runtime; @TOKENS@ are
  # substituted here so script-time config (e.g. BAT_THEME_NAME) lands in the file.
  cat <<'BLOCK' | sed "s|@BAT_THEME@|${BAT_THEME_NAME}|g"
# >>> server-setup >>>
# Managed by setup.sh — do not edit between these markers (re-run regenerates).

# Local bin (oh-my-posh, bat, fd symlinks, etc.)
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac

export EDITOR=nvim
export VISUAL=nvim
export BAT_THEME="@BAT_THEME@"

# fzf options
export FZF_DEFAULT_OPTS="--height 40% --layout=reverse --border --info=inline"
if command -v fd >/dev/null 2>&1; then
  export FZF_DEFAULT_COMMAND='fd --type f --hidden --follow --exclude .git'
  export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
  export FZF_ALT_C_COMMAND='fd --type d --hidden --follow --exclude .git'
fi

# oh-my-posh prompt
if command -v oh-my-posh >/dev/null 2>&1; then
  eval "$(oh-my-posh init bash --config "$HOME/.config/oh-my-posh/theme.omp.json")"
fi

# zoxide (smarter cd: use `z <dir>`, `zi` for interactive)
command -v zoxide >/dev/null 2>&1 && eval "$(zoxide init bash)"

# fzf key bindings & completion (Ctrl-T files, Alt-C cd, Ctrl-R is handled by atuin below)
if command -v fzf >/dev/null 2>&1; then
  if fzf --bash >/dev/null 2>&1; then
    eval "$(fzf --bash)"
  else
    [ -f /usr/share/doc/fzf/examples/key-bindings.bash ] && source /usr/share/doc/fzf/examples/key-bindings.bash
    [ -f /usr/share/bash-completion/completions/fzf ] && source /usr/share/bash-completion/completions/fzf
  fi
fi

# atuin — sourced AFTER fzf so it owns Ctrl-R (richer history search)
[ -f "$HOME/.bash-preexec.sh" ] && source "$HOME/.bash-preexec.sh"
command -v atuin >/dev/null 2>&1 && eval "$(atuin init bash)"

# Aliases (interactive only — scripts are unaffected)
if command -v eza >/dev/null 2>&1; then
  alias ls='eza --group-directories-first --icons=auto'
  alias ll='eza -lh --group-directories-first --icons=auto'
  alias la='eza -lah --group-directories-first --icons=auto'
  alias lt='eza --tree --level=2 --icons=auto'
fi
command -v bat    >/dev/null 2>&1 && alias cat='bat --paging=never'
command -v nvim   >/dev/null 2>&1 && { alias vi='nvim'; alias vim='nvim'; }
command -v lazygit>/dev/null 2>&1 && alias lg='lazygit'
command -v btop   >/dev/null 2>&1 && alias top='btop'
command -v duf    >/dev/null 2>&1 && alias df='duf'
command -v zellij >/dev/null 2>&1 && alias zj='zellij'
# <<< server-setup <<<
BLOCK
}

configure_shell() {
  section "Configuring ~/.bashrc"
  local rc="$HOME/.bashrc"
  touch "$rc"
  if grep -qF "$BEGIN_MARK" "$rc"; then
    info "Refreshing existing managed block..."
    sed -i "\|$BEGIN_MARK|,\|$END_MARK|d" "$rc"
  else
    info "Adding managed block..."
  fi
  # Trim trailing blank lines, then append a clean block.
  printf '\n%s\n' "$(bashrc_block)" >> "$rc"
  # shellcheck disable=SC2088  # literal text in a log message, not a path argument
  ok "~/.bashrc updated."
}

# ---------------------------------------------------------------------------
# Phase 6: per-tool configuration
# ---------------------------------------------------------------------------
configure_tools() {
  section "Per-tool configuration"

  if have delta; then
    info "Configuring git to use delta..."
    git config --global core.pager delta
    git config --global interactive.diffFilter "delta --color-only"
    git config --global delta.navigate true
    git config --global delta.side-by-side true
    git config --global merge.conflictStyle zdiff3
  fi

  if have tldr; then
    info "Seeding tldr cache..."
    tldr --update >/dev/null 2>&1 || warn "tldr cache update failed"
  fi

  if have atuin; then
    info "Importing existing shell history into atuin (local only)..."
    atuin import auto >/dev/null 2>&1 || warn "atuin history import skipped"
  fi
}

# ---------------------------------------------------------------------------
# Phase 7: summary + reboot
# ---------------------------------------------------------------------------
ver() {
  # ver <label> <binary>
  if have "$2"; then
    printf '  %-12s %s\n' "$1" "$("$2" --version 2>/dev/null | head -n1)"
  else
    printf '  %-12s %s\n' "$1" "(not found)"
  fi
}

print_summary() {
  section "Installed tool versions"
  ver "neovim"    nvim
  ver "oh-my-posh" oh-my-posh
  ver "fzf"       fzf
  ver "ripgrep"   rg
  ver "jq"        jq
  ver "bat"       bat
  ver "fd"        fd
  ver "zoxide"    zoxide
  ver "zellij"    zellij
  ver "eza"       eza
  ver "lazygit"   lazygit
  ver "delta"     delta
  ver "dust"      dust
  ver "duf"       duf
  ver "ncdu"      ncdu
  ver "btop"      btop
  ver "procs"     procs
  ver "bandwhich" bandwhich
  ver "yazi"      yazi
  ver "atuin"     atuin
  ver "tldr"      tldr
  ver "httpie"    http

  cat <<EOF

${C_BOLD}Next steps${C_RESET}
  1. Start a fresh shell to load everything:  ${C_GREEN}exec bash${C_RESET}
  2. Try it out:  z <dir> (zoxide), Ctrl-R (atuin), Ctrl-T (fzf), ls (eza), lg (lazygit), yazi
  3. ${C_BOLD}Nerd Font:${C_RESET} prompt/eza/btop glyphs render with YOUR terminal's font, not the
     server's. Install a Nerd Font locally (e.g. MesloLGS NF) and select it in your
     terminal emulator, otherwise icons show as boxes.
EOF
}

maybe_reboot() {
  if [ "$DO_REBOOT" -ne 1 ]; then
    section "Done"
    ok "Reboot skipped (--no-reboot). Reboot manually when ready: ${C_BOLD}$SUDO reboot${C_RESET}"
    return 0
  fi

  section "Reboot"
  # Only offer an interactive cancel when stdin is a terminal. A non-interactive
  # run (e.g. piped from curl) has no keyboard, so 'read -t' would return failure
  # instantly and reboot with no chance to abort — require an explicit countdown.
  if [ ! -t 0 ]; then
    warn "Non-interactive session — not rebooting automatically to avoid surprises."
    ok "Reboot manually when ready: ${C_BOLD}$SUDO reboot${C_RESET}"
    return 0
  fi

  printf '%sRebooting in 10 seconds — press any key to cancel...%s ' "$C_YELLOW" "$C_RESET"
  if read -rs -n1 -t 10 _key; then
    printf '\n'
    warn "Reboot cancelled."
    ok "Reboot manually when ready: ${C_BOLD}$SUDO reboot${C_RESET}"
  else
    printf '\n'
    info "Rebooting now."
    $SUDO reboot
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --update)      MODE="update" ;;
      --no-reboot)   DO_REBOOT=0 ;;
      --skip-update) DO_SYSTEM_UPDATE=0 ;;
      -h|--help)     usage; exit 0 ;;
      *) error "Unknown option: $1"; echo; usage; exit 1 ;;
    esac
    shift
  done
}

main() {
  parse_args "$@"
  preflight

  if [ "$MODE" = "update" ]; then
    section "Maintenance update mode"
    system_update
    ensure_local_symlinks
    install_repo_tools
    install_gh_tools
    configure_shell
    configure_tools
    print_summary
    section "Done"
    ok "Update complete. Run 'exec bash' to reload your shell. No reboot performed."
    return 0
  fi

  # Full install
  if [ "$DO_SYSTEM_UPDATE" -eq 1 ]; then
    system_update
  else
    warn "Skipping system update (--skip-update)."
  fi
  install_apt_tools
  install_repo_tools
  install_gh_tools
  configure_shell
  configure_tools
  print_summary
  maybe_reboot
}

main "$@"
