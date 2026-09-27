# The body is either the text itself or {"text": "..."}.
text =
  case input["body"] do
    %{"text" => text} -> text
    text when is_binary(text) -> text
    _ -> ""
  end

String.replace(text, "ing", "ong")
