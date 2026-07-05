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
    if ! command -v "$dep" &>/dev/null && [ "$dep" != "build-essential" ]; then
      missing+=("$dep")
    elif [ "$dep" = "build-essential" ] && ! dpkg -l | grep -q build-essential 2>/dev/null; then
      missing+=("build-essential")
    fi
  done

  if ((${#missing[@]} > 0)); then
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
    current_version="$(tmux -V 2>/dev/null | cut -d' ' -f2 | sed 's/[^0-9.]//g' || true)"
  fi

  if [[ -n "$current_version" ]]; then
    # We want at least v3.5
    if [ "$(printf '%s\n' "3.5" "$current_version" | sort -V | head -n1)" = "3.5" ]; then
      echo "✓ TMUX $current_version (>= 3.5) is already installed."
      return 0
    fi
  fi

  section "Installing latest TMUX from source (v3.5a)..."
  
  # Install build dependencies for compiling tmux
  run_with_spinner "Installing TMUX build dependencies..." \
    sudo apt-get install -y libevent-dev libncurses-dev bison pkg-config

  local temp_dir
  temp_dir="$(mktemp -d)"

  run_with_spinner "Downloading TMUX v3.5a source..." \
    curl -fsSL https://github.com/tmux/tmux/releases/download/3.5a/tmux-3.5a.tar.gz -o "$temp_dir/tmux-3.5a.tar.gz"

  run_with_spinner "Extracting TMUX source..." \
    tar -xzf "$temp_dir/tmux-3.5a.tar.gz" -C "$temp_dir"

  # Run configuration and build inside the temp directory
  (
    cd "$temp_dir/tmux-3.5a"
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

  if command -v jq &>/dev/null; then
    latest_version="$(curl -fsSL https://api.github.com/repos/charmbracelet/gum/releases/latest | jq -r .tag_name | sed 's/^v//')"
  else
    latest_version="$(curl -fsSL https://api.github.com/repos/charmbracelet/gum/releases/latest | grep -o '"tag_name": *"[^"]*"' | cut -d'"' -f4 | sed 's/^v//')"
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
  run_with_spinner "Installing AI tooling and devbox shims (claude-code, codex, hunk)..." mise use -g -y opencode claude-code codex antigravity-cli aqua:modem-dev/hunk

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
  fi
}

# --- Step 7: Shell Profile Integration ---
configure_shell_integration() {
  section "Applying userspace shell profile additions..."
  local shell_rcs=("$HOME/.bashrc" "$HOME/.zshrc")

  for rc in "${shell_rcs[@]}"; do
    # Ensure file exists
    touch "$rc"
    # Add PATH configurations
    if ! grep -q 'Devbox Shell Integrations' "$rc" 2>/dev/null; then
      local sh_name="bash"
      [[ "$rc" == *zshrc ]] && sh_name="zsh"

      cat >> "$rc" <<EOF

# --- Devbox Shell Integrations ---
# Fallback to xterm-256color if the current TERM's terminfo is missing on this host
if command -v infocmp &>/dev/null && ! infocmp "\${TERM:-}" &>/dev/null; then
  export TERM=xterm-256color
fi

export PATH="\$HOME/.local/bin:\$PATH"

if [ -d "\$HOME/.local/share/mise/bin" ]; then
  export PATH="\$HOME/.local/share/mise/bin:\$PATH"
  eval "\$("\$HOME/.local/share/mise/bin/mise" activate $sh_name)"
fi

# Clipboard alias
alias pbcopy='xclip -selection clipboard'

# Auto-launch TMUX for interactive incoming SSH sessions
if [[ -z "\$TMUX" && -n "\${SSH_CONNECTION:-}" ]]; then
  tmux attach-session -t devbox 2>/dev/null || tmux new-session -s devbox
fi
EOF
    else
      # Ensure pbcopy alias is present even on upgraded installs
      if ! grep -q "alias pbcopy=" "$rc" 2>/dev/null; then
        cat >> "$rc" <<EOF

# Clipboard alias added in setup v0.0.4
alias pbcopy='xclip -selection clipboard'
EOF
      fi
    fi
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
echo "[dpu/devbox] setup v0.0.4"
install_gum
install_system_dependencies
install_latest_tmux
install_omadots
install_mise_and_tools
provision_configurations

# Onboarding UX Elements
if [ ! -f "$SETUP_DONE_MARKER" ]; then
  onboard_git
  onboard_github
  onboard_tailscale
  touch "$SETUP_DONE_MARKER"
fi

configure_shell_integration
switch_to_zsh

section "Devbox userspace configuration successfully completed!"
echo -e "\033[1;32m✓ Setup finished. Run 'source ~/.bashrc' (or reconnect) and start zsh to launch your devbox TMUX window.\033[0m"

