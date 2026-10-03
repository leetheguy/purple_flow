defmodule PurpleFlow.OpenAIChatTest do
  # The OpenAI Chat node: specs/240_openai_chat.md.
  use ExUnit.Case, async: true

  alias PurpleFlow.Nodes.OpenAIChat

  @config %{
    "url" => "http://llm.test/v1/chat/completions",
    "body" => %{"model" => "m", "messages" => [%{"role" => "user", "content" => "hi"}]}
  }

  defp stub_sse(text) do
    Req.Test.stub(OpenAIChat, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(self(), {:request, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, text)
    end)
  end

  defp chunk(map), do: "data: #{Jason.encode!(map)}\n\n"

  # Everything the node sent to the (test process as) caller, as one text.
  defp relayed do
    receive do
      {:respond_chunk, _ref, data} -> IO.iodata_to_binary(data) <> relayed()
      {:respond_done, _ref} -> ""
    after
      0 -> flunk("the stream never ended")
    end
  end

  test "streams the answer to the caller as it came, and outputs the whole message" do
    stub_sse(
      ": OPENROUTER PROCESSING\n\n" <>
        chunk(%{
          "id" => "c1",
          "model" => "m",
          "choices" => [%{"delta" => %{"role" => "assistant", "reasoning" => "Hmm, "}}]
        }) <>
        chunk(%{"choices" => [%{"delta" => %{"reasoning" => "a greeting."}}]}) <>
        chunk(%{"choices" => [%{"delta" => %{"content" => "Hel"}}]}) <>
        chunk(%{"choices" => [%{"delta" => %{"content" => "lo!"}, "finish_reason" => "stop"}]}) <>
        chunk(%{"choices" => [], "usage" => %{"total_tokens" => 9}}) <>
        "data: [DONE]\n\n"
    )

    assert {:ok, output} = OpenAIChat.execute(nil, @config)

    assert output == %{
             "content" => "Hello!",
             "reasoning" => "Hmm, a greeting.",
             "tool_calls" => nil,
             "finish_reason" => "stop",
             "model" => "m",
             "id" => "c1",
             "usage" => %{"total_tokens" => 9}
           }

    # `stream` is always on.
    assert_received {:request, %{"stream" => true, "model" => "m"}}

    assert_received {:respond_stream, 200, %{"content-type" => "text/event-stream" <> _}}
    text = relayed()
    assert String.ends_with?(text, "data: [DONE]\n\n")
    # One `data:` per event, comments dropped, nothing else added.
    assert length(String.split(text, "\n\n", trim: true)) == 6
    refute text =~ "OPENROUTER"
  end

  test "joins tool calls from their pieces" do
    stub_sse(
      chunk(%{
        "choices" => [
          %{
            "delta" => %{
              "tool_calls" => [
                %{
                  "index" => 0,
                  "id" => "t1",
                  "type" => "function",
                  "function" => %{"name" => "look"}
                }
              ]
            }
          }
        ]
      }) <>
        chunk(%{
          "choices" => [
            %{
              "delta" => %{
                "tool_calls" => [%{"index" => 0, "function" => %{"arguments" => "{\"q\":"}}]
              }
            }
          ]
        }) <>
        chunk(%{
          "choices" => [
            %{
              "delta" => %{
                "tool_calls" => [%{"index" => 0, "function" => %{"arguments" => "1}"}}]
              },
              "finish_reason" => "tool_calls"
            }
          ]
        }) <>
        "data: [DONE]\n\n"
    )

    assert {:ok, %{"tool_calls" => [call], "finish_reason" => "tool_calls", "content" => ""}} =
             OpenAIChat.execute(nil, @config)

    assert call == %{
             "id" => "t1",
             "type" => "function",
             "function" => %{"name" => "look", "arguments" => "{\"q\":1}"}
           }
  end

  test "ends the stream with [DONE] even when the provider doesn't, and keeps named events" do
    stub_sse(
      "event: note\ndata: {\"x\": 1}\n\n" <>
        chunk(%{"choices" => [%{"delta" => %{"content" => "ok"}}]})
    )

    assert {:ok, %{"content" => "ok"}} = OpenAIChat.execute(nil, @config)

    assert relayed() ==
             "event: note\ndata: {\"x\":1}\n\n" <>
               chunk(%{"choices" => [%{"delta" => %{"content" => "ok"}}]}) <> "data: [DONE]\n\n"
  end

  test "an empty answer still answers the caller" do
    stub_sse("")
    assert {:ok, %{"content" => ""}} = OpenAIChat.execute(nil, @config)
    assert_received {:respond_stream, 200, _}
    assert relayed() == "data: [DONE]\n\n"
  end

  test "respond = false just reads the stream" do
    stub_sse(chunk(%{"choices" => [%{"delta" => %{"content" => "quiet"}}]}) <> "data: [DONE]\n\n")

    assert {:ok, %{"content" => "quiet"}} =
             OpenAIChat.execute(nil, Map.put(@config, "respond", false))

    refute_received {:respond_stream, _, _}
    refute_received {:respond_chunk, _, _}
  end

  test "a provider error mid-stream is passed on, then fails the step" do
    stub_sse(
      chunk(%{"choices" => [%{"delta" => %{"content" => "Hal"}}]}) <>
        chunk(%{"error" => %{"message" => "overloaded"}})
    )

    assert {:error, "the provider sent an error: overloaded"} = OpenAIChat.execute(nil, @config)
    assert relayed() =~ ~s(data: {"error":{"message":"overloaded"}})

    stub_sse(chunk(%{"error" => "plain"}))
    assert {:error, "the provider sent an error: \"plain\""} = OpenAIChat.execute(nil, @config)
  end

  test "a non-2xx answer goes to the caller as it is, and fails the step" do
    Req.Test.stub(OpenAIChat, fn conn ->
      conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"error" => %{"message" => "bad key"}})
    end)

    assert {:error, "HTTP 401: " <> _} = OpenAIChat.execute(nil, @config)

    assert_received {:respond,
                     %{"status" => 401, "body" => %{"error" => %{"message" => "bad key"}}}}

    refute_received {:respond_stream, _, _}

    Req.Test.stub(OpenAIChat, &Plug.Conn.send_resp(&1, 500, "not json"))
    assert {:error, "HTTP 500: not json"} = OpenAIChat.execute(nil, @config)
    assert_received {:respond, %{"status" => 500, "body" => "not json"}}
  end

  test "a failed request answers 502" do
    Req.Test.stub(OpenAIChat, &Req.Test.transport_error(&1, :econnrefused))

    assert {:error, "request failed: " <> _} = OpenAIChat.execute(nil, @config)
    assert_received {:respond, %{"status" => 502, "body" => %{"error" => %{"message" => _}}}}

    Req.Test.stub(OpenAIChat, &Req.Test.transport_error(&1, :econnrefused))

    assert {:error, "request failed: " <> _} =
             OpenAIChat.execute(nil, Map.put(@config, "respond", false))

    refute_received {:respond, _}
  end

  test "checks its config" do
    assert {:ok, _} = OpenAIChat.prepare(@config, ".", ".")
    assert {:error, "OpenAI Chat needs a url"} = OpenAIChat.prepare(%{"body" => %{}}, ".", ".")
    assert {:error, "OpenAI Chat needs a body"} = OpenAIChat.prepare(%{"url" => "u"}, ".", ".")

    assert {:error, "respond must be true or false"} =
             OpenAIChat.prepare(Map.put(@config, "respond", "yes"), ".", ".")

    assert {:error, "OpenAI Chat body must be a table, not \"x\""} =
             OpenAIChat.execute(nil, Map.put(@config, "body", "x"))
  end
end
