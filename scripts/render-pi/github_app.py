"""Mint repository-scoped GitHub App credentials on the T3 operator."""

import base64
import json
import subprocess
import time
from urllib.error import HTTPError
from urllib.request import Request, urlopen


def encoded(value):
    return base64.urlsafe_b64encode(value).rstrip(b"=")


def jwt(app_id, key):
    now = int(time.time())
    header = encoded(b'{"alg":"RS256","typ":"JWT"}')
    claims = encoded(json.dumps({"iat": now - 60, "exp": now + 480, "iss": app_id}).encode())
    message = header + b"." + claims
    signature = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", str(key)],
        input=message, capture_output=True, check=True, timeout=5,
    ).stdout
    return (message + b"." + encoded(signature)).decode()


def github(path, bearer, body=None):
    data = None if body is None else json.dumps(body).encode()
    request = Request(
        f"https://api.github.com{path}", data=data,
        headers={
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "T3-Render-Pi",
        },
    )
    request.add_unredirected_header("Authorization", f"Bearer {bearer}")
    try:
        with urlopen(request, timeout=10) as response:
            return json.load(response)
    except HTTPError as error:
        raise RuntimeError(f"GitHub App request for {path} returned HTTP {error.code}") from None


def mint(repository, config, key):
    owner, repo = repository.removeprefix("https://github.com/").removesuffix(".git").split("/")
    bearer = jwt(config["appId"], key)
    installation = int(github(f"/repos/{owner}/{repo}/installation", bearer)["id"])
    permissions = {"contents": "write", "pull_requests": "write"}
    credential = github(f"/app/installations/{installation}/access_tokens", bearer, {
        "repositories": [repo],
        "permissions": permissions,
    })
    if any(credential["permissions"].get(scope) != level for scope, level in permissions.items()):
        raise RuntimeError("GitHub App lacks Contents or Pull Requests write access")
    login = config["botLogin"]
    return {
        "token": credential["token"],
        "name": login,
        "email": f"{int(config['botUserId'])}+{login}@users.noreply.github.com",
    }
