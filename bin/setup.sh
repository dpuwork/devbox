#!/usr/bin/env bash
# bin/setup.sh
# Native Userspace Devbox Provisioner
# Replicates the Omaterm stack & onboarding direct-to-host without virtualization layers.
set -euo pipefail

# --- Pipe Re-execution Wrapper ---
# Detect if the script is being piped (e.g., curl | bash) and re-execute with stdin from /dev/tty
if [[ -z "${BASH_SOURCE[0]:-}" ]]; then
  if [ -r /dev/tty ]; then
    TEMP_SCRIPT="$(mktemp /tmp/setup-XXXXXX.sh)"
    cat > "$TEMP_SCRIPT"
    exec bash "$TEMP_SCRIPT" "$@" < /dev/tty
  fi
fi

# Self-cleanup if running the temporary setup script
if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" == /tmp/setup-* ]]; then
  trap 'rm -f "${BASH_SOURCE[0]}"' EXIT
fi

# Fallback to xterm-256color if the current TERM's terminfo is missing on this host
if command -v infocmp &>/dev/null && ! infocmp "${TERM:-}" &>/dev/null; then
  export TERM=xterm-256color
fi

# Ensure we are running on a Debian or Ubuntu system
if [ ! -f /etc/debian_version ]; then
  echo "Error: This script only supports Debian or Ubuntu systems." >&2
  exit 1
fi

DEVBOX_BIN_DIR="$HOME/.local/bin"
DEVBOX_STATE_DIR="$HOME/.local/state/devbox"
SETUP_DONE_MARKER="$DEVBOX_STATE_DIR/setup-done"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"


export PATH="$DEVBOX_BIN_DIR:$PATH"

# Ensure crucial directories exist
mkdir -p "$DEVBOX_BIN_DIR" "$DEVBOX_STATE_DIR" "$HOME/.config"

# --- UI Helpers ---

section() {
  echo -e "\n\033[1;34m==>\033[0m \033[1m$1\033[0m"
}

run_with_spinner() {
  local title="$1"
  shift

  if command -v gum &>/dev/null; then
    gum spin --spinner="dot" --title="$title" --show-error -- "$@"
  else
    echo "==> $title"
    "$@"
  fi
}

sudo_preflight() {
  if ! sudo -v; then
    echo "Error: sudo authentication failed." >&2
    exit 1
  fi
}

latest_github_release() {
  local repo="$1" fallback="${2:-}" tag=""

  if command -v jq &>/dev/null; then
    tag="$(curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null || true)"
  else
    tag="$(curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null | grep -o '"tag_name": *"[^"]*"' | cut -d'"' -f4 || true)"
  fi

  tag="${tag#v}"
  if [[ -z "$tag" || "$tag" == "null" ]]; then
    tag="$fallback"
  fi

  printf '%s\n' "$tag"
}


# --- Onboarding Prompts (Interrupt/Trap safe) ---
finish_from_interrupt() {
  echo -e "\n\033[1;31mOnboarding cancelled by user.\033[0m"
  exit 130
}

gum_input_into() {
  local -n target="$1"
  local value status
  shift

  set +e
  trap : INT
  value="$(gum input "$@" </dev/tty)"
  status=$?
  trap - INT
  set -e

  if (( status != 0 )); then
    target=""
    finish_from_interrupt
  fi

  target="$value"
}


gum_confirm() {
  local status interrupted=0

  set +e
  trap 'interrupted=1' INT
  gum confirm "$@" </dev/tty
  status=$?
  trap - INT
  set -e

  if (( interrupted || status == 130 || status > 1 )); then
    return 130
  fi

  return "$status"
}

# --- Step 1: Install System Dependencies ---
install_system_dependencies() {
  section "Checking system package prerequisites..."
  local deps=(git curl jq openssh-client build-essential unzip zsh xclip)
  local missing=()

  for dep in "${deps[@]}"; do
    if [ "$dep" = "openssh-client" ] && ! command -v ssh &>/dev/null; then
      missing+=("$dep")
    elif ! command -v "$dep" &>/dev/null && [ "$dep" != "build-essential" ] && [ "$dep" != "openssh-client" ]; then
      missing+=("$dep")
    elif [ "$dep" = "build-essential" ] && ! dpkg -l | grep -q build-essential 2>/dev/null; then
      missing+=("build-essential")
    fi
  done

  if ((${#missing[@]} > 0)); then
    sudo_preflight
    run_with_spinner "Updating system package repositories..." sudo apt-get update -y
    run_with_spinner "Installing missing system packages (${missing[*]})..." sudo apt-get install -y "${missing[@]}"
  else
    echo "✓ Core system packages already present."
  fi
}

# --- Step 1.5: Install Latest TMUX from Source ---
install_latest_tmux() {
  local current_version=""
  if command -v tmux &>/dev/null; then
    current_version="$(tmux -V 2>/dev/null | awk '{print $2}' || true)"
  fi

  local latest_version
  latest_version="$(latest_github_release tmux/tmux 3.7b)"

  if [[ -n "$current_version" ]]; then
    # If the current version is already >= the latest version, skip the rebuild.
    if [ "$(printf '%s\n' "$latest_version" "$current_version" | sort -V | head -n1)" = "$latest_version" ]; then
      echo "✓ TMUX $current_version (>= $latest_version) is already installed."
      return 0
    fi
  fi

  section "Installing latest TMUX from source (v${latest_version})..."
  
  # Install build dependencies for compiling tmux
  sudo_preflight
  run_with_spinner "Installing TMUX build dependencies..." \
    sudo apt-get install -y libevent-dev libncurses-dev bison pkg-config

  local temp_dir
  temp_dir="$(mktemp -d)"

  run_with_spinner "Downloading TMUX v${latest_version} source..." \
    curl -fsSL "https://github.com/tmux/tmux/releases/download/${latest_version}/tmux-${latest_version}.tar.gz" -o "$temp_dir/tmux-${latest_version}.tar.gz"

  run_with_spinner "Extracting TMUX source..." \
    tar -xzf "$temp_dir/tmux-${latest_version}.tar.gz" -C "$temp_dir"

  # Run configuration and build inside the temp directory
  (
    cd "$temp_dir/tmux-${latest_version}"
    run_with_spinner "Configuring TMUX..." ./configure --prefix="$HOME/.local"
    run_with_spinner "Compiling TMUX..." make -j"$(nproc 2>/dev/null || echo 2)"
    run_with_spinner "Installing TMUX to userspace..." make install
  )

  rm -rf "$temp_dir"
  
  # Verify installation
  if [ -f "$DEVBOX_BIN_DIR/tmux" ]; then
    local new_ver
    new_ver="$("$DEVBOX_BIN_DIR/tmux" -V)"
    echo "✓ TMUX $new_ver successfully installed to $DEVBOX_BIN_DIR/tmux"
  else
    echo "Error: TMUX installation failed." >&2
    exit 1
  fi
}



# --- Step 2: Install userspace Gum CLI ---
install_gum() {
  if command -v gum &>/dev/null; then
    return
  fi

  section "Installing Gum CLI..."
  local temp_dir os arch download_url latest_version
  temp_dir="$(mktemp -d)"
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"

  case "$arch" in
    x86_64) arch="x86_64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) echo "Unsupported architecture: $arch"; exit 1 ;;
  esac

  latest_version="$(latest_github_release charmbracelet/gum)"
  if [[ -z "$latest_version" ]]; then
    echo "Error: Could not determine latest Gum release version." >&2
    exit 1
  fi
  download_url="https://github.com/charmbracelet/gum/releases/download/v${latest_version}/gum_${latest_version}_${os}_${arch}.tar.gz"
  
  curl -fsSL "$download_url" | tar -xz -C "$temp_dir"
  find "$temp_dir" -type f -name "gum" -exec mv {} "$DEVBOX_BIN_DIR/gum" \;
  chmod +x "$DEVBOX_BIN_DIR/gum"
  rm -rf "$temp_dir"
  echo "✓ Gum installed successfully to $DEVBOX_BIN_DIR"
}

# --- Step 3: Bootstrap Omadots ---
install_omadots() {
  section "Checking Omadots status..."
  if [ ! -d "$HOME/.local/share/omadots" ]; then
    run_with_spinner "Installing Omadots configuration..." bash -c 'curl -fsSL https://raw.githubusercontent.com/omacom-io/omadots/refs/heads/master/install.sh | bash'
  else
    echo "✓ Omadots configuration present."
  fi
}

# --- Step 4: Bootstrap Mise & Install Development Stack ---
install_mise_and_tools() {
  section "Checking Mise runtime manager..."
  if ! command -v mise &>/dev/null; then
    run_with_spinner "Bootstrapping Mise runtime manager locally..." bash -c 'curl https://mise.jdx.dev/install.sh | sh'
  fi

  # Activate mise for the remainder of this setup session
  export PATH="$HOME/.local/share/mise/shims:$HOME/.local/share/mise/bin:$PATH"
  eval "$(mise activate bash)"

  section "Ensuring standard terminal tools and AI shims..."
  
  # Core terminal utilities (Mise compiles/grabs binaries directly)
  run_with_spinner "Installing core terminal utilities (neovim, python, node, lazygit, fzf, etc.)..." mise use -g -y neovim starship eza zoxide fzf gh lazygit lazydocker node python

  # AI Tooling & Shims
  run_with_spinner "Installing AI tooling and devbox shims (claude-code, codex, hunk, paseo)..." \
    mise use -g -y opencode claude-code codex antigravity-cli npm:@getpaseo/cli aqua:modem-dev/hunk

  # Sync shims to ensure they are available in the PATH
  run_with_spinner "Finalizing tools configuration..." bash -c 'mise reshim && mise install'
}

# --- Step 5: Mirror Configuration Profiles ---
provision_configurations() {
  section "Mirroring Devbox configuration parameters..."
  
  # Copy Starship configurations from repo
  if [ -f "$REPO_ROOT/config/starship.toml" ]; then
    mkdir -p "$HOME/.config"
    cp -Rf "$REPO_ROOT/config/starship.toml" "$HOME/.config/starship.toml"
    echo "✓ Starship configuration copied successfully."
  else
    echo "Warning: Repository starship.toml configuration not found. Skipping configuration seeding."
  fi

  # Apply local TMUX patch on top of omadots
  if [ -f "$REPO_ROOT/config/tmux.conf" ]; then
    mkdir -p "$HOME/.config/tmux"
    touch "$HOME/.config/tmux/tmux.conf"
    
    if ! grep -q "Custom Devbox TMUX Additions" "$HOME/.config/tmux/tmux.conf" 2>/dev/null; then
      cat "$REPO_ROOT/config/tmux.conf" >> "$HOME/.config/tmux/tmux.conf"
      echo "✓ Custom TMUX patch applied on top of omadots configuration."
    else
      echo "✓ Custom TMUX patch already applied."
    fi
  fi
}

# --- Step 6: Onboarding Flows (Interactive) ---
onboard_git() {
  local name="" email=""
  
  name="$(git config --global user.name 2>/dev/null || true)"
  email="$(git config --global user.email 2>/dev/null || true)"

  if [[ -n $name && -n $email ]]; then
    echo "✓ Git identity already configured."
    return 0
  fi

  if gum_confirm "Configure Git identity?"; then
    while [[ -z $name ]]; do
      gum_input_into name --prompt "[git] user.name: " --value "$name"
    done
    while [[ -z $email ]]; do
      gum_input_into email --prompt "[git] user.email: " --value "$email"
    done
    git config --global user.name "$name"
    git config --global user.email "$email"
    echo "✓ Git identity configured."
  else
    local status=$?
    if (( status == 130 )); then
      finish_from_interrupt
    fi
  fi
}

onboard_github() {
  if gh auth status &>/dev/null; then
    echo "✓ GitHub authenticated."
    return 0
  fi

  if gum_confirm "Authenticate with GitHub?"; then
    echo "Authenticating GitHub..."
    gh auth login </dev/tty
  else
    local status=$?
    if (( status == 130 )); then
      finish_from_interrupt
    fi
  fi
}

onboard_tailscale() {
  if command -v tailscale &>/dev/null && tailscale status &>/dev/null; then
    echo "✓ Tailscale connected."
    if sudo -n true &>/dev/null; then
      sudo tailscale set --ssh
    fi
    return 0
  fi

  # Skip Tailscale if we cannot act as root
  if ! sudo -n true &>/dev/null; then
    return 0
  fi

  if gum_confirm "Connect to Tailscale VPN on this VM?"; then
    if ! command -v tailscale &>/dev/null; then
      curl -fsSL https://tailscale.com/install.sh | sh
    fi
    local host_name
    host_name="$(hostname)"
    gum_input_into host_name --prompt "[tailscale] hostname: " --value "$host_name"
    sudo tailscale up --ssh --accept-routes --hostname "$host_name"
    sudo tailscale set --ssh
  else
    local status=$?
    if (( status == 130 )); then
      finish_from_interrupt
    fi
  fi
}

# --- Step 7: Shell Profile Integration ---
configure_shell_integration() {
  section "Applying userspace shell profile additions..."
  local shell_rcs=("$HOME/.bashrc" "$HOME/.zshrc")

  for rc in "${shell_rcs[@]}"; do
    # Ensure file exists
    touch "$rc"

    # Remove any existing Devbox integration block to allow clean upgrades/updates
    if sed --version 2>&1 | grep -q GNU; then
      sed -i '/# --- Devbox Shell Integrations ---/,/# --- End Devbox Shell Integrations ---/d' "$rc"
    else
      sed -i '' '/# --- Devbox Shell Integrations ---/,/# --- End Devbox Shell Integrations ---/d' "$rc"
    fi

    # Append fresh integrations at the end of the file
    local sh_name="bash"
    [[ "$rc" == *zshrc ]] && sh_name="zsh"

    cat >> "$rc" <<EOF

# --- Devbox Shell Integrations ---
# Fallback to xterm-256color if the current TERM's terminfo is missing on this host
if command -v infocmp &>/dev/null && ! infocmp "\${TERM:-}" &>/dev/null; then
  export TERM=xterm-256color
fi

export PATH="\$HOME/.local/bin:\$PATH"

# Activate Mise environment manager
if command -v mise &>/dev/null; then
  eval "\$(mise activate $sh_name)"
fi

# Clipboard alias
alias pbcopy='xclip -selection clipboard'

# Auto-launch TMUX for interactive incoming SSH sessions
if [[ \$- == *i* && -t 0 && -t 1 && -z "\$TMUX" && -n "\${SSH_CONNECTION:-}" ]]; then
  tmux attach-session -t devbox 2>/dev/null || tmux new-session -s devbox
fi
# --- End Devbox Shell Integrations ---
EOF
  done
  echo "✓ Shell profile integrations configured."
}

# --- Step 8: Switch default shell to Zsh ---
switch_to_zsh() {
  if [ "${SHELL##*/}" = "zsh" ]; then
    echo "✓ Default shell is already ZSH."
    return 0
  fi

  local zsh_path
  zsh_path="$(command -v zsh || true)"
  if [ -z "$zsh_path" ]; then
    echo "Warning: ZSH is not installed. Cannot switch shell." >&2
    return 1
  fi

  section "Switching default shell to ZSH..."
  if sudo -n true 2>/dev/null; then
    sudo chsh -s "$zsh_path" "$USER"
    echo "✓ Default shell changed to Zsh."
  else
    echo "Attempting to change default shell to Zsh (may prompt for password)..."
    if chsh -s "$zsh_path"; then
      echo "✓ Default shell changed to Zsh."
    else
      echo "Warning: Failed to change default shell automatically. Please run 'chsh -s $zsh_path' manually." >&2
    fi
  fi
}

# --- Execution Pipeline ---
echo "[dpu/devbox] setup v0.0.6"
install_system_dependencies
install_gum
install_latest_tmux
install_omadots
install_mise_and_tools
provision_configurations

# Onboarding UX Elements
if [ ! -f "$SETUP_DONE_MARKER" ]; then
  onboard_git
  onboard_github
  onboard_tailscale
  if gum_confirm "Mark onboarding complete and skip these prompts next time?"; then
    touch "$SETUP_DONE_MARKER"
  else
    status=$?
    if (( status == 130 )); then
      finish_from_interrupt
    fi
  fi
fi

configure_shell_integration
switch_to_zsh

section "Devbox userspace configuration successfully completed!"
echo -e "\033[1;32m✓ Setup finished. Run 'source ~/.zshrc' (or reconnect) to load all tools (e.g., eza, starship, nvim, fzf).\033[0m"
