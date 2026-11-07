defmodule Mix.Tasks.MutateTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Mutate

  @source """
  defmodule Example do
    @moduledoc "Docs aren't mutated: 1 >= 2 and true"
    def check(a, b) do
      if a >= b and b != 0, do: true, else: 10
    end
  end
  """

  test "finds comparisons, boolean operators, booleans, and numbers to change" do
    changes = for m <- Mutate.mutants(@source), do: {m.line, m.from, m.to}

    assert {4, ">=", ">"} in changes
    assert {4, "and", "or"} in changes
    assert {4, "!=", "=="} in changes
    assert {4, "true", "false"} in changes
    assert {4, "0", "1"} in changes
    assert {4, "10", "11"} in changes
  end

  test "leaves strings, docs, and module attributes alone" do
    refute Enum.any?(Mutate.mutants(@source), &(&1.line == 2))
  end

  test "leaves a capture's arity and argument positions alone, not its logic" do
    assert Mutate.mutants("f = &String.upcase/1") == []

    changes = for m <- Mutate.mutants("g = &(&1 + 1)"), do: {m.from, m.to}
    assert Enum.sort(changes) == [{"+", "-"}, {"1", "2"}]
  end

  test "applying a mutant changes only that spot, and checks it first" do
    [mutant | _] = for m <- Mutate.mutants(@source), m.from == ">=", do: m
    assert {:ok, mutated} = Mutate.apply_mutant(@source, mutant)
    assert mutated =~ "if a > b and b != 0"
    assert String.split(mutated, "\n") |> length() == String.split(@source, "\n") |> length()

    assert Mutate.apply_mutant(@source, %{mutant | from: "<="}) == :mismatch
  end

  test "finds the test files that name a module" do
    # Built at runtime, so this file doesn't name the module itself.
    files = Mutate.test_files_for(["PurpleFlow." <> "Watchdog"], "test")
    assert "test/purple_flow/watchdog_test.exs" in files
    refute "test/purple_flow/mutate_test.exs" in files
  end

  test "finds a module named in a grouped alias, like `alias PurpleFlow.{Id, RunFiles}`" do
    files = Mutate.test_files_for(["PurpleFlow." <> "RunFiles"], "test")
    assert "test/purple_flow/run_files_test.exs" in files
  end

  test "matches a module's whole name, not a longer one that starts with it" do
    files = Mutate.test_files_for(["PurpleFlow." <> "Run"], "test")
    refute "test/purple_flow/runner_test.exs" in files
  end

  test "reads the changed lines from a diff: added and changed, not removed" do
    diff = """
    diff --git a/lib/x.ex b/lib/x.ex
    --- a/lib/x.ex
    +++ b/lib/x.ex
    @@ -4,0 +5,3 @@ def a do
    +one
    +two
    +three
    @@ -20 +23 @@ def b do
    -old
    +new
    @@ -30,2 +32,0 @@ def c do
    -gone
    -gone too
    """

    assert Mutate.changed_lines(diff) == MapSet.new([5, 6, 7, 23])
    assert Mutate.changed_lines("") == MapSet.new()
  end

  test "keeps only the mutants on the given lines, or all of them" do
    mutants = Mutate.mutants(@source)

    assert Mutate.on_lines(mutants, MapSet.new([4])) == mutants
    assert Mutate.on_lines(mutants, MapSet.new([3, 5])) == []
    assert Mutate.on_lines(mutants, :all) == mutants
  end
end
