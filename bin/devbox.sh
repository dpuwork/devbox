#!/usr/bin/env bash
# Native userspace Devbox provisioner.
set -euo pipefail

DEVBOX_VERSION="0.0.14"

# Re-execute piped input with a terminal for interactive prompts.
if [[ -z "${BASH_SOURCE[0]:-}" ]]; then
  if [ -r /dev/tty ]; then
    TEMP_SCRIPT="$(mktemp /tmp/devbox-XXXXXX.sh)"
    cat > "$TEMP_SCRIPT"
    exec bash "$TEMP_SCRIPT" "$@" < /dev/tty
  fi
fi

CLEANUP_DIRS=()
TEMP_SCRIPT=""
if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" == /tmp/devbox-* ]]; then
  TEMP_SCRIPT="${BASH_SOURCE[0]}"
fi

cleanup() {
  local path

  if ((${#CLEANUP_DIRS[@]})); then
    for path in "${CLEANUP_DIRS[@]}"; do
      rm -rf "$path"
    done
  fi

  [[ -z $TEMP_SCRIPT ]] || rm -f "$TEMP_SCRIPT"
}

trap cleanup EXIT

# UI helpers.

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

ensure_docker_group() {
  local docker_gid command_line

  docker_gid="$(getent group docker 2>/dev/null | cut -d: -f3 || true)"
  [[ -n $docker_gid ]] || exec "$@"

  if id -G | grep -qw "$docker_gid"; then
    exec "$@"
  fi

  if ! command -v sg &>/dev/null; then
    echo "Warning: 'sg' is unavailable; the Docker group will take effect after re-login." >&2
    exec "$@"
  fi

  command_line="$(printf '%q ' "$@")"
  exec sg docker -c "$command_line"
}

latest_github_release() {
  local repo="$1" fallback="${2:-}" tag=""

  tag="$(curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null || true)"

  tag="${tag#v}"
  if [[ -z "$tag" || "$tag" == "null" ]]; then
    tag="$fallback"
  fi

  printf '%s\n' "$tag"
}


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

install_system_dependencies() {
  section "Checking system package prerequisites..."
  local deps=(git curl jq openssh-client build-essential unzip zsh xclip ca-certificates)

  # Installing existing packages also upgrades them on subsequent runs.
  sudo_preflight
  run_with_spinner "Updating system package repositories..." sudo apt-get update -y
  run_with_spinner "Installing/upgrading system packages (${deps[*]})..." sudo apt-get install -y "${deps[@]}"
}

install_latest_tmux() {
  local current_version=""
  if command -v tmux &>/dev/null; then
    current_version="$(tmux -V 2>/dev/null | awk '{print $2}' || true)"
  fi

  local latest_version
  latest_version="$(latest_github_release tmux/tmux 3.7b)"

  if [[ -n "$current_version" ]]; then
    if [ "$(printf '%s\n' "$latest_version" "$current_version" | sort -V | head -n1)" = "$latest_version" ]; then
      echo "✓ TMUX $current_version (>= $latest_version) is already installed."
      return 0
    fi
  fi

  section "Installing latest TMUX from source (v${latest_version})..."
  
  sudo_preflight
  run_with_spinner "Installing TMUX build dependencies..." \
    sudo apt-get install -y libevent-dev libncurses-dev bison pkg-config

  local temp_dir
  temp_dir="$(mktemp -d)"
  CLEANUP_DIRS+=("$temp_dir")

  run_with_spinner "Downloading TMUX v${latest_version} source..." \
    curl -fsSL "https://github.com/tmux/tmux/releases/download/${latest_version}/tmux-${latest_version}.tar.gz" -o "$temp_dir/tmux-${latest_version}.tar.gz"

  run_with_spinner "Extracting TMUX source..." \
    tar -xzf "$temp_dir/tmux-${latest_version}.tar.gz" -C "$temp_dir"

  (
    cd "$temp_dir/tmux-${latest_version}"
    run_with_spinner "Configuring TMUX..." ./configure --prefix="$HOME/.local"
    run_with_spinner "Compiling TMUX..." make -j"$(nproc 2>/dev/null || echo 2)"
    run_with_spinner "Installing TMUX to userspace..." make install
  )

  if [ -f "$DEVBOX_BIN_DIR/tmux" ]; then
    local new_ver
    new_ver="$("$DEVBOX_BIN_DIR/tmux" -V)"
    echo "✓ TMUX $new_ver successfully installed to $DEVBOX_BIN_DIR/tmux"
  else
    echo "Error: TMUX installation failed." >&2
    exit 1
  fi
}

install_docker_engine() {
  section "Checking Docker Engine (official CE repo)..."
  sudo_preflight

  local distro_id codename arch keyring
  distro_id="$(. /etc/os-release && echo "$ID")"
  codename="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"
  arch="$(dpkg --print-architecture)"
  keyring="/etc/apt/keyrings/docker.asc"

  if [ ! -f "$keyring" ]; then
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL "https://download.docker.com/linux/${distro_id}/gpg" -o "$keyring"
    sudo chmod a+r "$keyring"
  fi

  # Rewrite the repository entry so interrupted setups and distro upgrades recover.
  echo "deb [arch=${arch} signed-by=${keyring}] https://download.docker.com/linux/${distro_id} ${codename} stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

  # Reinstalling existing packages also upgrades Docker on subsequent runs.
  run_with_spinner "Updating package repositories..." sudo apt-get update -y
  run_with_spinner "Installing/upgrading Docker Engine, CLI, containerd, buildx, and compose plugin..." \
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  sudo systemctl enable --now docker
  sudo usermod -aG docker "$USER"
  echo "✓ Docker Engine running. $USER added to the docker group."
}


install_gum() {
  local current_version=""
  if command -v gum &>/dev/null; then
    current_version="$(gum --version 2>/dev/null | awk '{print $3}' || true)"
  fi

  local latest_version
  latest_version="$(latest_github_release charmbracelet/gum)"
  if [[ -z "$latest_version" ]]; then
    echo "Error: Could not determine latest Gum release version." >&2
    exit 1
  fi

  if [[ -n "$current_version" ]]; then
    if [ "$(printf '%s\n' "$latest_version" "$current_version" | sort -V | head -n1)" = "$latest_version" ]; then
      echo "✓ Gum $current_version (>= $latest_version) is already installed."
      return 0
    fi
  fi

  section "Installing Gum CLI (v${latest_version})..."
  local temp_dir os arch download_url
  temp_dir="$(mktemp -d)"
  CLEANUP_DIRS+=("$temp_dir")
  case "$(uname -s)" in
    Linux) os="Linux" ;;
    *) echo "Unsupported operating system: $(uname -s)" >&2; exit 1 ;;
  esac
  arch="$(uname -m)"

  case "$arch" in
    x86_64) arch="x86_64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) echo "Unsupported architecture: $arch"; exit 1 ;;
  esac

  download_url="https://github.com/charmbracelet/gum/releases/download/v${latest_version}/gum_${latest_version}_${os}_${arch}.tar.gz"

  curl -fsSL "$download_url" | tar -xz -C "$temp_dir"
  find "$temp_dir" -type f -name "gum" -exec mv {} "$DEVBOX_BIN_DIR/gum" \;
  chmod +x "$DEVBOX_BIN_DIR/gum"
  echo "✓ Gum installed successfully to $DEVBOX_BIN_DIR"
}

install_omadots() {
  section "Checking Omadots status..."
  if [ ! -d "$HOME/.local/share/omadots" ]; then
    run_with_spinner "Installing Omadots configuration..." bash -c 'curl -fsSL https://raw.githubusercontent.com/omacom-io/omadots/refs/heads/master/install.sh | bash'
  else
    echo "✓ Omadots configuration present."
  fi
}

configure_tmux_customizations() {
  local tmux_conf="$HOME/.config/tmux/tmux.conf"

  if [ ! -f "$tmux_conf" ]; then
    return 0
  fi

  section "Applying TMUX customizations..."

  # Replace the block so updates remain idempotent.
  sed -i '/# --- Devbox TMUX Customizations ---/,/# --- End Devbox TMUX Customizations ---/d' "$tmux_conf"

  cat >>"$tmux_conf" <<'EOF'

# --- Devbox TMUX Customizations ---
# Copy the pane ID to the local clipboard via OSC 52.
bind I run-shell "tmux set-buffer -w -- '#{pane_id}'" \; display-message "Copied pane ID #{pane_id}"
# Mark Devbox sessions in the status bar.
set -g status-left-length 40
set -g status-left "#[fg=black,bg=green,bold] DEVBOX #[fg=black,bg=blue,bold] #S #[bg=default] "
# --- End Devbox TMUX Customizations ---
EOF
  echo "✓ TMUX customizations applied to $tmux_conf"
}

install_mise_and_tools() {
  section "Checking Mise runtime manager..."
  if ! command -v mise &>/dev/null; then
    run_with_spinner "Bootstrapping Mise runtime manager locally..." bash -c 'curl https://mise.jdx.dev/install.sh | sh'
  fi

  # Make mise available for the remainder of this setup session.
  export PATH="$HOME/.local/share/mise/shims:$HOME/.local/share/mise/bin:$PATH"
  eval "$(mise activate bash)"

  # Package-managed mise may disable self-update or be unwritable.
  if [[ "$(command -v mise)" == "$DEVBOX_BIN_DIR/mise" ]]; then
    run_with_spinner "Updating mise itself..." mise self-update -y
  else
    echo "✓ Mise is managed outside Devbox's userspace install ($(command -v mise)); skipping 'mise self-update'."
  fi

  section "Ensuring standard terminal tools and AI shims..."

  run_with_spinner "Installing core terminal utilities (neovim, python, node, lazygit, fzf, etc.)..." mise use -g -y neovim starship eza zoxide fzf gh lazygit lazydocker btop fastfetch node python

  run_with_spinner "Installing AI tooling and devbox shims (claude-code, codex, tuicr)..." \
    mise use -g -y opencode claude-code codex antigravity-cli github:agavra/tuicr

  # Upgrade globally from $HOME so a project-local mise.toml is not modified.
  run_with_spinner "Upgrading installed tools to their latest versions..." \
    bash -c 'cd "$HOME" && mise upgrade -y'

  run_with_spinner "Finalizing tools configuration..." bash -c 'mise reshim && mise install'
}

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
      sudo tailscale set --ssh --operator="$USER"
    fi
    return 0
  fi

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
    sudo tailscale set --ssh --operator="$USER"
  else
    local status=$?
    if (( status == 130 )); then
      finish_from_interrupt
    fi
  fi
}

onboard_tmux_session() {
  if [ -f "$TMUX_SESSION_FILE" ]; then
    echo "✓ Default tmux session name already configured ('$TMUX_SESSION_NAME')."
    return 0
  fi

  local name="$TMUX_SESSION_NAME"
  gum_input_into name --prompt "[tmux] default session name: " --value "$name"
  TMUX_SESSION_NAME="${name:-Work}"
  echo "$TMUX_SESSION_NAME" > "$TMUX_SESSION_FILE"
  echo "✓ Default tmux session set to '$TMUX_SESSION_NAME'."
}

configure_firewall() {
  section "Configuring firewall (ufw)..."

  sudo_preflight

  if ! command -v ufw &>/dev/null; then
    run_with_spinner "Installing ufw..." sudo apt-get install -y ufw
  fi

  # Allow SSH before changing the default policy.
  sudo ufw allow 22/tcp >/dev/null
  # Allow tailnet traffic when Tailscale is available.
  sudo ufw allow in on tailscale0 >/dev/null 2>&1 || true

  sudo ufw default deny incoming >/dev/null
  sudo ufw default allow outgoing >/dev/null

  if sudo ufw status | grep -q "Status: active"; then
    echo "✓ Firewall already active (SSH + Tailscale interface allowed, everything else blocked)."
  else
    sudo ufw --force enable >/dev/null
    echo "✓ Firewall enabled: SSH (22/tcp) and Tailscale interface allowed, everything else blocked."
  fi
}

configure_shell_integration() {
  section "Applying userspace shell profile additions..."
  local shell_rcs=("$HOME/.bashrc" "$HOME/.zshrc")

  # Preserve spaces and special characters in the generated tmux argument.
  local quoted_session_name
  printf -v quoted_session_name '%q' "$TMUX_SESSION_NAME"

  for rc in "${shell_rcs[@]}"; do
    touch "$rc"

    # Replace the block so updates remain idempotent.
    sed -i '/# --- Devbox Shell Integrations ---/,/# --- End Devbox Shell Integrations ---/d' "$rc"

    local sh_name="bash"
    [[ "$rc" == *zshrc ]] && sh_name="zsh"

    cat >> "$rc" <<EOF

# --- Devbox Shell Integrations ---
if command -v infocmp &>/dev/null && ! infocmp "\${TERM:-}" &>/dev/null; then
  export TERM=xterm-256color
fi

export PATH="\$HOME/.local/bin:\$PATH"

if command -v mise &>/dev/null; then
  eval "\$(mise activate $sh_name)"
fi

alias pbcopy='xclip -selection clipboard'

alias tss='tailscale serve'

# Auto-launch TMUX for interactive SSH sessions.
if [[ \$- == *i* && -t 0 && -t 1 && -z "\$TMUX" && -n "\${SSH_CONNECTION:-}" ]]; then
  cd "\$HOME/Developer" && (tmux attach-session -t $quoted_session_name 2>/dev/null || tmux new-session -c "\$HOME/Developer" -s $quoted_session_name)
fi
# --- End Devbox Shell Integrations ---
EOF
  done
  echo "✓ Shell profile integrations configured."
}

reload_shell() {
  local tmux_conf="$HOME/.config/tmux/tmux.conf"

  if ! command -v zsh &>/dev/null; then
    echo "Warning: zsh is not installed; cannot reload the shell automatically. Run 'source ~/.zshrc' manually." >&2
    return 1
  fi

  if command -v tmux &>/dev/null && [ -f "$tmux_conf" ] && tmux has-session 2>/dev/null; then
    tmux source-file "$tmux_conf"
  fi

  ensure_docker_group zsh -il
}

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

usage() {
  cat <<'EOF'
Usage: devbox.sh

  Run without arguments to install Devbox on the first run and update it on later runs.
  -h, --help  Show this help text
EOF
}

install_phase() {
  install_system_dependencies
  install_gum
  install_latest_tmux
  install_docker_engine
  install_omadots
  configure_tmux_customizations
  install_mise_and_tools
}

setup_phase() {
  if [ ! -f "$ONBOARDING_DONE_MARKER" ]; then
    onboard_git
    onboard_github
    onboard_tailscale
    onboard_tmux_session
    if gum_confirm "Mark onboarding complete and skip these prompts next time?"; then
      touch "$ONBOARDING_DONE_MARKER"
    else
      local status=$?
      if (( status == 130 )); then
        finish_from_interrupt
      fi
    fi
  fi

  configure_firewall
  configure_shell_integration
  switch_to_zsh
  mkdir -p "$HOME/Developer"
  if [ -f "$ONBOARDING_DONE_MARKER" ]; then
    echo "$DEVBOX_VERSION" > "$SETUP_COMPLETE_MARKER"
  fi

  section "Devbox userspace configuration successfully completed!"
  echo -e "\033[1;32m✓ Setup finished. Reloading your shell to load all tools (e.g., eza, starship, nvim, fzf)...\033[0m"
}

update_phase() {
  configure_shell_integration
  section "Devbox components updated successfully!"
  echo -e "\033[1;32m✓ Update finished. Reloading your shell to load changes...\033[0m"
}

migrate_legacy_state() {
  local legacy_state_dir="$HOME/.local/state/devbox"
  local legacy_setup_cache="$legacy_state_dir/devbox.sh"

  # Only migrate state that contains the previous Devbox installer signature;
  # ~/.local/state/devbox is too generic to trust blindly.
  if [ ! -f "$legacy_setup_cache" ] || ! grep -q "Native userspace Devbox provisioner" "$legacy_setup_cache"; then
    return 0
  fi

  if [ ! -f "$ONBOARDING_DONE_MARKER" ] && [ -f "$legacy_state_dir/setup-done" ]; then
    cp "$legacy_state_dir/setup-done" "$ONBOARDING_DONE_MARKER"
  fi

  if [ ! -f "$TMUX_SESSION_FILE" ] && [ -f "$legacy_state_dir/tmux-session" ]; then
    cp "$legacy_state_dir/tmux-session" "$TMUX_SESSION_FILE"
  fi

  if [ -f "$legacy_state_dir/setup-done" ] && [ -f "$legacy_state_dir/tmux-session" ]; then
    echo "$DEVBOX_VERSION" > "$SETUP_COMPLETE_MARKER"
  fi
}

main() {
  if (($# > 1)); then
    echo "Unexpected arguments: ${*:2}" >&2
    usage >&2
    return 2
  fi

  case "${1:-}" in
    "")       DEVBOX_MODE="" ;;
    -h|--help)
      usage
      return 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      return 2
      ;;
  esac

  # Fallback to xterm-256color if the current TERM's terminfo is missing on this host.
  if command -v infocmp &>/dev/null && ! infocmp "${TERM:-}" &>/dev/null; then
    export TERM=xterm-256color
  fi

  if [ ! -f /etc/debian_version ]; then
    echo "Error: This script only supports Debian or Ubuntu systems." >&2
    return 1
  fi

  DEVBOX_BIN_DIR="$HOME/.local/bin"
  DEVBOX_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/dpuwork/devbox"
  ONBOARDING_DONE_MARKER="$DEVBOX_STATE_DIR/onboarding-done"
  SETUP_COMPLETE_MARKER="$DEVBOX_STATE_DIR/setup-complete"
  TMUX_SESSION_FILE="$DEVBOX_STATE_DIR/tmux-session"

  export PATH="$DEVBOX_BIN_DIR:$PATH"
  mkdir -p "$DEVBOX_BIN_DIR" "$DEVBOX_STATE_DIR" "$HOME/.config"
  migrate_legacy_state

  # Persist the tmux session name used for SSH auto-attach.
  TMUX_SESSION_NAME="Work"
  if [ -f "$TMUX_SESSION_FILE" ]; then
    TMUX_SESSION_NAME="$(cat "$TMUX_SESSION_FILE")"
  fi

  if [[ -z "$DEVBOX_MODE" ]]; then
    if [ -f "$SETUP_COMPLETE_MARKER" ]; then
      DEVBOX_MODE="update"
    else
      DEVBOX_MODE="setup"
    fi
  fi

  echo "[dpu/devbox] ${DEVBOX_MODE} v${DEVBOX_VERSION}"
  install_phase

  if [[ "$DEVBOX_MODE" == "setup" ]]; then
    setup_phase
    cleanup
    reload_shell
  else
    update_phase
    if [[ -t 0 && -t 1 && -t 2 ]]; then
      cleanup
      reload_shell
    else
      cleanup
    fi
  fi
}

main "$@"
