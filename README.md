<div align="center">

<picture>
  <source media="(prefers-color-scheme: light)" srcset="/assets/devbox-light.svg">
  <img alt="devbox logo" src="/assets/devbox-dark.svg" width="50%" height="50%">
</picture>

<br/>

devbox: minimalist, opinionated, ready-to-use development environment with tmux, Neovim, Tailscale, mise, Docker, and a set of TUIs and coding agents.
</div>

---

```bash
curl -fsSL https://cdn.dpuwork.com/devbox.sh | bash
```

## what setup does

- **Shell**: zsh (set as your default shell), tmux (built from latest source), [Omadots](https://github.com/omacom-io/omadots) dotfiles with devbox's own tmux customizations layered on top (pane-ID copy shortcut, status bar tag)
- **Editor**: Neovim ([LazyVim](https://www.lazyvim.org))
- **Agents**: `opencode`, `claude-code`, `codex`, `antigravity-cli`, [`tuicr`](https://github.com/agavra/tuicr)
- **Dev tools**: [mise](https://mise.jdx.dev), Docker Engine, `starship`, `eza`, `zoxide`, `fzf`, `gh`, `lazygit`, `lazydocker`, `btop`, `fastfetch`, `node`, `python`, [gum](https://github.com/charmbracelet/gum)
- **Networking**: SSH, Tailscale, and a ufw firewall that only allows SSH and Tailscale traffic
- **Git**: interactive login to git and GitHub

Base system packages (`git`, `ca-certificates`, `curl`, `jq`, `openssh-client`, `build-essential`, `unzip`, `zsh`, `xclip`) and Docker Engine are installed via the official apt repos; tmux is built from source. Dev tools and AI CLIs are installed through mise once those are in place. On first run, setup also walks you through logging into git and GitHub, connecting to Tailscale over SSH, and naming your default tmux session (defaults to `Work`), then configures your shell profile — `PATH`/mise activation, a `pbcopy` clipboard alias, a `tss` alias for `tailscale serve`, and auto-attaching tmux to your chosen session whenever you SSH in.

## install and updates

Run the same bootstrap command again to update Devbox-managed packages and tools:

```bash
curl -fsSL https://cdn.dpuwork.com/devbox.sh | bash
```

The first run performs onboarding and reloads the shell. Later interactive runs skip onboarding, update the installation, and automatically start a fresh shell with the updated configuration.

Devbox stores its configuration under `~/.local/state/dpuwork/devbox`.

## shortcuts

### omaterm shortcuts

The base tmux/Neovim/shell keybindings come from Omadots (see the [Omaterm manual](https://learn.omacom.io/4/the-omaterm-manual/113/hotkeys)).

### tmux shortcuts

| Hotkey     | Function                                  |
| ---------- | ----------------------------------------- |
| `Ctrl-b`   | tmux prefix (default, unchanged)          |
| `Prefix I` | Copy the current pane ID to the clipboard |

### aliases

| Alias    | Function                                                   |
| -------- | ---------------------------------------------------------- |
| `pbcopy` | Pipe stdin to the clipboard (`xclip -selection clipboard`) |
| `tss`    | Shortcut for [`tailscale serve`](https://tailscale.com/kb/1312/serve) |

Onboarding sets you as the Tailscale operator (`tailscale set --operator=$USER`) so `tss` works without `sudo`.

### mise updates

Update globally managed mise tools from your home directory:

```bash
cd ~ && mise upgrade
```

See the [mise documentation](https://mise.jdx.dev/) for more update options.

## credits

The logo uses [Microwaves](https://billyargel.com/product/microwaves/) font by Billy Argel, free for personal use.
