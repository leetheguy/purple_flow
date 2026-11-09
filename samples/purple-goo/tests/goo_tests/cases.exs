# Each case is a request to a workflow. Every metadata tree gets the fake
# provider's URL, at every level, since a child inherits nothing (spec 010
# rule 2). check.exs says what each case expects.
fake =
  (input["body"] || %{})["fake_url"] ||
    "http://localhost:4000/hooks/goo-fake-llm/chat/completions"

defmodule Tree do
  def fake(tree, url) do
    tree
    |> Map.put("provider_url", url)
    |> Map.update("monads", [], fn monads -> Enum.map(monads, &fake(&1, url)) end)
  end
end

hi = [%{"role" => "user", "content" => "hi"}]

goo = fn name, metadata, extra ->
  body =
    Map.merge(
      %{"model" => "m1", "messages" => hi, "metadata" => Tree.fake(metadata, fake)},
      extra
    )

  %{"case" => name, "workflow" => "goo", "body" => body}
end

[
  goo.("passthrough", %{}, %{}),
  goo.("personas", %{"personas" => ["p1", "p2"]}, %{}),
  goo.(
    "data",
    %{
      "data" => [
        %{"workflow" => "goo_test_data", "data" => %{"kind" => "text", "x" => "a"}},
        %{"workflow" => "goo_test_data", "data" => %{"kind" => "message"}},
        %{"workflow" => "goo_test_data", "data" => %{"kind" => "map"}},
        "goo_test_data"
      ]
    },
    %{}
  ),
  goo.("child", %{"personas" => ["parent"], "monads" => [%{"personas" => ["kid"]}]}, %{}),
  goo.(
    "grandchild",
    %{"monads" => [%{"personas" => ["kid"], "monads" => [%{"personas" => ["grandkid"]}]}]},
    %{}
  ),
  goo.("child model", %{"monads" => [%{"model" => "m2"}, %{}]}, %{}),
  goo.(
    "opening",
    %{
      "personas" => ["p"],
      "opening" => [
        %{"workflow" => "goo_test_open", "data" => %{"persona" => "o1"}},
        %{"workflow" => "goo_test_open", "data" => %{"persona" => "o2"}}
      ]
    },
    %{}
  ),
  goo.(
    "closing",
    %{
      "personas" => ["p"],
      "data" => [%{"workflow" => "goo_test_data", "data" => %{"kind" => "text", "x" => "a"}}],
      "monads" => [%{}],
      "closing" => [
        %{"workflow" => "goo_test_close", "data" => %{"tag" => "c1"}},
        %{"workflow" => "goo_test_close", "data" => %{"tag" => "c2"}}
      ]
    },
    %{}
  ),
  goo.("failed child", %{"monads" => [%{"model" => "boom"}]}, %{}),
  goo.(
    "failed data",
    %{"data" => [%{"workflow" => "goo_test_data", "data" => %{"kind" => "boom"}}]},
    %{}
  ),
  goo.(
    "failed opening",
    %{"opening" => [%{"workflow" => "goo_test_open", "data" => %{"fail" => true}}]},
    %{}
  ),
  goo.("failed root", %{}, %{"model" => "boom"}),
  %{"case" => "empty map", "workflow" => "goo_map", "body" => %{"calls" => []}},
  %{
    "case" => "empty chain",
    "workflow" => "goo_chain",
    "body" => %{"calls" => [], "frame" => %{"x" => 1}}
  }
]
