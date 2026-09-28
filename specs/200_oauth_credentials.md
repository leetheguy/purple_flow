# 200 — OAuth credentials

Status: implemented
Created: 2026-09-28

A credential can be an OAuth login instead of a plain value. A person connects it once on `/credentials` (the provider's "allow this?" screen), and from then on a workflow uses it like any other credential: `{{ creds.GMAIL }}` is a working access token. The app renews it when it expires. Workflows, templates, nodes, and redaction don't know OAuth exists.

Nothing is provider-specific in the app. The form comes filled in with Google's addresses because that's the common case; any OAuth 2 provider that uses the authorization-code flow with refresh tokens works by changing them.

## The credential

A credential gets a `type`: `"text"` (every credential so far, the default) or `"oauth"`.

An OAuth credential also has:

| Field | Stored | Notes |
|---|---|---|
| `oauth` | plain (jsonb) | `client_id`, `scopes`, `auth_url`, `token_url`: settings, not secrets, so the edit form can show them |
| `client_secret` | encrypted | never sent to the browser, like `key` |
| `key` | encrypted | the tokens, as JSON: `access_token`, `refresh_token`, `expires_at`. `nil` until connected |
| `oauth_error` | plain | why the last renewal was refused; `nil` when working |

So "set" means the same thing for both types: `key` is present. An OAuth credential that hasn't been connected yet is unset, and a workflow using it fails to load with the usual "isn't set" message.

Any number of OAuth credentials can exist, with any names, sharing a client or not. Each is its own login.

## Reading one: `Credentials.get/1`

The one place a name becomes a value picks by type:

- `"text"`: the decrypted value, as before.
- `"oauth"`: `PurpleFlow.Credentials.OAuth.access_token/1`. The saved access token if it has more than a minute left; otherwise it renews it first (a `refresh_token` request to `token_url`), saves the new tokens, and returns the new access token.

Renewal happens once at a time per credential: when many steps ask at the moment it expires, one renews and the rest get its result. Saving renewed tokens doesn't reload workflows.

When the provider refuses a renewal (a 4xx: access revoked, password changed, refresh token expired), `oauth_error` is set, and the step fails with `credential GMAIL needs reconnecting at /credentials (<what the provider said>)`. A network failure fails the step without marking the credential. A webhook `auth` naming an OAuth credential compares against its access token.

The access token goes into the step's secrets like any credential value, so it's redacted from every saved record. The refresh token and client secret never leave the app.

## Connecting

1. On `/credentials`, a person picks **OAuth** in the Type dropdown, fills in Name, Description, Scopes, Client ID, and Client Secret, and hits Save.
2. The app saves the credential and sends the browser to `GET /credentials/:id/connect`, which makes a random `state` and a PKCE verifier, keeps them in the signed-in session, and redirects to `auth_url` with `response_type=code`, `client_id`, `redirect_uri`, `scope`, `state`, `code_challenge` (S256), plus `access_type=offline` and `prompt=consent` (Google needs these to hand out a refresh token every time; other providers ignore them).
3. The provider sends the browser back to `GET /credentials/oauth/callback`. The app checks `state` against the session, trades the `code` for tokens (with the verifier), saves them, clears `oauth_error`, and returns to `/credentials` with "GMAIL connected". A wrong or missing `state`, a refusal (`error=access_denied`), or a failed trade returns there with the reason instead, and saves nothing.

The callback address (`redirect_uri`) is this site's `/credentials/oauth/callback`, from the endpoint's URL (`PHX_HOST`). The form shows it, click to copy, for pasting into the provider's client settings. Both routes are behind the sign-in.

## The page

Text credentials look as they do now. OAuth adds:

- **The add row** gets a Type dropdown at the start. With OAuth picked, the Value field becomes Scopes, and a second row holds Client ID and Client Secret, with the callback address under it. The authorize and token addresses come filled in with Google's and sit behind a small "change" link, which opens a third row. On a phone the fields wrap instead of squeezing onto one line.
- **In the list**, an OAuth credential shows its state where the dots would be: "connected", "not connected", or "needs reconnecting". Its buttons are **Reconnect**, Edit, and Archive. Reconnect goes through step 2 again, and it's red when the credential isn't connected or needs reconnecting.
- **Editing** shows the same fields; a blank Client Secret keeps the stored one. Saving doesn't reconnect: after changing scopes or the client, hit Reconnect.

## Tests

- **OAuth:** a fresh token is returned without a request; an expired one is renewed, saved, and returned; a refused renewal sets `oauth_error` and returns the reconnect message; many callers at once renew once.
- **Credentials:** `get` picks by type; an unconnected OAuth credential is unset.
- **Connect:** redirects to `auth_url` with the right parameters and keeps `state` in the session; the callback with the right `state` trades the code and saves the tokens; a wrong `state` or an `error` saves nothing.
- **Page:** picking OAuth shows its fields; saving one sends the browser to connect; Reconnect is red until connected.
- **Template:** a refused renewal fails the step with the reconnect message.
- **Sample:** `samples/gmail` runs end to end with Gmail stubbed, sending the built message with the credential's token, which stays out of the saved records.

A sample, `samples/gmail/`, sends an email with a Code step (Gmail wants the whole message base64url-encoded) and an HTTP step using `{{ creds.GMAIL }}`, with a README for setting up the Google side.
