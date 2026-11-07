defmodule Mix.Tasks.Mutate do
  @shortdoc "Mutation testing: are there bugs the tests wouldn't catch?"
  @moduledoc """
  Makes small, deliberate bugs in a source file, one at a time, and runs
  the tests against each. A bug no test catches (a *surviving mutant*) is a
  gap in the tests. See `OP-PARAMS.md` sections 4 and 5.

      mix mutate                               # every changed file in lib/
      mix mutate lib/purple_flow/watchdog.ex
      mix mutate lib/purple_flow/watchdog.ex --test test/purple_flow/watchdog_test.exs
      mix mutate --since master                # everything this branch changed
      mix mutate lib/purple_flow/watchdog.ex --all

  Only lines changed since `--since` (default `HEAD`: what isn't committed
  yet, staged or not) are mutated, read from `git diff`; a file git doesn't
  track yet is all changed. With no files named, it takes every changed
  `.ex` file under `lib/`. `--all` mutates whole files, for hardening a
  file's tests. A file with nothing to mutate is skipped without running
  its tests.

  The bugs it makes:

    * comparisons: `==` ↔ `!=`, `===` ↔ `!==`, `>` ↔ `>=`, `<` ↔ `<=`
    * boolean operators: `and` ↔ `or`, `&&` ↔ `||`
    * arithmetic: `+` ↔ `-`
    * literals: `true` ↔ `false`, and a number `n` becomes `n + 1`

  Strings, docs, module attributes (`@...`), and the numbers in captures
  (`&f/1`, `&1`) are left alone.

  The tests it runs are every `*_test.exs` file that names a module defined
  in the file, unless `--test` names them. They must pass before it starts.

  Each mutant is written into the file itself, and the file is restored
  after each run, so don't edit it (or stop this) while it runs. It lives
  in `test/support`, so it's only compiled for tests and never ships.
  Exits with status 1 when any mutant survives.

  Elixir's mutation tools are unmaintained (muzak's last release, in 2022,
  can't parse current Elixir), which is why this exists.
  """

  use Mix.Task

  @swaps %{
    ==: :!=,
    !=: :==,
    ===: :!==,
    !==: :===,
    >: :>=,
    >=: :>,
    <: :<=,
    <=: :<,
    and: :or,
    or: :and,
    &&: :||,
    ||: :&&,
    +: :-,
    -: :+
  }

  @impl Mix.Task
  def run(args) do
    {opts, files} =
      OptionParser.parse!(args, strict: [test: :keep, since: :string, all: :boolean])

    since = Keyword.get(opts, :since, "HEAD")
    files = if files == [], do: changed_files(since), else: files
    if files == [], do: Mix.shell().info("nothing changed since #{since} in lib/")

    survivors =
      Enum.flat_map(files, fn path ->
        lines = if opts[:all], do: :all, else: lines_changed(path, since)
        mutate_file(path, lines, Keyword.get_values(opts, :test))
      end)

    if survivors != [], do: exit({:shutdown, 1})
  end

  defp changed_files(since) do
    {diffed, 0} = System.cmd("git", ["diff", "--name-only", since, "--", "lib"])
    {untracked, 0} = System.cmd("git", ["ls-files", "--others", "--exclude-standard", "lib"])

    (String.split(diffed) ++ String.split(untracked))
    |> Enum.filter(&(String.ends_with?(&1, ".ex") and File.exists?(&1)))
    |> Enum.uniq()
  end

  defp lines_changed(path, since) do
    case System.cmd("git", ["ls-files", "--error-unmatch", path], stderr_to_stdout: true) do
      {_, 0} ->
        {diff, 0} = System.cmd("git", ["diff", "-U0", since, "--", path])
        changed_lines(diff)

      _untracked ->
        :all
    end
  end

  @doc """
  The lines a `git diff -U0` adds or changes, by their numbers in the new
  file. Each hunk header `@@ -a,b +c,d @@` covers lines `c` to `c + d - 1`
  (`d` is 1 when left out; 0 means lines were only removed).
  """
  def changed_lines(diff) do
    # Regex.scan leaves out a trailing group that didn't match, so a hunk
    # with no `,d` gives `[_, c]`.
    for [_, start | count] <- Regex.scan(~r/^@@ -\S+ \+(\d+)(?:,(\d+))? @@/m, diff),
        start = String.to_integer(start),
        count = if(count == [], do: 1, else: String.to_integer(hd(count))),
        line <- start..(start + count - 1)//1,
        into: MapSet.new(),
        do: line
  end

  @doc "The mutants on `lines` (a set of line numbers), or all of them for `:all`."
  def on_lines(mutants, :all), do: mutants
  def on_lines(mutants, lines), do: Enum.filter(mutants, &MapSet.member?(lines, &1.line))

  defp mutate_file(path, lines, tests) do
    case on_lines(mutants(File.read!(path)), lines) do
      [] ->
        Mix.shell().info("#{path}: nothing to mutate on changed lines")
        []

      mutants ->
        mutate_file(path, mutants, File.read!(path), tests)
    end
  end

  defp mutate_file(path, mutants, source, tests) do
    modules = for [_, name] <- Regex.scan(~r/defmodule\s+([\w.]+)/, source), do: name
    tests = if tests == [], do: test_files_for(modules, "test"), else: tests
    if tests == [], do: Mix.raise("no test files name #{Enum.join(modules, ", ")}; pass --test")

    Mix.shell().info("#{path}: running #{Enum.join(tests, " ")} first")
    if not tests_pass?(tests), do: Mix.raise("the tests fail before any mutation; fix them first")

    Mix.shell().info("#{length(mutants)} mutants")

    results =
      try do
        for mutant <- mutants do
          result =
            case apply_mutant(source, mutant) do
              {:ok, mutated} ->
                File.write!(path, mutated)
                if tests_pass?(tests), do: :survived, else: :killed

              :mismatch ->
                :skipped
            end

          IO.write(%{killed: ".", survived: "S", skipped: "?"}[result])
          {mutant, result}
        end
      after
        File.write!(path, source)
      end

    IO.write("\n")
    report(path, results)
  end

  defp report(path, results) do
    count = fn kind -> Enum.count(results, &(elem(&1, 1) == kind)) end
    survivors = for {mutant, :survived} <- results, do: mutant

    Mix.shell().info(
      "#{path}: #{count.(:killed)} killed, #{length(survivors)} survived, #{count.(:skipped)} skipped"
    )

    for m <- survivors do
      Mix.shell().info("  #{path}:#{m.line}: `#{m.from}` -> `#{m.to}`: no test failed")
    end

    survivors
  end

  defp tests_pass?(tests) do
    {_output, status} =
      System.cmd("mix", ["test", "--max-failures", "1" | tests],
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    status == 0
  end

  @doc """
  Every test file under `dir` that names one of `modules` (full names, like
  `"PurpleFlow.Watchdog"`), whole or in a grouped alias
  (`alias PurpleFlow.{Id, Watchdog}`).
  """
  def test_files_for(modules, dir) do
    # The whole name: `PurpleFlow.Run` doesn't match `PurpleFlow.Runner`.
    patterns =
      Enum.flat_map(modules, fn m ->
        {parent, [last]} = m |> String.split(".") |> Enum.split(-1)
        whole = Regex.compile!(Regex.escape(m) <> "(?![\\w])")

        if parent == [] do
          [whole]
        else
          prefix = Regex.escape(Enum.join(parent, "."))
          [whole, Regex.compile!(prefix <> "\\.\\{[^}]*\\b" <> Regex.escape(last) <> "\\b")]
        end
      end)

    for file <- Path.wildcard(Path.join(dir, "**/*_test.exs")),
        contents = File.read!(file),
        Enum.any?(patterns, &Regex.match?(&1, contents)),
        do: file
  end

  @doc """
  The mutants for `source`: maps of `:line`, `:column`, `:from` (the text
  there now), and `:to` (what it becomes).
  """
  def mutants(source) do
    source
    |> Code.string_to_quoted!(
      columns: true,
      token_metadata: true,
      literal_encoder: &{:ok, {:__block__, &2, [&1]}}
    )
    |> walk()
  end

  # Module attributes hold docs and settings, not logic. In a capture, the
  # numbers in `&f/1` and `&1` are an arity and an argument position.
  defp walk({:@, _, _}), do: []
  defp walk({:&, _, [{:/, _, [_function, _arity]}]}), do: []
  defp walk({:&, _, [{:__block__, _, [n]}]}) when is_integer(n), do: []

  defp walk({:__block__, meta, [n]}) when is_integer(n) do
    [mutant(meta, meta[:token] || Integer.to_string(n), Integer.to_string(n + 1))]
  end

  defp walk({:__block__, meta, [b]}) when is_boolean(b),
    do: [mutant(meta, to_string(b), to_string(not b))]

  defp walk({:__block__, _meta, [literal]}) when is_list(literal) or is_tuple(literal),
    do: walk(literal)

  defp walk({op, meta, [left, right]}) when is_map_key(@swaps, op) do
    [mutant(meta, Atom.to_string(op), Atom.to_string(@swaps[op])) | walk(left) ++ walk(right)]
  end

  defp walk({head, _meta, args}) when is_list(args), do: walk(head) ++ walk(args)
  defp walk(list) when is_list(list), do: Enum.flat_map(list, &walk/1)
  defp walk({left, right}), do: walk(left) ++ walk(right)
  defp walk(_other), do: []

  defp mutant(meta, from, to), do: %{line: meta[:line], column: meta[:column], from: from, to: to}

  @doc """
  `source` with `mutant` applied, or `:mismatch` when the text at its
  position isn't `mutant.from` (so a wrong position never edits the wrong
  thing).
  """
  def apply_mutant(source, mutant) do
    lines = String.split(source, "\n")
    line = Enum.at(lines, mutant.line - 1)
    {before, rest} = String.split_at(line, mutant.column - 1)

    if String.starts_with?(rest, mutant.from) do
      after_from =
        binary_part(rest, byte_size(mutant.from), byte_size(rest) - byte_size(mutant.from))

      changed = before <> mutant.to <> after_from
      {:ok, lines |> List.replace_at(mutant.line - 1, changed) |> Enum.join("\n")}
    else
      :mismatch
    end
  end
end
