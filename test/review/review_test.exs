Code.require_file("review_lib.exs", __DIR__)

defmodule PurpleFlow.ReviewTest do
  # The independent review script: test/review/README.md.
  use ExUnit.Case, async: true

  alias PurpleFlow.Review

  describe "args" do
    test "takes a range and a spec, with an optional --out and --dry-run" do
      assert {:ok, %{range: "abc..def", spec: "specs/260_x.md", out: nil, dry_run: false}} =
               Review.parse_args(["abc..def", "specs/260_x.md"])

      assert {:ok, %{out: "r.md", dry_run: true}} =
               Review.parse_args(["a..b", "s.md", "--out", "r.md", "--dry-run"])
    end

    test "--context adds files the change didn't touch, as many as given" do
      assert {:ok, %{context: []}} = Review.parse_args(["a..b", "s.md"])

      assert {:ok, %{context: ["lib/run.ex", "lib/step_task.ex"]}} =
               Review.parse_args([
                 "a..b",
                 "s.md",
                 "--context",
                 "lib/run.ex",
                 "--context",
                 "lib/step_task.ex"
               ])
    end

    test "anything else is the usage" do
      assert {:error, "usage: " <> _} = Review.parse_args([])
      assert {:error, "usage: " <> _} = Review.parse_args(["a..b"])
      assert {:error, "usage: " <> _} = Review.parse_args(["a..b", "s.md", "extra"])
    end
  end

  describe ".env" do
    test "reads KEY=value lines, skipping comments and blanks, and unquoting values" do
      text = """
      # OpenRouter
      OPENROUTER_API_KEY=sk-or-123

      REVIEW_MODEL="z-ai/some-model"
      SPACED = 'x y'
      """

      assert Review.parse_env(text) == %{
               "OPENROUTER_API_KEY" => "sk-or-123",
               "REVIEW_MODEL" => "z-ai/some-model",
               "SPACED" => "x y"
             }
    end

    test "settings come from the environment first, then .env" do
      assert Review.setting("REVIEW_MODEL", %{"REVIEW_MODEL" => "from-file"}, %{}) ==
               "from-file"

      assert Review.setting("REVIEW_MODEL", %{"REVIEW_MODEL" => "from-file"}, %{
               "REVIEW_MODEL" => "from-env"
             }) == "from-env"

      assert Review.setting("REVIEW_MODEL", %{}, %{}) == nil
    end
  end

  describe "the prompt" do
    setup do
      %{
        materials: %{
          agents: "AGENTS TEXT",
          op_params: "OP-PARAMS TEXT",
          spec: {"specs/260_x.md", "SPEC TEXT"},
          diff: "DIFF TEXT",
          files: [{"lib/a.ex", "A TEXT"}, {"lib/b.ex", "B TEXT"}],
          context: [{"lib/c.ex", "UNCHANGED TEXT"}]
        }
      }
    end

    test "holds every piece, each under a heading that names it", %{materials: m} do
      prompt = Review.prompt(m)

      for {heading, text} <- [
            {"# AGENTS.md", "AGENTS TEXT"},
            {"# OP-PARAMS.md", "OP-PARAMS TEXT"},
            {"# The spec: specs/260_x.md", "SPEC TEXT"},
            {"# The diff", "DIFF TEXT"},
            {"# Changed file: lib/a.ex", "A TEXT"},
            {"# Changed file: lib/b.ex", "B TEXT"},
            {"# Context (unchanged): lib/c.ex", "UNCHANGED TEXT"}
          ] do
        assert prompt =~ heading <> "\n\n````\n" <> text <> "\n````"
      end
    end

    test "puts the spec and diff first, then the changed files, then the context",
         %{materials: m} do
      prompt = Review.prompt(m)

      positions =
        for text <- ["SPEC TEXT", "DIFF TEXT", "A TEXT", "UNCHANGED TEXT"],
            do: :binary.match(prompt, text)

      assert positions == Enum.sort(positions)
    end

    test "the request sends the instructions as the system message" do
      assert Review.body("z-ai/m", "INSTRUCTIONS", "PROMPT") == %{
               "model" => "z-ai/m",
               "messages" => [
                 %{"role" => "system", "content" => "INSTRUCTIONS"},
                 %{"role" => "user", "content" => "PROMPT"}
               ]
             }
    end
  end

  describe "asking OpenRouter" do
    test "returns the answer's text, and sends the key" do
      Req.Test.stub(Review, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer sk-or-1"]
        assert conn.request_path == "/api/v1/chat/completions"

        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"content" => "## Findings\n\nNone serious."}}]
        })
      end)

      assert {:ok, "## Findings\n\nNone serious."} =
               Review.ask("sk-or-1", %{"model" => "m"}, plug: {Req.Test, Review})
    end

    test "an error status is an error, with OpenRouter's message" do
      Req.Test.stub(Review, fn conn ->
        conn
        |> Plug.Conn.put_status(402)
        |> Req.Test.json(%{"error" => %{"message" => "Insufficient credits"}})
      end)

      assert {:error, "OpenRouter answered 402: Insufficient credits"} =
               Review.ask("k", %{}, plug: {Req.Test, Review})
    end

    test "a reply with no answer in it is an error, showing what came back" do
      Req.Test.stub(Review, &Req.Test.json(&1, %{"choices" => []}))

      assert {:error, "no answer in OpenRouter's reply: " <> _} =
               Review.ask("k", %{}, plug: {Req.Test, Review})
    end

    test "a request that fails is an error" do
      Req.Test.stub(Review, &Req.Test.transport_error(&1, :timeout))

      assert {:error, "request to OpenRouter failed: " <> _} =
               Review.ask("k", %{}, plug: {Req.Test, Review})
    end
  end

  test "the default report goes in test/review/reports, named for the range's end and the model" do
    assert Review.default_out("297abe5..c135034", "z-ai/glm-x") ==
             "test/review/reports/c135034-z-ai-glm-x.md"

    assert Review.default_out("HEAD~3", "m") == "test/review/reports/HEAD-m.md"
  end
end
