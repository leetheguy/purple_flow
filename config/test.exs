import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :purple_flow, PurpleFlow.Repo,
  username: "postgres",
  password: "postgres",
  hostname: System.get_env("POSTGRES_HOST", "localhost"),
  port: String.to_integer(System.get_env("POSTGRES_PORT", "5432")),
  database: "purple_flow_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :purple_flow, PurpleFlowWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "MnlRrLJTuxrypWoQG8jVqXeETT2wCLKHEA5iB4fY1B4/RGl0u9XJ3sYAy+bSRTMW",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# PurpleFlow: test workflows, and no boot-time DB cleanup (the DB is sandboxed per test).
config :purple_flow,
  workflows_dir: "test/support/workflows",
  mark_interrupted_on_boot: false,
  # The app's own Workflows process doesn't watch in tests: tests that need
  # watching start their own on a temp folder and tick it by hand.
  workflows_watch: [interval: :manual, credentials: false],
  http_req_options: [plug: {Req.Test, PurpleFlow.Nodes.Http}]

# Requests from here are refused, as from the Code node runner's network.
config :purple_flow, :runner_subnet, "10.250.250.0/24"
