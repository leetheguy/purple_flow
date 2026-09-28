# Send email from Gmail

Sends email as you, from your own Gmail or Google Workspace mailbox, through
Gmail's API. No SMTP and no mail service. Messages land in your Sent folder.

## Set up (once)

**In Google Cloud Console** (console.cloud.google.com):

1. Pick or create a project, and turn on the **Gmail API** (APIs & Services →
   Library → Gmail API → Enable).
2. Set up the **OAuth consent screen**. On Google Workspace, choose
   **Internal**: Google skips its review, and your login doesn't expire every
   7 days (it does for External apps still in Testing).
3. Create an **OAuth client ID** (APIs & Services → Credentials → Create
   credentials → OAuth client ID), type **Web application**. Under
   **Authorized redirect URIs**, add the Redirect URI shown on PurpleFlow's
   Credentials page when you pick Type: OAuth (it's
   `https://<your site>/credentials/oauth/callback`; click it to copy).
4. Keep the **Client ID** and **Client secret** it shows you.

**In PurpleFlow**, on the Credentials page:

1. Type: **OAuth**. Name: `GMAIL`. Scopes:
   `https://www.googleapis.com/auth/gmail.send`. Paste the Client ID and
   Client secret.
2. Save. Google asks you to allow it; click Allow. You're back on the
   Credentials page, and `GMAIL` says **connected**.

That's all. If it ever says **needs reconnecting** (you revoked access or
changed your password), press its red Reconnect button.

## Use it

Copy this folder into your workflows folder, then:

```sh
curl -X POST localhost:4000/hooks/send-email -H 'content-type: application/json' \
  -d '{"to": "someone@example.com", "subject": "Hello", "text": "Sent from PurpleFlow."}'
```

`to`, `cc`, and `bcc` take one address or a list. `reply_to` and `from` (a
send-as alias set up in Gmail) are optional.

Several accounts? Make one OAuth credential per account (`LEE_GMAIL`,
`SUPPORT_GMAIL`, ...) and point each workflow's `send.toml` at the one it
should send as.

## How it works

- `build.exs` puts the email together the way Gmail's API wants it: the whole
  message, base64url-encoded, as `{"raw": ...}`.
- `send.toml` is a plain HTTP step. `{{ creds.GMAIL }}` is a working access
  token; the app renews it behind the scenes, and hides it from run records
  like any credential.
