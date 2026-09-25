defmodule PurpleFlow.Template do
  @moduledoc """
  Fills in `{{ ... }}` placeholders in a node's config before it runs.

  Three kinds of placeholder:

  - `{{ input.user.id }}`: a value from the node's input
  - `{{ steps.fetch.output.total }}`: a value from an ancestor step's output
  - `{{ env.API_TOKEN }}`: an environment variable (credentials go here)

  If a string is *only* a placeholder, the raw value is used, so numbers,
  lists, and maps keep their type. Otherwise the value is turned into text.
  List positions work too: `{{ input.items.0.name }}`.
  """

  alias PurpleFlow.Env

  @pattern ~r/\{\{\s*([^{}]+?)\s*\}\}/
  @whole ~r/\A\{\{\s*([^{}]+?)\s*\}\}\z/

  @doc """
  Fills every placeholder in `config`.

  `context` has `:input` and `:steps` (ancestor outputs). Returns the filled
  config plus the credential values that were used, so they can be redacted
  later.
  """
  @spec render(term(), %{input: term(), steps: map()}) ::
          {:ok, term(), [String.t()]} | {:error, String.t()}
  def render(config, context) do
    {filled, secrets} = walk(config, context, [])
    {:ok, filled, Enum.uniq(secrets)}
  catch
    {:template_error, message} -> {:error, message}
  end

  @doc """
  Lists every placeholder in `config` without filling anything in, as
  `{:env, name}`, `{:steps, name, path}`, `{:input, path}`, or `{:bad, text}`.
  Used when a workflow loads, to catch mistakes early.
  """
  def refs(config) do
    config
    |> strings()
    |> Enum.flat_map(fn string ->
      for [_, path] <- Regex.scan(@pattern, string), do: classify(path)
    end)
  end

  # -- filling in --

  # Maps and lists are walked into. Strings get their placeholders filled.
  # Anything else (numbers, booleans, prepared data like parsed code) is left alone.
  defp walk(map, ctx, secrets) when is_map(map) and not is_struct(map) do
    Enum.reduce(map, {%{}, secrets}, fn {key, value}, {acc, secrets} ->
      {value, secrets} = walk(value, ctx, secrets)
      {Map.put(acc, key, value), secrets}
    end)
  end

  defp walk(list, ctx, secrets) when is_list(list) do
    {items, secrets} =
      Enum.reduce(list, {[], secrets}, fn value, {acc, secrets} ->
        {value, secrets} = walk(value, ctx, secrets)
        {[value | acc], secrets}
      end)

    {Enum.reverse(items), secrets}
  end

  defp walk(string, ctx, secrets) when is_binary(string) do
    case Regex.run(@whole, string) do
      [_, path] ->
        lookup(path, ctx, secrets)

      nil ->
        Regex.scan(@pattern, string)
        |> Enum.reduce({string, secrets}, fn [placeholder, path], {string, secrets} ->
          {value, secrets} = lookup(path, ctx, secrets)
          {String.replace(string, placeholder, to_text(value), global: false), secrets}
        end)
    end
  end

  defp walk(other, _ctx, secrets), do: {other, secrets}

  defp lookup(path, ctx, secrets) do
    case classify(path) do
      {:env, name} ->
        case Env.get(name) do
          nil -> fail("env var #{name} isn't set")
          value -> {value, [value | secrets]}
        end

      {:input, rest} ->
        {dig(ctx.input, rest, path), secrets}

      {:steps, name, rest} ->
        case Map.fetch(ctx.steps, name) do
          {:ok, %{"output" => output}} -> {dig(output, rest, path), secrets}
          :error -> fail("step #{name} isn't an ancestor, or didn't run")
        end

      {:bad, _} ->
        fail("don't know what {{ #{path} }} means")
    end
  end

  defp classify(path) do
    case String.split(path, ".") do
      ["env", name] -> {:env, name}
      ["input" | rest] -> {:input, rest}
      ["steps", name, "output" | rest] -> {:steps, name, rest}
      _ -> {:bad, path}
    end
  end

  # Follow a path like ["user", "id"] into a value.
  defp dig(value, [], _path), do: value

  defp dig(map, [key | rest], path) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> dig(value, rest, path)
      :error -> fail("{{ #{path} }}: no \"#{key}\" found")
    end
  end

  defp dig(list, [key | rest], path) when is_list(list) do
    with {index, ""} <- Integer.parse(key),
         {:ok, value} <- Enum.fetch(list, index) do
      dig(value, rest, path)
    else
      _ -> fail("{{ #{path} }}: no item #{key} in the list")
    end
  end

  defp dig(_other, [key | _], path), do: fail("{{ #{path} }}: can't look up \"#{key}\" here")

  defp to_text(nil), do: ""
  defp to_text(value) when is_binary(value), do: value
  defp to_text(value) when is_map(value) or is_list(value), do: Jason.encode!(value)
  defp to_text(value), do: to_string(value)

  defp fail(message), do: throw({:template_error, message})

  defp strings(value) when is_binary(value), do: [value]

  defp strings(map) when is_map(map) and not is_struct(map),
    do: Enum.flat_map(Map.values(map), &strings/1)

  defp strings(list) when is_list(list), do: Enum.flat_map(list, &strings/1)
  defp strings(_), do: []
end
