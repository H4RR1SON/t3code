#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == get ]] || exit 0
protocol=
host=
path=
while IFS='=' read -r key value && [[ -n "$key" ]]; do
  case "$key" in
    protocol) protocol="$value" ;;
    host) host="$value" ;;
    path) path="$value" ;;
  esac
done
private=/run/t3-render-pi
[[ "$protocol" == https && "$host" == github.com && -r "$private/github-app.json" ]] || exit 0
IFS= read -r origin <"$private/git-origin"
[[ "${path%.git}" == "${origin%.git}" ]] || exit 0
printf 'username=x-access-token\npassword='
jq -er .token "$private/github-app.json"
