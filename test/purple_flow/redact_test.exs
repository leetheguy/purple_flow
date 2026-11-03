defmodule PurpleFlow.RedactTest do
  use ExUnit.Case, async: true

  alias PurpleFlow.Redact

  doctest Redact

  test "short secrets are left alone, so ordinary data isn't blanked out" do
    assert Redact.redact("on and on", ["on"]) == "on and on"
  end

  test "map keys are redacted too, and other values pass through" do
    assert Redact.redact(%{"s3cret" => 1, "n" => 2}, ["s3cret"]) ==
             %{"[redacted]" => 1, "n" => 2}
  end
end
