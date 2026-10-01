# 230 — String and Text credentials

Status: implemented
Created: 2026-10-01

A credential's value is either one line or several. Most are one line (an API token, a password), but some aren't: an SSH private key, a certificate, a JSON service-account file. A one-line field can't hold those: browsers drop the line breaks when you paste into one. So a plain credential is one of two types, and the person picks which on `/credentials`.

## The types

`type` is one of:

| Type | Label | Value field | Use it for |
|---|---|---|---|
| `"string"` | String | one line | tokens, passwords, IDs. The default |
| `"text"` | Text | a box that keeps line breaks | SSH keys, certificates, anything spanning lines |
| `"oauth"` | OAuth | see [200](200_oauth_credentials.md) | logins |

String and Text differ only in the page. Both are stored the same way (encrypted `key`), and `Credentials.get/1` returns the value as it was saved, line breaks and all. Workflows, templates, nodes, and redaction can't tell them apart.

Every credential that existed before this was a one-line value, so they all became String. A new credential is String unless the person picks otherwise; the **Create N missing** stubs ([220](220_missing_credentials.md)) are String too.

## The page

- The add row's dropdown has String, Text, and OAuth, in that order. Picking Text swaps the value input for a three-row box the person can resize. Saving creates the credential with the type picked.
- An existing String or Text credential's edit row has a String/Text dropdown in place of its type label, so its type can change without archiving it. Switching swaps the value field the same way. Leaving the value empty still keeps the stored one. An OAuth credential's type can't be changed there.
- A row shows its type: String, Text, or OAuth.

The value is never sent to the browser, as before: a Text credential's box opens empty when editing, the same as a String's input.

## Tests

- `Credentials`: a new credential is String by default, Text when asked, and an unknown type is refused; a Text value comes back from `get/1` with its line breaks.
- The page: the add row starts on String with a one-line input; picking Text shows the box, and saving keeps the value's line breaks and the Text type, without the value appearing in the page; an edit row can switch String to Text, which swaps the field and keeps the stored value when left empty; an OAuth row has no type dropdown.
- Missing-credential stubs are String.
