# devbox

```
██████╗ ███████╗██╗   ██╗██████╗  ██████╗ ██╗  ██╗
██╔══██╗██╔════╝██║   ██║██╔══██╗██╔═══██╗╚██╗██╔╝
██║  ██║█████╗  ██║   ██║██████╔╝██║   ██║ ╚███╔╝
██║  ██║██╔══╝  ╚██╗ ██╔╝██╔══██╗██║   ██║ ██╔██╗
██████╔╝███████╗ ╚████╔╝ ██████╔╝╚██████╔╝██╔╝ ██╗
╚═════╝ ╚══════╝  ╚═══╝  ╚═════╝  ╚═════╝ ╚═╝  ╚═╝
```

Minimal terminal setup for dev boxes. Rent a VM, pipe the script, work.

## install

### setup

```bash
curl -fsSL https://cdn.dpuwork.com/setup.sh | bash
```

### (other) bootstrap

```bash
curl -fsSL https://cdn.dpuwork.com/bootstrap.sh | bash
```

## what setup does

1. Installs base system packages: `git`, `curl`, `jq`, `openssh-client`, `build-essential`, `unzip`, `zsh`, `xclip`
2. Installs [gum](https://github.com/charmbracelet/gum), for the nice terminal prompts
3. Builds the latest tmux from source
4. Pulls in [Omadots](https://github.com/omacom-io/omadots) for dotfiles/config
5. Appends devbox's own tmux customizations on top of Omadots' config (pane-ID copy shortcut, status bar tag)
6. Installs dev tools and AI CLIs via [mise](https://mise.jdx.dev):
   - Terminal tools: `neovim`, `starship`, `eza`, `zoxide`, `fzf`, `gh`, `lazygit`, `lazydocker`, `node`, `python`
   - AI CLIs & shims: `opencode`, `claude-code`, `codex`, `antigravity-cli`, [`tuicr`](https://github.com/agavra/tuicr)
7. Walks you through logging into git and GitHub, connecting to Tailscale with SSH, and naming your default tmux session (first run only — prompts default to `Work` for the session name, just hit enter to accept)
8. Turns on a firewall (ufw) that only allows SSH and Tailscale traffic, blocking everything else
9. Sets up your shell profile: `PATH`/mise activation, a `pbcopy` clipboard alias, a `tss` alias for `tailscale serve`, and auto-attaching tmux to your chosen session whenever you SSH in
10. Switches your default shell to zsh

Safe to run more than once — it skips anything already set up. Your tmux session name choice is remembered, so you won't be asked again on reruns.
