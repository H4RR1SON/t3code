#!/usr/bin/env bash
set -euo pipefail
[[ -r /run/t3-render-pi/git-token ]]
case "$1" in
  Username*) printf '%s\n' x-access-token ;;
  Password*) cat /run/t3-render-pi/git-token ;;
  *) exit 1 ;;
esac
