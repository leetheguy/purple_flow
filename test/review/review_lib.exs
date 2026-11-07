defmodule PurpleFlow.Review do
  @moduledoc """
  An independent review of a change by another AI, through OpenRouter. It
  sends the review instructions, the project's rules, the spec, the diff,
  and the changed files, and saves the answer as a report. The reviewer
  only reads: it gets text and returns text, with no tools and no access to
  the code. See `test/review/README.md` and `OP-PARAMS.md` section 5.

  It lives in `test/review`, isn't compiled into the app, and never ships.
  `test/review/review.exs` runs it.
  """

  @url "https://openrouter.ai/api/v1/chat/completions"
  @usage "usage: test/review/review.sh RANGE SPEC [--context FILE]... [--out REPORT] [--dry-run]\n" <>
           "  e.g. test/review/review.sh 297abe5..c135034 specs/260_file_transport.md"

  @doc """
  Reads the command line: a git range, a spec's path, and the options
  `--context` (a file the change didn't touch but relies on; any number),
  `--out` (where the report goes), and `--dry-run` (save what would be
  sent instead of sending it).
  """
  def parse_args(argv) do
    case OptionParser.parse(argv, strict: [out: :string, dry_run: :boolean, context: :keep]) do
      {opts, [range, spec], []} ->
        {:ok,
         %{
           range: range,
           spec: spec,
           out: opts[:out],
           dry_run: opts[:dry_run] || false,
           context: Keyword.get_values(opts, :context)
         }}

      _ ->
        {:error, @usage}
    end
  end

  @doc """
  The `KEY=value` lines of a `.env` file, as a map. Blank lines and `#`
  comments are skipped, and quotes around a value are taken off.
  """
  def parse_env(text) do
    for line <- String.split(text, "\n"),
        line = String.trim(line),
        line != "" and not String.starts_with?(line, "#"),
        [key, value] <- [String.split(line, "=", parts: 2)],
        into: %{},
        do: {String.trim(key), unquote_value(String.trim(value))}
  end

  defp unquote_value(<<q, rest::binary>> = value) when q in [?", ?'] do
    if String.ends_with?(rest, <<q>>), do: String.slice(rest, 0..-2//1), else: value
  end

  defp unquote_value(value), do: value

  @doc "A setting from the environment (`env`) if it's there, else from `.env` (`file`)."
  def setting(name, file, env), do: Map.get(env, name) || Map.get(file, name)

  @doc """
  The user message: every piece of the review's material, each under a
  heading that names it, in the order a reviewer should read them.
  `materials` has `:agents`, `:op_params`, `:spec` (`{path, text}`),
  `:diff`, `:files`, and `:context` (each `[{path, text}]`).
  """
  def prompt(materials) do
    {spec_path, spec} = materials.spec

    sections =
      [
        {"AGENTS.md", materials.agents},
        {"OP-PARAMS.md", materials.op_params},
        {"The spec: #{spec_path}", spec},
        {"The diff", materials.diff}
      ] ++
        for({path, text} <- materials.files, do: {"Changed file: #{path}", text}) ++
        for({path, text} <- materials.context, do: {"Context (unchanged): #{path}", text})

    # Four backticks, so a file's own ``` fences don't end the block.
    Enum.map_join(sections, "\n\n", fn {heading, text} ->
      "# #{heading}\n\n````\n#{text}\n````"
    end)
  end

  @doc "The request body for OpenRouter's chat API (OpenAI's format)."
  def body(model, instructions, prompt) do
    %{
      "model" => model,
      "messages" => [
        %{"role" => "system", "content" => instructions},
        %{"role" => "user", "content" => prompt}
      ]
    }
  end

  # Where a streamed answer has got to.
  @stream %{parser: PurpleFlow.StreamParser.new(), text: [], usage: nil, error: nil}

  @doc """
  Sends `body` to OpenRouter with the API key and streams the answer back.
  Each piece is handed to `on_progress` as it arrives, as
  `{:thinking, text}` (a reasoning model's thinking, not part of the
  report) or `{:writing, text}`. Returns `{:ok, report, usage}`, where
  `usage` is OpenRouter's token counts and cost (or `nil`).
  `req_options` are extra `Req` options (tests pass a `:plug`).
  """
  def ask(key, body, on_progress, req_options \\ []) do
    body = Map.merge(body, %{"stream" => true, "usage" => %{"include" => true}})

    into = fn {:data, data}, {req, resp} ->
      if resp.status == 200 do
        stream = Req.Response.get_private(resp, :stream, @stream)
        {events, parser} = PurpleFlow.StreamParser.parse("sse", stream.parser, data)
        stream = Enum.reduce(events, %{stream | parser: parser}, &event(&1, &2, on_progress))
        resp = Req.Response.put_private(resp, :stream, stream)
        {if(stream.error, do: :halt, else: :cont), {req, resp}}
      else
        {:cont, {req, %{resp | body: resp.body <> data}}}
      end
    end

    options =
      [
        url: @url,
        method: :post,
        json: body,
        auth: {:bearer, key},
        into: into,
        # OpenRouter sends a keep-alive comment while the model works, so
        # this long with nothing at all means the connection is dead.
        receive_timeout: 300_000,
        retry: false
      ] ++ req_options

    case Req.request(options) do
      {:ok, %Req.Response{status: 200} = resp} ->
        case Req.Response.get_private(resp, :stream, @stream) do
          %{error: message} when is_binary(message) ->
            {:error, "OpenRouter stopped with an error: #{message}"}

          %{text: []} ->
            {:error, "OpenRouter's stream ended with no answer"}

          %{text: text, usage: usage} ->
            {:ok, text |> Enum.reverse() |> IO.iodata_to_binary(), usage}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "OpenRouter answered #{status}: #{error_message(body)}"}

      {:error, error} ->
        {:error, "request to OpenRouter failed: #{Exception.message(error)}"}
    end
  end

  # One server-sent event of OpenRouter's stream (OpenAI's chunk format).
  defp event(%{"data" => %{"error" => error}}, stream, _on_progress),
    do: %{stream | error: error_message(%{"error" => error})}

  defp event(%{"data" => %{} = chunk}, stream, on_progress) do
    delta = get_in(chunk, ["choices", Access.at(0), "delta"]) || %{}
    stream = if usage = chunk["usage"], do: %{stream | usage: usage}, else: stream

    if is_binary(delta["reasoning"]) and delta["reasoning"] != "",
      do: on_progress.({:thinking, delta["reasoning"]})

    case delta["content"] do
      text when is_binary(text) and text != "" ->
        on_progress.({:writing, text})
        %{stream | text: [text | stream.text]}

      _ ->
        stream
    end
  end

  # "[DONE]", and anything else that isn't a chunk.
  defp event(_event, stream, _on_progress), do: stream

  defp error_message(%{"error" => %{"message" => message}}), do: message

  defp error_message(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"message" => message}}} -> message
      _ -> String.slice(body, 0, 500)
    end
  end

  defp error_message(body), do: inspect(body, limit: 20)

  @doc """
  The live status line: what's happening, how long it's been, and how
  much has come back. `progress` has `:phase` (`:waiting`, `:thinking`, or
  `:writing`), `:words` in that phase, and `:thought` (words of thinking
  before writing began).
  """
  def status_line(%{phase: :waiting}, elapsed_ms),
    do: "Waiting for the model to start… #{clock(elapsed_ms)}"

  def status_line(%{phase: :thinking, words: words}, elapsed_ms) do
    rate = if elapsed_ms > 0, do: round(words * 60_000 / elapsed_ms), else: 0

    "Thinking: #{count_words(words)}, #{clock(elapsed_ms)} " <>
      "(about #{thousands(rate)} words a minute)"
  end

  def status_line(%{phase: :writing, words: words} = progress, elapsed_ms) do
    thought = Map.get(progress, :thought, 0)
    first = if thought > 0, do: " (thought #{count_words(thought)} first)", else: ""
    "Writing the report: #{count_words(words)}, #{clock(elapsed_ms)}#{first}"
  end

  @doc "How many words are in `text`, for counting a stream's pieces."
  def words(text), do: text |> String.split() |> length()

  @doc "The last line: how long it took, the tokens and cost, and where the report is."
  def summary(elapsed_ms, usage, out) do
    tokens =
      case usage do
        %{"prompt_tokens" => input, "completion_tokens" => output} ->
          cost = if is_number(usage["cost"]), do: ", $#{usage["cost"]}", else: ""
          " #{thousands(input)} tokens in, #{thousands(output)} out#{cost}."

        _ ->
          ""
      end

    "Done in #{clock(elapsed_ms)}.#{tokens} Report saved to #{out}"
  end

  defp count_words(1), do: "1 word"
  defp count_words(n), do: "#{thousands(n)} words"

  defp clock(ms) do
    seconds = div(ms, 1000)
    {h, m, s} = {div(seconds, 3600), div(rem(seconds, 3600), 60), rem(seconds, 60)}
    pad = &String.pad_leading(Integer.to_string(&1), 2, "0")
    if h > 0, do: "#{h}:#{pad.(m)}:#{pad.(s)}", else: "#{m}:#{pad.(s)}"
  end

  defp thousands(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  @doc """
  Where the report goes unless `--out` says: `test/review/reports/`, named
  for the range's end and the model.
  """
  def default_out(range, model) do
    name =
      Enum.map_join(
        [range_end(range) || "HEAD", model],
        "-",
        &String.replace(&1, ~r/[^\w.]+/, "-")
      )

    "test/review/reports/#{name}.md"
  end

  @doc """
  Runs a review from the command line. Returns `:ok` or `{:error, message}`.
  `req_options` go to `ask/4`.
  """
  def main(argv, req_options \\ []) do
    file = read_env_file("test/review/.env")
    env = System.get_env()

    with {:ok, args} <- parse_args(argv),
         :ok <- say("Reading the spec, the diff (#{args.range}), and the changed files…"),
         {:ok, materials} <- materials(args) do
      prompt = prompt(materials)
      instructions = File.read!("test/review/instructions.md")
      tokens = div(byte_size(instructions <> prompt), 4)

      say(
        "#{count(materials.files, "changed file")}, #{count(materials.context, "context file")}, " <>
          "and the diff: about #{thousands(tokens)} tokens"
      )

      if args.dry_run do
        out = args.out || default_out(args.range, "dry-run")
        save(out, instructions <> "\n\n" <> prompt)
        say("Nothing sent. What would be sent is in #{out}")
      else
        with {:ok, key} <- required("OPENROUTER_API_KEY", file, env),
             {:ok, model} <- required("REVIEW_MODEL", file, env) do
          out = args.out || default_out(args.range, model)
          send_review(key, model, instructions, prompt, out, req_options)
        end
      end
    end
  end

  # Streams the review into `out` as it arrives, with a status line that
  # updates every second, so a stop partway leaves what came so far.
  defp send_review(key, model, instructions, prompt, out, req_options) do
    File.mkdir_p!(Path.dirname(out))
    {:ok, report} = File.open(out, [:write, :utf8])
    started = now()

    say("Sending to #{model} through OpenRouter.")
    say("The report is written to #{out} as it arrives. Press Ctrl-C twice to stop.")

    ticker =
      spawn_link(fn -> tick(%{phase: :waiting, words: 0, thought: 0}, started, started) end)

    on_progress = fn
      {:thinking, text} ->
        send(ticker, {:thinking, words(text)})

      {:writing, text} ->
        IO.write(report, text)
        send(ticker, {:writing, words(text)})
    end

    result = ask(key, body(model, instructions, prompt), on_progress, req_options)
    stop_ticker(ticker)
    File.close(report)
    elapsed = now() - started

    case result do
      {:ok, _text, usage} ->
        say(summary(elapsed, usage, out))

      {:error, message} ->
        if File.stat!(out).size == 0 do
          File.rm(out)
          {:error, message}
        else
          {:error, "#{message}\nWhat arrived before it stopped is in #{out}"}
        end
    end
  end

  # Redraws the status line once a second, however fast pieces arrive, and
  # at once when a phase starts. On a terminal it rewrites one line in
  # place; otherwise (output sent to a file) it adds a line on each new
  # phase and every 30 seconds.
  # The clock can be negative, so the first deadline is the start time.
  defp tick(progress, started, next_draw) do
    receive do
      {:stop, from} ->
        if terminal?(), do: IO.write("\r\e[2K")
        send(from, :stopped)

      {phase, words} ->
        if phase == progress.phase do
          tick(advance(progress, phase, words), started, next_draw)
        else
          progress = progress |> advance(phase, words) |> draw(started, true)
          tick(progress, started, now() + 1000)
        end
    after
      max(next_draw - now(), 0) ->
        tick(draw(progress, started, false), started, now() + 1000)
    end
  end

  @doc """
  How progress moves on when a piece arrives: `words` more in `phase`. A
  new phase starts its count over; when writing starts, the words thought
  so far are kept as `:thought`.
  """
  def advance(progress, phase, words) do
    case {progress.phase, phase} do
      {same, same} ->
        %{progress | words: progress.words + words}

      {:thinking, :writing} ->
        %{progress | phase: :writing, thought: progress.words, words: words}

      {_, new} ->
        %{progress | phase: new, words: words}
    end
  end

  defp draw(progress, started, new_phase?) do
    elapsed = now() - started
    line = status_line(progress, elapsed)
    printed = Map.get(progress, :printed_at, -30_000)

    cond do
      terminal?() ->
        IO.write("\r\e[2K" <> line)
        progress

      new_phase? or elapsed - printed >= 30_000 ->
        IO.puts(line)
        Map.put(progress, :printed_at, elapsed)

      true ->
        progress
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp stop_ticker(ticker) do
    send(ticker, {:stop, self()})

    receive do
      :stopped -> :ok
    after
      1000 -> :ok
    end
  end

  # Erlang only knows standard output as a terminal, so progress goes there
  # (the report goes to its own file).
  defp terminal?, do: Keyword.get(:io.getopts(:standard_io), :terminal, false) == true

  defp say(line), do: IO.puts(line)

  defp count([_], noun), do: "1 #{noun}"
  defp count(list, noun), do: "#{length(list)} #{noun}s"

  defp save(path, text) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, text)
  end

  defp read_env_file(path) do
    case File.read(path) do
      {:ok, text} -> parse_env(text)
      {:error, _} -> %{}
    end
  end

  defp required(name, file, env) do
    case setting(name, file, env) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "#{name} isn't set: put it in test/review/.env (see .env.example)"}
    end
  end

  # The spec, the diff, and each changed file as it is at the range's end
  # (files the change deleted are left out; the diff shows them).
  defp materials(%{range: range, spec: spec, context: context}) do
    with {:ok, diff} <- git(["diff", range]),
         {:ok, names} <- git(["diff", "--name-only", "--diff-filter=d", range]),
         {:ok, spec_text} <- read(spec),
         {:ok, context} <- read_all(context) do
      files =
        for path <- String.split(names, "\n", trim: true) do
          {path, file_at(range_end(range), path)}
        end

      {:ok,
       %{
         agents: File.read!("AGENTS.md"),
         op_params: File.read!("OP-PARAMS.md"),
         spec: {spec, spec_text},
         diff: diff,
         files: files,
         context: context
       }}
    end
  end

  # "a..b" ends at b; a single commit or "a.." ends at the working tree (nil).
  defp range_end(range) do
    case String.split(range, "..") do
      [_from, to] when to != "" -> to
      _ -> nil
    end
  end

  # With no end to the range, git diffs against the working tree, so read
  # the file from disk.
  defp file_at(nil, path), do: File.read!(path)

  defp file_at(ending, path) do
    {:ok, text} = git(["show", "#{ending}:#{path}"])
    text
  end

  defp read_all(paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      case read(path) do
        {:ok, text} -> {:cont, {:ok, acc ++ [{path, text}]}}
        error -> {:halt, error}
      end
    end)
  end

  defp read(path) do
    case File.read(path) do
      {:ok, text} -> {:ok, text}
      {:error, reason} -> {:error, "can't read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp git(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, _} -> {:error, "git #{Enum.join(args, " ")} failed: #{String.trim(out)}"}
    end
  end
end
