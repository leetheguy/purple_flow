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

  @doc """
  Sends `body` to OpenRouter with the API key and returns the answer's
  text. `req_options` are extra `Req` options (tests pass a `:plug`).
  """
  def ask(key, body, req_options \\ []) do
    options =
      [
        url: @url,
        method: :post,
        json: body,
        auth: {:bearer, key},
        # A big review can take minutes to write.
        receive_timeout: 900_000,
        retry: false
      ] ++ req_options

    case Req.request(options) do
      {:ok,
       %Req.Response{
         status: 200,
         body: %{"choices" => [%{"message" => %{"content" => text}} | _]}
       }}
      when is_binary(text) ->
        {:ok, text}

      {:ok, %Req.Response{status: 200, body: body}} ->
        {:error, "no answer in OpenRouter's reply: #{inspect(body, limit: 20)}"}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "OpenRouter answered #{status}: #{error_message(body)}"}

      {:error, error} ->
        {:error, "request to OpenRouter failed: #{Exception.message(error)}"}
    end
  end

  defp error_message(%{"error" => %{"message" => message}}), do: message
  defp error_message(body), do: inspect(body, limit: 20)

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

  @doc "Runs a review from the command line. Returns `:ok` or `{:error, message}`."
  def main(argv) do
    file = read_env_file("test/review/.env")
    env = System.get_env()

    with {:ok, args} <- parse_args(argv),
         {:ok, materials} <- materials(args) do
      prompt = prompt(materials)
      instructions = File.read!("test/review/instructions.md")

      size =
        "#{length(materials.files)} changed files, #{length(materials.context)} context files, " <>
          "and the diff, about #{div(byte_size(instructions <> prompt), 4)} tokens"

      if args.dry_run do
        out = args.out || default_out(args.range, "dry-run")
        save(out, instructions <> "\n\n" <> prompt)
        IO.puts("Nothing sent. What would be sent (#{size}) is in #{out}")
      else
        with {:ok, key} <- required("OPENROUTER_API_KEY", file, env),
             {:ok, model} <- required("REVIEW_MODEL", file, env) do
          IO.puts(:stderr, "Sending #{size} to #{model}…")

          with {:ok, report} <- ask(key, body(model, instructions, prompt)) do
            out = args.out || default_out(args.range, model)
            save(out, report)
            IO.puts("Report saved to #{out}")
          end
        end
      end
    end
  end

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
