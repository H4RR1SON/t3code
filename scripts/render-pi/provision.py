#!/usr/bin/env python3
"""Provision and retire a named Pi environment for T3's native peer transport."""
import argparse
import base64
import fcntl
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlencode, urlsplit
from urllib.request import ProxyHandler, Request, build_opener, urlopen

import github_app


STATE = Path(os.environ.get("T3_RENDER_PI_STATE", Path.home() / ".t3" / "render-pi"))
RENDER = os.environ.get("T3_RENDER_PI_RENDER_CLI", "render")
GUEST_PRIVATE = "/run/t3-render-pi"
GUEST_T3 = "/home/t3worker/.t3"


class ProvisionError(Exception):
    pass


def call(*args, seconds=30):
    try:
        result = subprocess.run(args, capture_output=True, timeout=seconds, check=True)
    except subprocess.CalledProcessError as failure:
        raise ProvisionError(f"Render {args[2]} exited {failure.returncode}") from None
    except subprocess.TimeoutExpired:
        raise ProvisionError(f"Render {args[2]} timed out") from None
    return result.stdout.decode()


def render(*args, **options):
    return call(RENDER, "sandboxes", *args, **options)


def guest(sandbox, *args, **options):
    return render("exec", sandbox, "--", *args, **options)


def repeat(action, seconds=65):
    deadline = time.monotonic() + seconds
    while True:
        try:
            return action()
        except (OSError, ProvisionError) as failure:
            if time.monotonic() >= deadline:
                raise ProvisionError(str(failure)) from None
            time.sleep(1)


def save(path, record):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(record) + "\n")
    temporary.replace(path)


def matches(name):
    return json.loads(render("list", "--group", os.environ["T3_RENDER_PI_GROUP"],
                             "--name", name, "--all", "-o", "json"))


def stop(sandbox, name):
    def terminated():
        entry = next((row for row in matches(name) if row["id"] == sandbox), None)
        return entry is not None and entry["status"] == "terminated"

    if not terminated():
        try:
            render("stop", sandbox, "--confirm", "-o", "json")
        except ProvisionError:
            if not terminated():
                raise

    def confirm():
        if not terminated():
            raise ProvisionError(f"Termination unconfirmed for {sandbox}")

    repeat(confirm, 45)


def secret(name):
    path = Path(os.environ[name])
    if not path.is_file() or path.stat().st_mode & 0o077 or not path.stat().st_size:
        raise ProvisionError(f"{name} must point to a nonempty mode-600 file")
    return path


def delivery_key():
    if not os.environ.get("T3_RENDER_PI_TAILSCALE_OAUTH_FILE"):
        return secret("T3_RENDER_PI_TAILSCALE_KEY_FILE").read_bytes()
    config = json.loads(secret("T3_RENDER_PI_TAILSCALE_OAUTH_FILE").read_text())
    tags = config["tags"]
    if not isinstance(tags, list) or not tags or any(not re.fullmatch(r"tag:[\w-]+", tag) for tag in tags):
        raise ProvisionError("Tailscale OAuth requires an allowed worker tag")
    principal = base64.b64encode(f"{config['clientId']}:{config['clientSecret']}".encode()).decode()
    api = "https://api.tailscale.com/api/v2"
    with urlopen(Request(f"{api}/oauth/token", data=urlencode({"grant_type": "client_credentials"}).encode(),
                         headers={"Authorization": f"Basic {principal}"}), timeout=15) as response:
        bearer = json.load(response)["access_token"]
    create = {"reusable": False, "ephemeral": True, "preauthorized": True, "tags": tags}
    body = json.dumps({"capabilities": {"devices": {"create": create}}, "expirySeconds": 600}).encode()
    with urlopen(Request(f"{api}/tailnet/-/keys", data=body,
                         headers={"Authorization": f"Bearer {bearer}", "Content-Type": "application/json"}),
                 timeout=15) as response:
        return json.load(response)["key"].encode()


def deliver(sandbox, data, name):
    with tempfile.TemporaryDirectory(dir=STATE) as directory:
        private = Path(directory) / "credential"
        private.write_bytes(data)
        render("copy", str(private), f"{sandbox}:{GUEST_PRIVATE}/{name}")


def identify(sandbox, name, transport):
    dns = repeat(lambda: guest(
        sandbox, "bash", "-o", "pipefail", "-c",
        'tailscale status --json | jq -er \'select(.BackendState == "Running") | .Self.DNSName | rtrimstr(".")\'',
    ).strip())
    if not re.fullmatch(r"[a-z0-9.-]+\.ts\.net", dns) or dns.split(".")[0] != name:
        raise ProvisionError("Unexpected private hostname")
    url = f"http://{dns}:3773" if transport == "tcp" else f"https://{dns}"
    opener = build_opener(ProxyHandler({}))

    def descriptor():
        with opener.open(f"{url}/.well-known/t3/environment", timeout=5) as response:
            return json.load(response)

    try:
        identity = repeat(descriptor, 30 if transport == "tcp" else 100)
    except ProvisionError as error:
        raise ProvisionError(f"T3 {transport} readiness probe for {name} failed: {error}") from None
    if identity["label"] != name:
        raise ProvisionError("T3 descriptor does not belong to this worker")
    return {"sandboxId": sandbox, "name": name, "url": url, "environmentId": identity["environmentId"]}


def prepare(args, path):
    if not re.fullmatch(r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git", args.repository):
        raise ProvisionError("Use a canonical HTTPS GitHub origin")
    allowed = os.environ["T3_RENDER_PI_REPOSITORIES"].split(",")
    if args.repository not in allowed:
        raise ProvisionError("Repository is outside this Render integration's scope")
    record = json.loads(path.read_text()) if path.exists() else {}
    if "environmentId" in record:
        if record.get("status") not in {"ready", "active"}:
            raise ProvisionError("Worker has entered terminal cleanup")
        if (record.get("repository"), record.get("branch"), record.get("base"), record.get("baseCommit")) != (
            args.repository, args.branch, args.base, args.base_commit
        ):
            raise ProvisionError("This request ID already belongs to a different checkout")
        return record
    tailnet = delivery_key()
    relace = secret("T3_RENDER_PI_RELACE_KEY_FILE")
    git = secret("T3_RENDER_PI_GIT_TOKEN_FILE") if os.environ.get("T3_RENDER_PI_GIT_TOKEN_FILE") else None
    app = os.environ.get("T3_RENDER_PI_GITHUB_APP_FILE")
    if app and git:
        raise ProvisionError("Configure one GitHub credential source")
    if app:
        app_config = json.loads(secret("T3_RENDER_PI_GITHUB_APP_FILE").read_text())
        app_key = Path(app_config["privateKeyFile"])
        if not app_key.is_absolute() or not app_key.is_file() or app_key.stat().st_mode & 0o077:
            raise ProvisionError("GitHub App private key must be an absolute private file")
        if not re.fullmatch(r"[a-z0-9-]+\[bot\]", app_config["botLogin"]):
            raise ProvisionError("Configure the GitHub App bot login")
    ledger = None
    if os.environ.get("T3_RENDER_PI_LEDGER_FILE") and args.repository.casefold() == "https://github.com/noresponsehq/noresponse.git":
        ledger = json.loads(secret("T3_RENDER_PI_LEDGER_FILE").read_text())
        ledger_url = urlsplit(ledger["url"])
        if (ledger_url.scheme != "https" or not ledger_url.hostname or ledger_url.username is not None
            or ledger_url.query or ledger_url.fragment or not ledger["token"]):
            raise ProvisionError("Configure a NoResponse ledger HTTPS URL and agent token")
    if args.base_commit is not None and not re.fullmatch(r"[0-9a-f]{40}", args.base_commit):
        raise ProvisionError("Base commit must be a full lowercase Git commit SHA")
    transport = os.environ.get("T3_RENDER_PI_TAILNET_TRANSPORT", "https")
    if transport not in {"https", "tcp"}:
        raise ProvisionError("Tailnet transport must be https or tcp")
    rows = [row for row in matches(args.name) if row["status"] != "terminated"]
    if rows:
        raise ProvisionError(f"Unconfirmed prior provisioning of {args.name}; retire it before retrying")
    save(path, {"name": args.name, "status": "creating"})
    sandbox = None
    checkout = None
    try:
        try:
            row = json.loads(render("create", "--group", os.environ["T3_RENDER_PI_GROUP"],
                "--snapshot-id", os.environ["T3_RENDER_PI_SNAPSHOT"], "--name", args.name,
                "--plan", "2c-4g", "--timeout", "3600", "--idle-timeout", "0",
                "--network-policy", "allow-all", "-o", "json", seconds=40))
            sandbox = row["id"]
        except (ProvisionError, ValueError):
            recovered = [row for row in matches(args.name) if row["status"] != "terminated"]
            if len(recovered) == 1:
                sandbox = recovered[0]["id"]
            raise
        save(path, {"name": args.name, "sandboxId": sandbox, "status": "starting"})
        repeat(lambda: guest(sandbox, "install", "-m", "0700", "-d", GUEST_PRIVATE))
        deliver(sandbox, tailnet, "tailnet-key")
        deliver(sandbox, relace.read_bytes(), "relace-key")
        if git is not None:
            deliver(sandbox, git.read_bytes(), "git-token")
        if app:
            credential = github_app.mint(args.repository, app_config, app_key)
            deliver(sandbox, json.dumps(credential).encode(), "github-app.json")
        if ledger is not None:
            deliver(sandbox, json.dumps(ledger).encode(), "ledger.json")
        guest(sandbox, "bash", "-c",
              'setsid /usr/local/bin/t3-render-pi-worker "$@" </dev/null >/var/log/t3-render-pi.log 2>&1 &',
              "start", args.name, args.repository, args.branch, args.base,
              args.base_commit or "", transport)
        checkout = json.loads(repeat(lambda: guest(sandbox, "cat", f"{GUEST_PRIVATE}/checkout.json")))
        record = identify(sandbox, args.name, transport)
        guest(sandbox, "runuser", "-u", "t3worker", "--", "t3", "project", "add",
              "--base-dir", GUEST_T3, "/work/repository")
        record.update(status="ready", repository=args.repository, branch=args.branch, base=args.base,
                      baseCommit=args.base_commit, checkout=checkout)
        save(path, record)
        return record
    except BaseException:
        if sandbox:
            stop(sandbox, args.name)
            save(path, {"sandboxId": sandbox, "name": args.name, "status": "terminated", "checkout": checkout})
        raise


def retire(name, path):
    if not path.exists():
        return {"status": "untracked"}
    record = json.loads(path.read_text())
    if record.get("status") == "terminated":
        return record
    sandbox = record.get("sandboxId")
    rows = matches(name)
    if not sandbox:
        active = [row for row in rows if row["status"] != "terminated"]
        if len(active) != 1:
            raise ProvisionError(f"Cannot resolve one sandbox for {name}")
        sandbox = active[0]["id"]
    if any(row["id"] == sandbox and row["status"] == "terminated" for row in rows):
        record.update(sandboxId=sandbox, status="terminated")
        save(path, record)
        return record
    save(path, {**record, "sandboxId": sandbox, "status": "retiring"})
    guest(sandbox, "bash", "-c", r"""
        set -eu
        install -m 0700 -d /tmp/t3-pi-artifacts
        git_as_worker() { runuser -u t3worker -- git -C /work/repository "$@"; }
        git_as_worker diff --binary HEAD > /tmp/t3-pi-artifacts/working.patch
        if git_as_worker show-ref --verify --quiet refs/t3/base; then
          git_as_worker format-patch --stdout refs/t3/base..HEAD > /tmp/t3-pi-artifacts/commits.patch
        else
          git_as_worker format-patch --stdout --root HEAD --not --remotes=origin \
            > /tmp/t3-pi-artifacts/commits.patch
        fi
        git_as_worker ls-files --others --exclude-standard -z | \
          tar -C /work/repository -cf /tmp/t3-pi-artifacts/untracked.tar --null --no-recursion -T -
        if [ -d /home/t3worker/.pi/agent/sessions ]; then
          cp -a /home/t3worker/.pi/agent/sessions /tmp/t3-pi-artifacts/pi-sessions
        fi
        database=/home/t3worker/.t3/userdata/statev2.sqlite
        if [ -r "$database" ]; then
          sqlite3 -readonly -cmd '.timeout 3000' "$database" "
            SELECT json_object('sequence', sequence, 'id', event_id, 'streamId', stream_id,
              'aggregateKind', aggregate_kind, 'streamVersion', stream_version,
              'type', event_type, 'at', occurred_at, 'payload', json(payload_json),
              'metadata', json(metadata_json))
            FROM orchestration_events WHERE application_event_version = 2 ORDER BY sequence
          " > /tmp/t3-pi-artifacts/t3-events.ndjson
        fi
        cp /var/log/t3-render-pi.log /tmp/t3-pi-artifacts/supervisor.log
    """)
    archive = STATE / name
    archive.mkdir(mode=0o700, exist_ok=True)
    render("copy", f"{sandbox}:/tmp/t3-pi-artifacts", str(archive), seconds=120)
    stop(sandbox, name)
    record.update(sandboxId=sandbox, status="terminated")
    save(path, record)
    return record


def reconcile():
    for path in STATE.glob("nr-t3-pi-*.json"):
        with path.with_suffix(".lock").open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                continue
            record = json.loads(path.read_text())
            name = path.stem
            status = record.get("status")
            if status in {"creating", "starting"}:
                for row in matches(name):
                    if row["status"] != "terminated":
                        stop(row["id"], name)
                save(path, {**record, "status": "terminated"})
            elif status == "retiring":
                retire(name, path)


def interrupted(_signum, _frame):
    raise ProvisionError("Worker preparation interrupted")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("prepare", "adopt", "retire", "reconcile"))
    parser.add_argument("name", nargs="?")
    parser.add_argument("repository", nargs="?")
    parser.add_argument("branch", nargs="?")
    parser.add_argument("base", nargs="?")
    parser.add_argument("base_commit", nargs="?")
    args = parser.parse_args()
    os.umask(0o077)
    STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
    if args.action == "reconcile":
        reconcile()
        return
    if not args.name or not re.fullmatch(r"nr-(?:tmp-)?t3-pi-[a-z0-9-]{1,48}", args.name):
        parser.error("Invalid worker name")
    path = STATE / f"{args.name}.json"
    with path.with_suffix(".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            if args.action == "adopt":
                record = json.loads(path.read_text())
                if record["status"] not in {"ready", "active"}:
                    raise ProvisionError("Worker has entered terminal cleanup")
                save(path, {**record, "status": "active"})
                return
            if args.action == "retire":
                print(json.dumps(retire(args.name, path)))
                return
            record = prepare(args, path)
            pairing = json.loads(guest(
                record["sandboxId"], "runuser", "-u", "t3worker", "--", "t3", "auth",
                "pairing", "create", "--base-dir", GUEST_T3, "--ttl", "5m", "--json",
            ))
            print(json.dumps({**record, "pairingCode": pairing["credential"]}))
        except (OSError, KeyError, ValueError, RuntimeError, subprocess.SubprocessError, ProvisionError) as error:
            sys.exit(f"Render Pi: {error}")


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    main()
