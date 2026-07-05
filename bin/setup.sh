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
  local deps=(git curl jq tmux openssh-client build-essential unzip)
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
  local shell_rcs=("$HOME/.bashrc")
  [ -f "$HOME/.zshrc" ] && shell_rcs+=("$HOME/.zshrc")

  for rc in "${shell_rcs[@]}"; do
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

# Auto-launch TMUX for interactive incoming SSH sessions
if [[ -z "\$TMUX" && -n "\${SSH_CONNECTION:-}" ]]; then
  tmux attach-session -t devbox 2>/dev/null || tmux new-session -s devbox
fi
EOF
    fi
  done
  echo "✓ Shell profile integrations configured."
}

# --- Execution Pipeline ---
echo "[dpu/devbox] setup v0.0.2"
install_gum
install_system_dependencies
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

section "Devbox userspace configuration successfully completed!"
echo -e "\033[1;32m✓ Setup finished. Run 'source ~/.bashrc' or reconnect to launch your devbox TMUX window.\033[0m"
