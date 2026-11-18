#!/usr/bin/env bash
set -euo pipefail

footprint="${1:?Footprint skill directory required}"
agent=/home/t3worker/.pi/agent
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for skill in enrich-identifiers save-tfi-evidence; do
  install -d -o t3worker -g t3worker -m 0755 "$agent/skills/$skill"
  install -o t3worker -g t3worker -m 0644 "$footprint/$skill/SKILL.md" "$agent/skills/$skill/"
done
install -d -o t3worker -g t3worker -m 0755 "$agent/skills/enrich-identifiers/references"
install -o t3worker -g t3worker -m 0644 "$footprint/enrich-identifiers/references/tools.md" \
  "$agent/skills/enrich-identifiers/references/"

curl -fsSL --retry 3 --max-time 120 \
  https://github.com/skylot/jadx/releases/download/v1.5.6/jadx-1.5.6.zip -o "$tmp/jadx.zip"
curl -fsSL --retry 3 --max-time 120 \
  https://github.com/iBotPeaches/Apktool/releases/download/v3.0.3/apktool_3.0.3.jar -o "$tmp/apktool.jar"
(
  cd "$tmp"
  sha256sum -c <<'CHECKSUMS'
545ea2be9c242511bc145755cf4bda2485ade42966e096f8b4d3da2a230e8974  jadx.zip
dbf930b076c6b9be08d57c449cacefc3bdd6b71ebd59b3066fc0e1f5b14f9423  apktool.jar
CHECKSUMS
)
unzip -q -o "$tmp/jadx.zip" -d /opt/jadx
ln -sfn /opt/jadx/bin/jadx /usr/local/bin/jadx
install -m 0644 "$tmp/apktool.jar" /opt/apktool.jar
cat >/usr/local/bin/apktool <<'APKTOOL'
#!/bin/sh
exec java -jar /opt/apktool.jar "$@"
APKTOOL
chmod 0755 /usr/local/bin/apktool
jadx --version
apktool --version
