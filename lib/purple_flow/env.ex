defmodule PurpleFlow.Env do
  @moduledoc """
  Credentials. They live in environment variables, never in TOML.

  At boot, `load/0` reads the `.env` file in the project root (if there is
  one). `get/1` looks a name up: a real environment variable wins, then the
  `.env` value.
  """

  @key {__MODULE__, :dotenv}

  @doc "Reads `.env` into memory. Called once at boot."
  def load(path \\ ".env") do
    values = Dotenvy.source!([path])
    # `:persistent_term` is a fast, read-mostly global store built into Erlang.
    :persistent_term.put(@key, values)
    :ok
  end

  @doc "The value of an env var, or `nil` if it isn't set anywhere."
  @spec get(String.t()) :: String.t() | nil
  def get(name) do
    System.get_env(name) || Map.get(:persistent_term.get(@key, %{}), name)
  end
end
