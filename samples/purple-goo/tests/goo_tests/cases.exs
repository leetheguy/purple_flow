# Each case is a request to a workflow. Only the root of each metadata tree
# gets the fake provider's URL, in _meta; every child inherits it (spec 010
# log, 2026-11-09). check.exs says what each case expects.
fake =
  (input["body"] || %{})["fake_url"] ||
    "http://localhost:4000/hooks/goo-fake-llm/chat/completions"

defmodule Tree do
  def fake(tree, url) do
    # The skill sheet is off by default (spec 020 log); only "skill" turns it on.
    defaults = %{"provider_url" => url}
    Map.update(tree, "_meta", defaults, &Map.merge(defaults, &1))
  end
end

hi = [%{"role" => "user", "content" => "hi"}]
say = fn text -> %{"messages" => [%{"role" => "user", "content" => text}]} end

weather = %{
  "tools" => [
    %{
      "type" => "function",
      "function" => %{"name" => "weather", "parameters" => %{"type" => "object"}}
    }
  ]
}

say = fn text -> %{"messages" => [%{"role" => "user", "content" => text}]} end

weather = %{
  "tools" => [
    %{
      "type" => "function",
      "function" => %{"name" => "weather", "parameters" => %{"type" => "object"}}
    }
  ]
}

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
  goo.(
    "environment",
    %{
      "_meta" => %{"depth" => 0},
      "monads" => [
        %{},
        %{"_meta" => %{"provider_url" => fake <> "?which=kid2"}, "monads" => [%{}]}
      ]
    },
    %{}
  ),
  goo.(
    "skill",
    %{
      "_meta" => %{"swarm_skill" => true},
      "personas" => ["p"],
      "monads" => [%{}],
      "closing" => [%{"workflow" => "goo_test_close", "data" => %{"tag" => "c1"}}]
    },
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
  goo.("speaks", %{}, %{}),
  goo.("tool once", %{}, say.("tools:1")),
  goo.("tool chain", %{}, say.("tools:2")),
  goo.("tool failed", %{}, say.("tools:fail")),
  goo.("monad tools", %{"monads" => [%{}]}, say.("tools:1")),
  goo.("tool off", %{"_meta" => %{"run_workflow" => false}}, %{}),
  goo.("client tool", %{}, Map.merge(weather, say.("client:weather"))),
  goo.("children get no client tools", %{"monads" => [%{}]}, weather),
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
