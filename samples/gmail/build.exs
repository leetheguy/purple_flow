# Gmail's API takes the whole email (headers, a blank line, the body) as one
# base64url-encoded string: {"raw": "..."}. This builds it.
#
# Input: the webhook body, {"to", "subject", "text"}. "to" may be one address
# or a list. Optional: "cc", "bcc", "reply_to", and "from" (a send-as alias;
# without it, Gmail uses the connected account).
email = input["body"]

addresses = fn value -> value |> List.wrap() |> Enum.join(", ") end

# Text outside plain ASCII (accents, emoji) has to be encoded to go in a header.
encoded = fn text -> "=?UTF-8?B?" <> Base.encode64(text) <> "?=" end

# The body goes as base64 too, in lines of at most 76 characters.
body =
  (email["text"] || "")
  |> Base.encode64()
  |> then(&Regex.scan(~r/.{1,76}/, &1))
  |> Enum.map_join("\r\n", &hd/1)

headers =
  [
    {"From", email["from"]},
    {"To", addresses.(email["to"])},
    {"Cc", email["cc"] && addresses.(email["cc"])},
    {"Bcc", email["bcc"] && addresses.(email["bcc"])},
    {"Reply-To", email["reply_to"]},
    {"Subject", encoded.(email["subject"] || "")},
    {"MIME-Version", "1.0"},
    {"Content-Type", "text/plain; charset=UTF-8"},
    {"Content-Transfer-Encoding", "base64"}
  ]
  |> Enum.reject(fn {_name, value} -> value in [nil, ""] end)
  |> Enum.map_join(fn {name, value} -> "#{name}: #{value}\r\n" end)

%{"raw" => Base.url_encode64(headers <> "\r\n" <> body, padding: false)}
