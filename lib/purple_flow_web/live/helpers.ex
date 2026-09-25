defmodule PurpleFlowWeb.Live.Helpers do
  @moduledoc "Small display helpers shared by the UI pages."

  use Phoenix.Component

  @doc "A colored status pill: green ok, red failed, blue running, gray didn't run."
  attr :status, :string, required: true
  attr :id, :string, default: nil

  def status_badge(assigns) do
    ~H"""
    <span
      id={@id}
      class={[
        "inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-xs font-medium",
        status_class(@status)
      ]}
    >
      <span class="size-1.5 rounded-full bg-current"></span>
      {@status}
    </span>
    """
  end

  def status_class(status) when status in ["complete", "ok"],
    do: "bg-emerald-500/15 text-emerald-600 dark:text-emerald-400"

  def status_class(status) when status in ["failed", "error", "timed_out"],
    do: "bg-red-500/15 text-red-600 dark:text-red-400"

  def status_class("running"), do: "bg-sky-500/15 text-sky-600 dark:text-sky-400"
  def status_class(_), do: "bg-base-300/60 text-base-content/50"

  @doc "Milliseconds between two times, as `850ms`, `3.2s`, or `4m 10s`."
  def duration(nil, _), do: nil
  def duration(_, nil), do: nil

  def duration(from, to) do
    ms = DateTime.diff(to, from, :millisecond)

    cond do
      ms < 1_000 -> "#{ms}ms"
      ms < 60_000 -> "#{Float.round(ms / 1000, 1)}s"
      true -> "#{div(ms, 60_000)}m #{rem(div(ms, 1000), 60)}s"
    end
  end

  @doc "A timestamp as `2026-09-25 14:03:07`."
  def timestamp(nil), do: ""
  def timestamp(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")

  @doc "Pretty JSON for display."
  def pretty(value), do: Jason.encode!(value, pretty: true)
end
