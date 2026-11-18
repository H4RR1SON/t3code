#!/usr/bin/env bash
set -euo pipefail

name="${1:?worker name required}"
repository="${2:?canonical HTTPS repository URL required}"
branch="${3:?isolated branch required}"
base="${4:?base branch required}"
[[ "$name" =~ ^nr-[a-z0-9-]+$ && "${#name}" -lt 64 ]]
[[ "$repository" =~ ^https://github[.]com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+[.]git$ ]]
[[ "$branch" == agent/* ]]
git check-ref-format --branch "$branch" >/dev/null
git check-ref-format --branch "$base" >/dev/null

state=/var/lib/t3-render-pi
secrets=/run/t3-render-pi
checkout=/work/repository
home=/home/t3worker
t3home="$home/.t3"
socket=/run/tailscale/tailscaled.sock
umask 077
install -d -m 0700 "$state"
exec 9>"$state/supervisor.lock"
flock -n 9

hostname "$name"
printf 'PRETTY_HOSTNAME=%s\n' "$name" | install -m 0644 /dev/stdin /etc/machine-info
install -d -o t3worker -g t3worker -m 0755 "$checkout"
trap 'rm -f "$secrets/git-token"' EXIT
if [[ -f "$secrets/git-token" ]]; then
  install -g t3worker -m 0710 -d "$secrets"
  chown t3worker:t3worker "$secrets/git-token"
  chmod 0600 "$secrets/git-token"
fi
runuser -u t3worker -- env GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/usr/local/bin/t3-render-pi-git-askpass \
  git -c credential.helper= clone --branch "$base" --single-branch -- "$repository" "$checkout"
rm -f "$secrets/git-token"
runuser -u t3worker -- git -C "$checkout" switch -c "$branch"
runuser -u t3worker -- git -C "$checkout" config user.name "T3 Render agent"
runuser -u t3worker -- git -C "$checkout" config user.email "t3-render-agent@users.noreply.github.com"

install -d -o t3worker -g t3worker -m 0700 "$t3home" "$t3home/userdata"
runuser -u t3worker -- tee "$t3home/userdata/settings.json" >/dev/null <<'SETTINGS'
{"linkedEnvironmentsEnabled":true,"providerInstances":{"pi":{"driver":"pi","enabled":true,"settings":{"launchArgs":"--provider relace --model deepseek-ai/DeepSeek-V4.1-Flash-1017"}}}}
SETTINGS

tailscaled --tun=userspace-networking --statedir="$state" --socket="$socket" &
tail_pid=$!
t3_pid=
finish() {
  rm -f "$secrets/tailnet-key" "$secrets/relace-key" "$secrets/git-token"
  if [[ -n "$t3_pid" ]]; then kill "$t3_pid" 2>/dev/null || true; fi
  kill "$tail_pid" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap finish EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
for _ in {1..50}; do
  [[ -S "$socket" ]] && break
  sleep 0.2
done
tailscale up --auth-key="file:$secrets/tailnet-key" --hostname="$name" \
  --accept-dns=false --accept-routes=false --operator=t3worker --timeout=45s
rm -f "$secrets/tailnet-key"

RELACE_API_KEY="$(cat "$secrets/relace-key")"
rm -f "$secrets/relace-key"
[[ -n "$RELACE_API_KEY" ]]
export RELACE_API_KEY
cd "$checkout"
runuser -u t3worker --preserve-environment -- env HOME="$home" USER=t3worker LOGNAME=t3worker \
  t3 serve --base-dir "$t3home" --host 127.0.0.1 --port 3773 --tailscale-serve >/dev/null &
t3_pid=$!
unset RELACE_API_KEY
wait -n "$tail_pid" "$t3_pid"
