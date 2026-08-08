# devbox

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

- Installs the basics (git, curl, build tools, zsh, etc.)
- Builds the latest tmux from source
- Installs gum, for the nice terminal prompts
- Pulls in Omadots for dotfiles/config
- Installs dev tools and AI CLIs via mise (neovim, node, python, claude-code, codex, and more)
- Walks you through logging into git and GitHub, and connecting to Tailscale with SSH
- Turns on a firewall (ufw) that only allows SSH and Tailscale traffic, blocking everything else
- Adds a `tss` alias for `tailscale serve`
- Sets up your shell so tmux auto-attaches to a session called `Work` whenever you SSH in
- Switches your default shell to zsh

Safe to run more than once — it skips anything already set up.
