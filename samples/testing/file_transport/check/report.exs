# What each step saw, for the harness to check.
%{
  "form" => steps["form"]["output"]["body"],
  "body" => Map.take(steps["body"]["output"]["headers"], ["content-type", "content-length"]),
  "download" => steps["download"]["output"]
}
