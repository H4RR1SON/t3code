#!/usr/bin/env bash
set -euo pipefail

name="${1:?worker name required}"
repository="${2:?canonical HTTPS repository URL required}"
branch="${3:?isolated branch required}"
base="${4:?base branch required}"
base_commit="${5:-}"
footprint_url="${6:-}"
transport="${7:-https}"
[[ "$name" =~ ^nr-[a-z0-9-]+$ && "${#name}" -lt 64 ]]
[[ "$repository" =~ ^https://github[.]com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+[.]git$ ]]
[[ "$branch" == agent/* ]]
git check-ref-format --branch "$branch" >/dev/null
git check-ref-format --branch "$base" >/dev/null
[[ -z "$base_commit" || "$base_commit" =~ ^[0-9a-f]{40}$ ]]
[[ "$transport" == https || "$transport" == tcp ]]

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
tailscaled --tun=userspace-networking --statedir="$state" --socket="$socket" &
tail_pid=$!
join_pid=
t3_pid=
finish() {
  rm -f "$secrets/tailnet-key" "$secrets/relace-key" "$secrets/git-token" \
    "$secrets/github-app.json" "$secrets/footprint-token" "$secrets/ledger.json"
  if [[ -n "$t3_pid" ]]; then kill "$t3_pid" 2>/dev/null || true; fi
  if [[ -n "$join_pid" ]]; then kill "$join_pid" 2>/dev/null || true; fi
  kill "$tail_pid" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap finish EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
(
  for _ in {1..50}; do
    [[ -S "$socket" ]] && break
    sleep 0.2
  done
  tailscale up --auth-key="file:$secrets/tailnet-key" --hostname="$name" \
    --accept-dns=false --accept-routes=false --operator=t3worker --timeout=45s
  rm -f "$secrets/tailnet-key"
) &
join_pid=$!

install -g t3worker -m 0710 -d "$secrets"
install -d -o t3worker -g t3worker -m 0755 "$checkout"
git_as_worker() {
  runuser -u t3worker -- env GIT_TERMINAL_PROMPT=0 \
    GIT_ASKPASS=/usr/local/bin/t3-render-pi-git-askpass git -C "$checkout" "$@"
}

git_started="$(date +%s%3N)"
git_as_worker init --quiet --initial-branch "$branch"
git_as_worker remote add --no-tags -t "$base" origin "$repository"
git_as_worker config credential.helper ''
git_as_worker config credential.useHttpPath true
if [[ -f "$secrets/github-app.json" ]]; then
  printf '%s\n' "${repository#https://github.com/}" | install -o t3worker -m 0600 /dev/stdin "$secrets/git-origin"
  chown t3worker "$secrets/github-app.json"
  git_as_worker config --add credential.helper /usr/local/bin/t3-render-pi-git-credential
  git_as_worker config user.name "$(jq -er .name "$secrets/github-app.json")"
  git_as_worker config user.email "$(jq -er .email "$secrets/github-app.json")"
elif [[ -f "$secrets/git-token" ]]; then
  chown t3worker "$secrets/git-token"
fi
if [[ ! -f "$secrets/github-app.json" ]]; then
  git_as_worker config user.name "T3 Render agent"
  git_as_worker config user.email "t3-render-agent@users.noreply.github.com"
fi
git_as_worker fetch --quiet --depth=1 --no-tags origin "${base_commit:-refs/heads/$base}"
rm -f "$secrets/git-token"
fetched="$(git_as_worker rev-parse FETCH_HEAD)"
[[ -z "$base_commit" || "$fetched" == "$base_commit" ]]
git_as_worker update-ref refs/t3/base "$fetched"
git_as_worker update-ref "refs/remotes/origin/$base" "$fetched"
git_as_worker reset --quiet --hard "$fetched"
git_as_worker config push.autoSetupRemote true
git_as_worker config push.default current
if [[ -x "$checkout/.github/hooks/pre-push" ]]; then
  git_as_worker config core.hooksPath .github/hooks
fi
jq -nc --arg sha "$fetched" --argjson ms "$(( $(date +%s%3N) - git_started ))" \
  '{commit:$sha, milliseconds:$ms}' >"$secrets/checkout.json"

install -d -o t3worker -g t3worker -m 0700 "$t3home" "$t3home/userdata"
runuser -u t3worker -- tee "$t3home/userdata/settings.json" >/dev/null <<'SETTINGS'
{"linkedEnvironmentsEnabled":true,"providerInstances":{"pi":{"driver":"pi","enabled":true,"settings":{"launchArgs":"--provider relace --model deepseek-ai/DeepSeek-V4.1-Flash-1017"}}}}
SETTINGS
if [[ -n "$footprint_url" ]]; then
  jq -nc --arg url "$footprint_url" \
    '{mcpServers:{footprint:{url:$url,headers:{Authorization:"Bearer ${FOOTPRINT_API_KEY}"}}}}' \
    | install -o t3worker -m 0600 /dev/stdin "$home/.pi/agent/mcp.json"
  FOOTPRINT_API_KEY="$(cat "$secrets/footprint-token")"
  rm -f "$secrets/footprint-token"
  export FOOTPRINT_API_KEY
fi

wait "$join_pid"
join_pid=
if [[ -f "$secrets/github-app.json" ]]; then
  GH_TOKEN="$(jq -er .token "$secrets/github-app.json")"
  export GH_TOKEN
fi
if [[ -f "$secrets/ledger.json" ]]; then
  NR_LEDGER_URL="$(jq -er .url "$secrets/ledger.json")"
  NR_LEDGER_TOKEN="$(jq -er .token "$secrets/ledger.json")"
  rm -f "$secrets/ledger.json"
  export NR_LEDGER_URL NR_LEDGER_TOKEN
fi

RELACE_API_KEY="$(cat "$secrets/relace-key")"
rm -f "$secrets/relace-key"
[[ -n "$RELACE_API_KEY" ]]
export RELACE_API_KEY
cd "$checkout"
t3_args=(serve --base-dir "$t3home" --host 127.0.0.1 --port 3773)
if [[ "$transport" == tcp ]]; then
  tailscale serve --bg --tcp=3773 tcp://127.0.0.1:3773
else
  t3_args+=(--tailscale-serve)
fi
runuser -u t3worker --preserve-environment -- env HOME="$home" USER=t3worker LOGNAME=t3worker \
  t3 "${t3_args[@]}" >/dev/null &
t3_pid=$!
unset RELACE_API_KEY GH_TOKEN FOOTPRINT_API_KEY NR_LEDGER_URL NR_LEDGER_TOKEN
wait -n "$tail_pid" "$t3_pid"
