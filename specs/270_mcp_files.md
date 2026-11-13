# 270 — Files over MCP

Status: draft
Created: 2026-11-13

Claude on the web, on the phone, and in Claude Code can reach the workflows folder as an MCP connector. A person adds `https://<PHX_HOST>/mcp` as a custom connector in claude.ai, signs in to PurpleFlow when Claude asks, clicks **Allow**, and Claude gets the files service's API as tools.

```
Claude  →  POST /mcp  →  PurpleFlow  →  dufs (/fs/)
```

The bridge is part of the app, not a program of its own: same container, same sign-in, nothing new to run.

## Tools

Each tool is one dufs request, made the same way `/fs/` makes it ([090](090_workflow_files.md)): to `PURPLEFLOW_FILES_URL`, with dufs's own login added. The tools add nothing dufs doesn't do.

| Tool | dufs request | Returns |
|---|---|---|
| `list` | `GET path/?json` | the folder's entries: `name`, `type` (`file` or `dir`), `size`, `mtime` (ISO 8601) |
| `search` | `GET path/?q=QUERY&json` | entries whose name contains `query`, anywhere under `path`, with paths relative to `path` |
| `read` | `GET path`, with `Range` when `offset` and `length` are given | the content: text if it's valid UTF-8, otherwise base64 with `encoding: "base64"` |
| `stat` | `HEAD path` | `exists`, and for something that exists: `type`, `size`, `mtime`, `etag` |
| `hash` | `GET path?hash` | the file's SHA-256, in hex |
| `write` | `PUT path` | nothing. Creates missing folders, replaces an existing file. `content` is text, or base64 with `encoding: "base64"` |
| `append` | `PATCH path` with `X-Update-Range: append` | nothing. Adds `content` to the end of an existing file |
| `mkdir` | `MKCOL path` | nothing |
| `copy` | `COPY path` with `Destination` | nothing |
| `move` | `MOVE path` with `Destination` | nothing. Also renames |
| `delete` | `DELETE path` | nothing. A folder goes with everything in it |

- `read` returns the whole file unless `offset` and `length` are given; its description says so, so an agent can read a large file a piece at a time.
- `copy` and `move` onto an existing path do what dufs does (the tests record it).
- dufs's WebDAV-only requests (`PROPFIND`, `PROPPATCH`, `LOCK`, `UNLOCK`) have no tools: `list` and `stat` cover what they show, and locks mean nothing to an agent making one request at a time. `?zip` has none either: a zip is no use to an agent.
- Each tool's description says what it does, what each argument means, and points to `GET /agents` for how workflows are written, so an agent needs no other guide to start.

### Paths

A tool's `path` is relative to the workflows folder; a leading `/` means the same thing. It's split on `/`, and each segment is URL-encoded before it's joined to `/fs/`, so `?`, `#`, `%`, and spaces in a name are part of the name, never a query. A path with a `..` or `.` segment, a `\`, or a NUL is refused before any request is made. `Destination` for `copy` and `move` is built the same way. (dufs keeps paths inside its folder on its own, and `.git` is covered by a mount, [090](090_workflow_files.md); this check means a bad path never gets that far.)

### Results and errors

A dufs answer outside 2xx is a tool error (`isError: true`) with the status and a short message: 404 is "nothing at that path"; anything else is the status and dufs's body, cut to 500 characters. If dufs can't be reached, or there's no files service (dev, test), the tool error says so. Requests time out after 60 seconds, like `/fs/`. No result or error contains dufs's login.

## The MCP endpoint

`POST /mcp`, MCP's Streamable HTTP transport, answering every request with plain JSON (no event stream). It keeps no sessions: each request stands alone, so a restart drops nothing.

It speaks both generations of the protocol, because clients haven't all moved. A request whose `params._meta` names `io.modelcontextprotocol/protocolVersion` is the newer kind; anything else is the older kind.

- **`2026-07-28`:** `server/discover`, `tools/list`, and `tools/call`. Results carry `resultType: "complete"` and `_meta.io.modelcontextprotocol/serverInfo`; `server/discover` and `tools/list` also carry `ttlMs` (`3600000`) and `cacheScope: "private"`. The HTTP headers must match the body: `MCP-Protocol-Version` the `_meta` version, `Mcp-Method` the method, and, for `tools/call`, `Mcp-Name` the tool's name (decoded first when it's sent as `=?base64?…?=`). A missing or mismatched header is `400` with `-32020`. A version this server doesn't speak is `400` with `-32022`, listing the ones it does. An unknown method is `404` with `-32601`.
- **`2025-06-18` and `2025-11-25`:** `initialize` (answered with the version the client asked for when it's one of these, otherwise `2025-11-25`), `notifications/initialized`, `ping`, `tools/list`, and `tools/call`. No `Mcp-Session-Id` is issued, and one that's sent is ignored. An unknown method is `-32601`, with `200`.

`server/discover` lists all three versions as `supportedVersions`. The server's capabilities are `tools` only. A notification gets `202` with no body. A tool that doesn't exist, or arguments that don't fit its schema, are `-32602`. A body that isn't JSON-RPC is `400` with `-32600`. `GET` and `DELETE` on `/mcp` are `405`. A request with an `Origin` header naming another site is `403` (MCP requires this, against DNS rebinding); Claude's own requests come from its servers and send none.

A request gets through with either:

- an **access token** from the sign-in below, or
- `Authorization: Bearer <PURPLEFLOW_AGENT_TOKEN>`, the same token that already grants `/fs/` (for Claude Code and other clients that can send a header).

Anything else is `401` with `WWW-Authenticate: Bearer resource_metadata="https://<host>/.well-known/oauth-protected-resource/mcp"`, and nothing reaches dufs. Requests from the runner's subnet are refused like every other request ([100](100_runner_container.md)).

## Signing in

claude.ai only connects to a remote server through OAuth, so PurpleFlow is its own OAuth authorization server, for one person: the admin who signs in at `/login`. The parts:

**Discovery.** Two public JSON documents tell Claude where everything is.

- `GET /.well-known/oauth-protected-resource/mcp` (and the same at `/.well-known/oauth-protected-resource`): `resource` is `https://<host>/mcp`, exactly the URL the person pastes into Claude; `authorization_servers` is `["https://<host>"]`; `scopes_supported` is `["files"]`.
- `GET /.well-known/oauth-authorization-server`: `issuer` `https://<host>`, the `authorize` and `token` addresses, `response_types_supported: ["code"]`, `grant_types_supported: ["authorization_code", "refresh_token"]`, `code_challenge_methods_supported: ["S256"]`, `token_endpoint_auth_methods_supported: ["none"]`, `client_id_metadata_document_supported: true`, `authorization_response_iss_parameter_supported: true`, `scopes_supported: ["files"]`.

**Which app is asking.** PurpleFlow takes Client ID Metadata Documents, the way MCP and Claude prefer: the app's `client_id` is an `https` URL, and PurpleFlow fetches it to learn the app's name and its allowed `redirect_uris`. The fetch is one `GET`, `https` only, no redirects followed, 5 seconds, and at most 5 KB; the document's own `client_id` must equal the URL. There's nothing to register in advance and nothing stored about apps until one is allowed.

**Allowing it: `GET /oauth/authorize`.** Behind the sign-in, so a person who isn't signed in goes through `/login` first and comes back. It checks the request (`response_type=code`, a `client_id` document that loads, a `redirect_uri` listed in it, an S256 `code_challenge`, and `resource`, when given, equal to the `/mcp` URL), then shows one page:

> **Claude** wants to read and change the files in your workflows folder.
> It will be sent back to **claude.ai**.
> [Allow] [Deny]

The name comes from the app's document, and the host from the `redirect_uri`, so a look-alike app can't hide where it sends you. A request that fails the checks shows what's wrong and sends nothing back, since the `redirect_uri` can't be trusted. **Allow** (a `POST`, with the form's CSRF token) sends the browser to the `redirect_uri` with a `code`, the `state` it came with, and `iss`. **Deny** sends `error=access_denied` the same way.

**Trading for tokens: `POST /oauth/token`.** Form-encoded, no client secret (Claude is a public client; PKCE does that job).

- `grant_type=authorization_code`: the `code`, the `code_verifier`, and the same `client_id` and `redirect_uri`. A code works once, within 60 seconds. The answer is an `access_token` (good for one hour), a `refresh_token`, `token_type: "Bearer"`, `expires_in`, and `scope: "files"`.
- `grant_type=refresh_token`: a new access token and a new refresh token; the old refresh token stops working.
- Errors are RFC 6749's: `invalid_grant` for a used, expired, or unknown code or refresh token, or a verifier that doesn't match; `invalid_request` for a missing field; `unsupported_grant_type`.

**What's stored.** Each allowed app is one row in `mcp_connections`: the app's name and `client_id`, and hashes (SHA-256) of its current code, access token, and refresh token, with their expiry times and when it was last used. Tokens are 32 random bytes, shown once and never stored in the clear, so a copy of the database can't be used to connect.

**Disconnecting.** `/credentials` gets a short **Connected apps** list: each app's name, when it was connected and last used, and a **Disconnect** button, which deletes its row; its tokens stop working at once. Changing the admin password doesn't disconnect apps (it signs browsers out, as before); Disconnect does.

## Log

## Tests

Endpoint
- a request without a token, or with a wrong one, is 401 with `WWW-Authenticate` naming the resource metadata, and dufs gets nothing
- an access token from the sign-in works; `PURPLEFLOW_AGENT_TOKEN` works
- an expired access token, or one from a disconnected app, is 401
- `initialize` answers with the version asked for when supported, and `2025-11-25` otherwise; `notifications/initialized` is 202; `ping` answers
- `server/discover` lists the supported versions and the `tools` capability
- `tools/list` lists the eleven tools, in a fixed order, each with an input schema, in both generations
- a newer request with a missing or mismatched `MCP-Protocol-Version`, `Mcp-Method`, or `Mcp-Name` is 400 with `-32020`; a base64-encoded `Mcp-Name` that matches is accepted
- a newer request with an unsupported version is 400 with `-32022` and the supported list
- an unknown method is 404 with `-32601` for a newer request, and `-32601` with 200 for an older one
- an unknown tool or missing argument is `-32602`; a body that isn't JSON-RPC is 400
- `GET` and `DELETE` on `/mcp` are 405; an `Origin` from another site is 403

Tools (against dufs stubbed as in `files_proxy_test.exs`, each request checked)
- each tool sends the dufs request in the table, with dufs's login and without the caller's token
- `list` and `search` return entries; `search` paths are relative to the folder searched
- `read` returns text as text and binary as base64 with the exact bytes; with `offset` and `length` it sends `Range`
- `stat` reports `exists: false` for a 404
- `write` with base64 content sends the exact bytes
- a 404 from dufs is a tool error saying nothing is there; another status includes dufs's body, cut to 500 characters
- with no files service, or dufs unreachable, the tool error says so
- no tool result or error contains dufs's login

Paths
- a name with a space, `?`, `#`, or `%` reaches the file with that exact name
- `..`, `.`, `\`, and NUL in a path are refused, and nothing reaches dufs; the same for a `copy` or `move` destination

Discovery
- both metadata documents are public and hold the values above, with the site's own address

Authorize
- someone not signed in is sent to sign in, then back to the same request
- a valid request shows the app's name and the `redirect_uri`'s host
- a `client_id` that isn't `https`, doesn't load, is too large, redirects, or whose document names another `client_id` is refused, with nothing sent to the `redirect_uri`
- a `redirect_uri` not in the document, a missing or non-S256 `code_challenge`, or a `resource` that isn't `/mcp` is refused the same way
- Allow redirects with `code`, the same `state`, and `iss`; Deny redirects with `error=access_denied`
- Allow without a valid CSRF token does nothing

Token
- the right code and verifier get an access token and a refresh token that work at `/mcp`
- a wrong verifier, a used code, a code past 60 seconds, or a different `client_id` or `redirect_uri` is `invalid_grant`
- a refresh token gets new tokens, and the old refresh token then fails with `invalid_grant`
- an unknown grant type is `unsupported_grant_type`; a missing field is `invalid_request`
- the database holds no token or code in the clear

Disconnecting
- `/credentials` lists connected apps; Disconnect removes one, and its tokens fail at once

Deployed (against the real compose stack)
- claude.ai connects at `https://<host>/mcp`, shows the Allow page, and lists and reads the workflows folder
- a `write` from Claude is live in the app within a couple of seconds, like any save through `/fs/`

## Tasks

- [x] Tools: `PurpleFlowWeb.MCP.Tools`, the eleven dufs requests, paths, and errors
- [x] Endpoint: `POST /mcp` for both generations, the agent token, the 401 challenge, and the protected resource metadata
- [x] Connections: the `mcp_connections` table, codes and tokens, and access tokens at `/mcp`
- [x] Authorize: the authorization server metadata, the client document fetch, and the Allow page
- [x] Token: `POST /oauth/token`, both grants
- [ ] Connected apps on `/credentials`
- [ ] Docs (README, `samples/AGENTS.md`, the skill sheet, 000), the deployed check, the independent review, and `implemented`
