defmodule PurpleFlow.Redact do
  @moduledoc """
  Hides credentials. Anywhere a secret value shows up in a record, error, or
  broadcast, it's replaced with `[redacted]` before it leaves the task.
  """

  @mask "[redacted]"

  # Very short values ("1", "on") would blank out half the data, so skip them.
  @min_length 4

  @doc "Replaces every secret found anywhere inside `value`."
  def redact(value, secrets) do
    case Enum.filter(secrets, &(is_binary(&1) and byte_size(&1) >= @min_length)) do
      [] -> value
      secrets -> scrub(value, secrets)
    end
  end

  defp scrub(string, secrets) when is_binary(string), do: String.replace(string, secrets, @mask)

  defp scrub(map, secrets) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} -> {scrub(k, secrets), scrub(v, secrets)} end)
  end

  defp scrub(list, secrets) when is_list(list), do: Enum.map(list, &scrub(&1, secrets))
  defp scrub(other, _secrets), do: other
end
