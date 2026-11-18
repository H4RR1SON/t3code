#!/usr/bin/env bash
set -euo pipefail

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

download() {
  curl -fsSL --retry 3 --max-time 120 "https://github.com/$1/releases/download/$2/$3" -o "$tmp/$4"
}
# The Render base has glibc 2.36. apkeep 1.1.0's release binary requires 2.38.
download EFForg/apkeep 1.0.0 apkeep-x86_64-unknown-linux-gnu apkeep
download MG1937/rust_ASC v0.1.2-musl rust_ASC-linux-x86_64-musl rust_ASC
download astral-sh/uv 0.12.2 uv-x86_64-unknown-linux-gnu.tar.gz uv.tar.gz
download skylot/jadx v1.5.6 jadx-1.5.6.zip jadx.zip
download iBotPeaches/Apktool v3.0.3 apktool_3.0.3.jar apktool.jar
(
  cd "$tmp"
  sha256sum -c <<'CHECKSUMS'
a23579a3ba366d25a6d69848189b983d65662f4ecf4b9e11e16510811659de4e  apkeep
cf46411fc8905f290822d8a066bdff564b10e5925cc6cdc5e29b0518cae150ca  rust_ASC
d66e96b5f1ca3b99806eee283a8125d33a0bd669e6e6d9bc4ab7ffda63c41bf4  uv.tar.gz
545ea2be9c242511bc145755cf4bda2485ade42966e096f8b4d3da2a230e8974  jadx.zip
dbf930b076c6b9be08d57c449cacefc3bdd6b71ebd59b3066fc0e1f5b14f9423  apktool.jar
CHECKSUMS
)
install -m 0755 "$tmp/apkeep" "$tmp/rust_ASC" /usr/local/bin/
tar -xzf "$tmp/uv.tar.gz" -C "$tmp"
install -m 0755 "$tmp/uv-x86_64-unknown-linux-gnu/uv" "$tmp/uv-x86_64-unknown-linux-gnu/uvx" /usr/local/bin/
unzip -q -o "$tmp/jadx.zip" -d /opt/jadx
ln -sfn /opt/jadx/bin/jadx /usr/local/bin/jadx
install -m 0644 "$tmp/apktool.jar" /opt/apktool.jar
cat >/usr/local/bin/apktool <<'APKTOOL'
#!/bin/sh
exec java -jar /opt/apktool.jar "$@"
APKTOOL
chmod 0755 /usr/local/bin/apktool
apkeep --version
asc_help="$(rust_ASC --help 2>&1)" || [[ $? -eq 1 ]]
grep -q getmanifest <<<"$asc_help"
uv --version
jadx --version
apktool --version
