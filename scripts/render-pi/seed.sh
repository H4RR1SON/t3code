#!/usr/bin/env bash
set -euo pipefail

[[ "$(uname -m)" == x86_64 && "$EUID" == 0 ]]
here="$(cd -- "$(dirname -- "$0")" && pwd)"
node_version=24.22.3
go_version=1.27.4
pi_version=1.5.2
t3_version=0.1.10-nightly.20261114.4669
tailscale_version=1.104.4
tailscale_checksum=624ea093d47d62cf56f17b8332d74b8decda4a1faa610ebc60a1de334b2b3dc9
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export DEBIAN_FRONTEND=noninteractive

apt-get -qq update
apt-get -qq install -y --no-install-recommends ca-certificates curl git git-lfs gh \
  build-essential sqlite3 shellcheck openssh-client rsync ripgrep jq bash file \
  unzip zip binutils xz-utils zstd python3 python3-venv openjdk-17-jre-headless
rm -rf /var/lib/apt/lists/*

download() {
  curl --fail --silent --show-error --location --retry 2 --max-time 120 "$1" -o "$2"
}

node_archive="node-v$node_version-linux-x64.tar.xz"
download "https://nodejs.org/dist/v$node_version/$node_archive" "$tmp/$node_archive"
download "https://nodejs.org/dist/v$node_version/SHASUMS256.txt" "$tmp/node-sha.txt"
(cd "$tmp" && grep -F "  $node_archive" node-sha.txt | sha256sum -c)
install -d /opt/node /opt/t3
tar -xJf "$tmp/$node_archive" --strip-components=1 -C /opt/node
export PATH="/opt/node/bin:/opt/go/bin:/usr/local/bin:$PATH"
npm install --global --ignore-scripts --no-fund --no-audit "@earendil-works/pi-coding-agent@$pi_version"
for binary in node npm pi; do
  ln -sfn "/opt/node/bin/$binary" "/usr/local/bin/$binary"
done

download "https://go.dev/dl/go$go_version.linux-amd64.tar.gz" "$tmp/go.tgz"
tar -xzf "$tmp/go.tgz" -C /opt
ln -sfn /opt/go/bin/go /usr/local/bin/go

download "https://github.com/pingdotgg/t3code/releases/download/v$t3_version/t3-$t3_version-linux-x64.tar.gz" "$tmp/t3.tgz"
tar -xzf "$tmp/t3.tgz" -C /opt/t3
t3_binary="$(find /opt/t3 -type f -name t3 -print -quit)"
[[ -x "$t3_binary" ]]
ln -sfn "$t3_binary" /usr/local/bin/t3

download "https://pkgs.tailscale.com/stable/tailscale_${tailscale_version}_amd64.tgz" "$tmp/tailscale.tgz"
printf '%s  %s\n' "$tailscale_checksum" "$tmp/tailscale.tgz" | sha256sum -c
tar -xzf "$tmp/tailscale.tgz" -C "$tmp" --strip-components=1 --wildcards '*/tailscale' '*/tailscaled'
install -m 0755 "$tmp/tailscale" "$tmp/tailscaled" /usr/local/bin/

useradd --create-home --shell /bin/bash t3worker
install -d -o t3worker -g t3worker -m 0700 /home/t3worker/.pi/agent
install -o t3worker -g t3worker -m 0600 "$here/models.json" /home/t3worker/.pi/agent/models.json
install -m 0755 "$here/start.sh" /usr/local/bin/t3-render-pi-worker
install -m 0755 "$here/git-askpass.sh" /usr/local/bin/t3-render-pi-git-askpass
for binary in opencode codex claude; do
  if command -v "$binary" >/dev/null; then
    printf 'Unexpected harness in snapshot: %s\n' "$binary" >&2
    exit 1
  fi
done
pi --version
t3 --version
go version
