#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none
export NEEDRESTART_MODE=a

apt_y() {
  apt-get -y \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    "$@"
}

apt-get update -y
apt_y upgrade
apt_y install git curl

curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
sh /tmp/get-docker.sh
rm -f /tmp/get-docker.sh

if [ ! -f /swapfile ]; then
  fallocate -l 4G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  cp /etc/fstab /etc/fstab.bak
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

install_gh=no
if [ -r /dev/tty ]; then
  exec < /dev/tty
  PS3="Install GitHub CLI? "
  select choice in "No" "Yes"; do
    install_gh=$choice
    break
  done
fi

case "$install_gh" in
  Yes)
    tag=$(curl -Ls -o /dev/null -w '%{url_effective}' https://github.com/cli/cli/releases/latest | sed 's|.*/||')
    curl -Lso /tmp/gh.deb "https://github.com/cli/cli/releases/download/$tag/gh_${tag#v}_linux_amd64.deb"
    dpkg -i /tmp/gh.deb
    rm -f /tmp/gh.deb
    ;;
esac
