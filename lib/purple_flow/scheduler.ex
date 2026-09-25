defmodule PurpleFlow.Scheduler do
  @moduledoc """
  Runs cron triggers, using the Quantum library. `PurpleFlow.Workflows` adds
  one job per workflow that has a `[trigger.cron]` block.
  """

  use Quantum, otp_app: :purple_flow
end
