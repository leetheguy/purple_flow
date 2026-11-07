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
    # A streamed answer, as OpenRouter sends it: a keep-alive comment, some
    # thinking, the answer in pieces, the usage, and [DONE].
    defp sse(events) do
      Enum.map_join(events, "", fn
        :keep_alive -> ": OPENROUTER PROCESSING\n\n"
        :done -> "data: [DONE]\n\n"
        event -> "data: " <> Jason.encode!(event) <> "\n\n"
      end)
    end

    defp delta(fields), do: %{"choices" => [%{"delta" => fields}]}

    defp serve(body, status \\ 200) do
      Req.Test.stub(Review, fn conn ->
        send(self(), {:request_headers, conn.req_headers})
        {:ok, request, conn} = Plug.Conn.read_body(conn)
        send(self(), {:request_body, Jason.decode!(request)})

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(status, body)
      end)
    end

    defp ask(body \\ %{"model" => "m"}) do
      test = self()
      Review.ask("sk-or-1", body, &send(test, {:progress, &1}), plug: {Req.Test, Review})
    end

    defp progress do
      receive do
        {:progress, event} -> [event | progress()]
      after
        0 -> []
      end
    end

    test "streams the answer, telling progress as it comes, and returns it with the usage" do
      serve(
        sse([
          :keep_alive,
          delta(%{"reasoning" => "Let me look at the spec."}),
          delta(%{"content" => "## Findings\n\n"}),
          delta(%{"content" => "None serious."}),
          %{
            "choices" => [],
            "usage" => %{"prompt_tokens" => 100, "completion_tokens" => 7, "cost" => 0.01}
          },
          :done
        ])
      )

      assert {:ok, "## Findings\n\nNone serious.", usage} = ask()
      assert usage == %{"prompt_tokens" => 100, "completion_tokens" => 7, "cost" => 0.01}

      assert progress() == [
               {:thinking, "Let me look at the spec."},
               {:writing, "## Findings\n\n"},
               {:writing, "None serious."}
             ]
    end

    test "asks for a stream with the usage, and sends the key" do
      serve(sse([delta(%{"content" => "ok"}), :done]))

      assert {:ok, "ok", nil} = ask(%{"model" => "m"})

      assert_received {:request_body,
                       %{"model" => "m", "stream" => true, "usage" => %{"include" => true}}}

      assert_received {:request_headers, headers}
      assert {"authorization", "Bearer sk-or-1"} in headers
    end

    test "an error in the stream is an error, with OpenRouter's message" do
      serve(
        sse([delta(%{"content" => "half"}), %{"error" => %{"message" => "Provider timed out"}}])
      )

      assert {:error, "OpenRouter stopped with an error: Provider timed out"} = ask()
    end

    test "an error status is an error, with OpenRouter's message" do
      serve(Jason.encode!(%{"error" => %{"message" => "Insufficient credits"}}), 402)

      assert {:error, "OpenRouter answered 402: Insufficient credits"} = ask()
    end

    test "an error page that isn't JSON shows its start" do
      page = "<html>Bad gateway" <> String.duplicate(" ", 600) <> "</html>"
      serve(page, 502)

      assert {:error, "OpenRouter answered 502: " <> start} = ask()
      assert start == String.slice(page, 0, 500)
    end

    test "a stream that ends with no answer is an error" do
      serve(sse([:keep_alive, :done]))

      assert {:error, "OpenRouter's stream ended with no answer"} = ask()
    end

    test "a request that fails is an error" do
      Req.Test.stub(Review, &Req.Test.transport_error(&1, :timeout))

      assert {:error, "request to OpenRouter failed: " <> _} = ask()
    end
  end

  describe "telling progress" do
    test "the status line says what's happening, how long it's been, and how much is written" do
      assert Review.status_line(%{phase: :waiting, words: 0}, 42_000) ==
               "Waiting for the model to start… 0:42"

      assert Review.status_line(%{phase: :thinking, words: 300}, 70_000) ==
               "Thinking: 300 words, 1:10 (about 257 words a minute)"

      assert Review.status_line(%{phase: :writing, words: 1240, thought: 300}, 3_735_000) ==
               "Writing the report: 1,240 words, 1:02:15 (thought 300 words first)"
    end

    test "at the very start, or with nothing thought first, the line still reads right" do
      assert Review.status_line(%{phase: :thinking, words: 0}, 0) ==
               "Thinking: 0 words, 0:00 (about 0 words a minute)"

      assert Review.status_line(%{phase: :writing, words: 5, thought: 0}, 9_000) ==
               "Writing the report: 5 words, 0:09"
    end

    test "the clock counts minutes and seconds up to the hour" do
      assert Review.status_line(%{phase: :waiting, words: 0}, 60_000) ==
               "Waiting for the model to start… 1:00"

      assert Review.status_line(%{phase: :waiting, words: 0}, 3_599_000) ==
               "Waiting for the model to start… 59:59"
    end

    test "one word is one word, and an hour shows as one" do
      assert Review.status_line(%{phase: :writing, words: 1, thought: 1}, 3_600_000) ==
               "Writing the report: 1 word, 1:00:00 (thought 1 word first)"
    end

    test "each piece adds to its phase's words; a new phase starts its count over" do
      start = %{phase: :waiting, words: 0, thought: 0}

      thinking = start |> Review.advance(:thinking, 3) |> Review.advance(:thinking, 4)
      assert thinking == %{phase: :thinking, words: 7, thought: 0}

      writing = thinking |> Review.advance(:writing, 2) |> Review.advance(:writing, 5)
      assert writing == %{phase: :writing, words: 7, thought: 7}

      assert Review.advance(start, :writing, 2) == %{phase: :writing, words: 2, thought: 0}
    end

    test "counting words in each piece as it arrives" do
      assert Review.words("## Findings\n\nNone serious.") == 4
      assert Review.words("   ") == 0
    end

    test "the summary gives the time, the tokens, the cost, and where the report is" do
      assert Review.summary(
               185_000,
               %{"prompt_tokens" => 131_766, "completion_tokens" => 2_480, "cost" => 0.0912},
               "r.md"
             ) ==
               "Done in 3:05. 131,766 tokens in, 2,480 out, $0.0912. Report saved to r.md"

      assert Review.summary(5_000, nil, "r.md") == "Done in 0:05. Report saved to r.md"
    end
  end

  test "the default report goes in test/review/reports, named for the range's end and the model" do
    assert Review.default_out("297abe5..c135034", "z-ai/glm-x") ==
             "test/review/reports/c135034-z-ai-glm-x.md"

    assert Review.default_out("HEAD~3", "m") == "test/review/reports/HEAD-m.md"
  end
end
