#!/usr/bin/env python3
"""Checks files over MCP (specs/270) against a running PurpleFlow in Docker.

    python3 test/deployed/mcp_check.py      (from the repo root)

It signs in to /mcp two ways and uses the tools against the real dufs:

1. With the agent token: lists, writes a workflow, waits for it to load
   (GET /api/workflows), reads, stats, hashes, moves, and deletes it.
2. As Claude would: fetches the metadata, signs in at /login, opens the
   Allow page with Claude's real client document
   (https://claude.ai/oauth/mcp-oauth-client-metadata, fetched by the app),
   clicks Allow, takes the code from the redirect (not followed), trades it
   with PKCE, calls /mcp with the access token, refreshes, and checks the
   old refresh token is refused.

It leaves nothing behind but the connected app, named Claude; disconnect
it on /credentials. Exits 1 on the first failure.

Settings (environment, else ./.env): PF_PORT (PORT), PF_TOKEN
(PURPLEFLOW_AGENT_TOKEN), PF_ADMIN_USER and PF_ADMIN_PASSWORD
(PURPLEFLOW_ADMIN_USERNAME, PURPLEFLOW_ADMIN_PASSWORD).
"""

import base64
import hashlib
import http.cookiejar
import json
import os
import re
import secrets
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


def env_value(name):
    try:
        for line in open(".env"):
            if line.startswith(name + "="):
                return line.split("=", 1)[1].strip()
    except FileNotFoundError:
        pass
    return None


PORT = os.environ.get("PF_PORT") or env_value("PORT") or "4000"
TOKEN = os.environ.get("PF_TOKEN") or env_value("PURPLEFLOW_AGENT_TOKEN")
USER = os.environ.get("PF_ADMIN_USER") or env_value("PURPLEFLOW_ADMIN_USERNAME")
PASSWORD = os.environ.get("PF_ADMIN_PASSWORD") or env_value("PURPLEFLOW_ADMIN_PASSWORD")
BASE = f"http://localhost:{PORT}"
CLAUDE = "https://claude.ai/oauth/mcp-oauth-client-metadata"
CALLBACK = "https://claude.ai/api/mcp/auth_callback"
FOLDER = "zz_mcp_check"


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


jar = http.cookiejar.CookieJar()
browser = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar), NoRedirect)
plain = urllib.request.build_opener(NoRedirect)


def request(method, path, body=None, headers=None, opener=plain):
    req = urllib.request.Request(BASE + path, data=body, method=method, headers=headers or {})
    try:
        with opener.open(req, timeout=30) as resp:
            return resp.status, dict(resp.headers), resp.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()


def check(ok, what):
    print(("ok    " if ok else "FAIL  ") + what)
    if not ok:
        sys.exit(1)


def rpc(token, method, params=None, id=1):
    message = {"jsonrpc": "2.0", "id": id, "method": method, "params": params or {}}
    status, _, body = request(
        "POST",
        "/mcp",
        json.dumps(message).encode(),
        {
            "authorization": "Bearer " + token,
            "content-type": "application/json",
            "accept": "application/json, text/event-stream",
        },
    )
    return status, json.loads(body) if body else None


def tool(token, name, **arguments):
    status, body = rpc(token, "tools/call", {"name": name, "arguments": arguments})
    if status != 200 or "result" not in body:
        check(False, f"{name}: {status} {body}")
    return body["result"]


def with_agent_token():
    status, headers, _ = request("POST", "/mcp", b"{}", {"content-type": "application/json"})
    check(status == 401 and "resource_metadata" in headers.get("www-authenticate", ""),
          "/mcp without a token is 401 with a challenge")

    status, body = rpc(TOKEN, "initialize", {"protocolVersion": "2025-11-25"})
    check(status == 200 and body["result"]["protocolVersion"] == "2025-11-25", "initialize")

    _, body = rpc(TOKEN, "tools/list")
    check(len(body["result"]["tools"]) == 11, "tools/list has the eleven tools")

    tool(TOKEN, "delete", path=FOLDER)  # in case an earlier run stopped halfway
    toml = f'[workflow]\nname = "{FOLDER}"\n\n[[steps]]\nname = "noop"\nnode = "noop.toml"\n'
    result = tool(TOKEN, "write", path=f"{FOLDER}/noop.toml", content='module = "PurpleFlow.Nodes.Noop"\n')
    check(not result["isError"], "write makes a file in a new folder")
    tool(TOKEN, "write", path=f"{FOLDER}/workflow.toml", content=toml)

    loaded = False
    for _ in range(20):
        _, _, body = request("GET", "/api/workflows", headers={"authorization": "Bearer " + TOKEN})
        names = [w["name"] for w in json.loads(body)["workflows"] if not w["problems"]]
        if FOLDER in names:
            loaded = True
            break
        time.sleep(0.5)
    check(loaded, "the written workflow loads, live")

    result = tool(TOKEN, "read", path=f"{FOLDER}/workflow.toml")
    check(result["content"][0]["text"] == toml, "read returns what was written")

    entries = tool(TOKEN, "list", path=FOLDER)["structuredContent"]["entries"]
    check(sorted(e["name"] for e in entries) == ["noop.toml", "workflow.toml"], "list shows both")

    stat = tool(TOKEN, "stat", path=f"{FOLDER}/workflow.toml")["structuredContent"]
    check(stat["exists"] and stat["type"] == "file" and stat["size"] == len(toml), "stat")
    folder = tool(TOKEN, "stat", path=FOLDER)["structuredContent"]
    check(folder == {"exists": True, "type": "dir"}, "stat on a folder")

    digest = tool(TOKEN, "hash", path=f"{FOLDER}/workflow.toml")["structuredContent"]["sha256"]
    check(digest == hashlib.sha256(toml.encode()).hexdigest(), "hash is the SHA-256")

    tool(TOKEN, "append", path=f"{FOLDER}/notes.txt", content="x")  # missing: an error
    tool(TOKEN, "write", path=f"{FOLDER}/notes.txt", content="one")
    tool(TOKEN, "append", path=f"{FOLDER}/notes.txt", content="+two")
    tool(TOKEN, "move", path=f"{FOLDER}/notes.txt", destination=f"{FOLDER}/moved.txt")
    text = tool(TOKEN, "read", path=f"{FOLDER}/moved.txt")["content"][0]["text"]
    check(text == "one+two", "append and move")

    found = tool(TOKEN, "search", path="", query="moved")["structuredContent"]["entries"]
    check([e["name"] for e in found] == [f"{FOLDER}/moved.txt"], "search finds it")

    escape = tool(TOKEN, "read", path="../.env")
    check(escape["isError"], "a path with .. is refused")

    tool(TOKEN, "delete", path=FOLDER)
    check(not tool(TOKEN, "stat", path=FOLDER)["structuredContent"]["exists"], "delete")


def as_claude():
    _, _, body = request("GET", "/.well-known/oauth-protected-resource/mcp")
    resource = json.loads(body)["resource"]
    _, _, body = request("GET", "/.well-known/oauth-authorization-server")
    issuer = json.loads(body)["issuer"]
    check(resource == issuer + "/mcp", "the metadata names this site")

    _, _, page = request("GET", "/login", opener=browser)
    csrf = re.search(rb'name="_csrf_token"[^>]*value="([^"]+)"', page).group(1).decode()
    form = urllib.parse.urlencode({"_csrf_token": csrf, "username": USER, "password": PASSWORD})
    status, _, _ = request("POST", "/login", form.encode(),
                           {"content-type": "application/x-www-form-urlencoded"}, browser)
    check(status == 302, "signed in")

    verifier = secrets.token_urlsafe(48)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=")
    params = {
        "response_type": "code",
        "client_id": CLAUDE,
        "redirect_uri": CALLBACK,
        "code_challenge": challenge.decode(),
        "code_challenge_method": "S256",
        "state": "check-state",
        "scope": "files",
        "resource": resource,
    }
    status, _, page = request("GET", "/oauth/authorize?" + urllib.parse.urlencode(params), opener=browser)
    check(status == 200 and b"Claude" in page and b"claude.ai" in page,
          "the Allow page names Claude and claude.ai (its real document)")

    csrf = re.search(rb'name="_csrf_token"[^>]*value="([^"]+)"', page).group(1).decode()
    form = urllib.parse.urlencode({**params, "_csrf_token": csrf, "decision": "allow"})
    status, headers, _ = request("POST", "/oauth/authorize", form.encode(),
                                 {"content-type": "application/x-www-form-urlencoded"}, browser)
    location = urllib.parse.urlparse(headers.get("location", ""))
    answer = dict(urllib.parse.parse_qsl(location.query))
    check(status == 302 and location.netloc == "claude.ai" and answer.get("state") == "check-state"
          and answer.get("iss") == issuer and "code" in answer,
          "Allow sends a code back to claude.ai, with state and iss")

    form = urllib.parse.urlencode({
        "grant_type": "authorization_code", "code": answer["code"], "code_verifier": verifier,
        "client_id": CLAUDE, "redirect_uri": CALLBACK, "resource": resource,
    })
    status, _, body = request("POST", "/oauth/token", form.encode(),
                              {"content-type": "application/x-www-form-urlencoded"})
    tokens = json.loads(body)
    check(status == 200 and tokens["token_type"] == "Bearer", "the code trades for tokens")

    _, body = rpc(tokens["access_token"], "tools/list")
    check(len(body["result"]["tools"]) == 11, "the access token works at /mcp")

    form = urllib.parse.urlencode({"grant_type": "refresh_token", "refresh_token": tokens["refresh_token"],
                                   "client_id": CLAUDE})
    status, _, body = request("POST", "/oauth/token", form.encode(),
                              {"content-type": "application/x-www-form-urlencoded"})
    check(status == 200, "refreshing works")
    status, _, body = request("POST", "/oauth/token", form.encode(),
                              {"content-type": "application/x-www-form-urlencoded"})
    check(status == 400 and json.loads(body)["error"] == "invalid_grant", "the old refresh token is refused")


if __name__ == "__main__":
    if not (TOKEN and USER and PASSWORD):
        sys.exit("Needs PF_TOKEN, PF_ADMIN_USER, and PF_ADMIN_PASSWORD, or a .env with them.")
    with_agent_token()
    as_claude()
    print("all good")
