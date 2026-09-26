import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/purple_flow start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :purple_flow, PurpleFlowWeb.Endpoint, server: true
end

config :purple_flow, PurpleFlowWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# The same release runs as either the app or the Code node runner (see
# specs/070_code_sandbox.md). The runner is started with no secrets at all,
# so nothing below that requires one applies to it.
role = if System.get_env("PURPLEFLOW_ROLE") == "runner", do: :runner, else: :app
config :purple_flow, :role, role

if role == :runner do
  config :purple_flow,
         :runner_port,
         String.to_integer(System.get_env("PURPLEFLOW_RUNNER_PORT", "4100"))
end

# Where the app sends Code node scripts, as "host:port". Without it (dev and
# test), the app runs them in its own VM instead; a release requires it.
if runner_address = System.get_env("PURPLEFLOW_RUNNER_ADDRESS") do
  [host, port] = String.split(runner_address, ":", parts: 2)
  config :purple_flow, :runner_address, {host, String.to_integer(port)}
end

# The runner's network, as a CIDR like "10.250.250.0/24". The app refuses
# every web request from it, so a script can't call the app's webhooks or UI.
if runner_subnet = System.get_env("PURPLEFLOW_RUNNER_SUBNET") do
  config :purple_flow, :runner_subnet, runner_subnet
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :purple_flow, PurpleFlowWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/purple_flow_web/router\.ex$"E,
        ~r"lib/purple_flow_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod and role == :app do
  System.get_env("PURPLEFLOW_RUNNER_ADDRESS") ||
    raise """
    environment variable PURPLEFLOW_RUNNER_ADDRESS is missing.
    Code node scripts run in a separate runner container, for example
    PURPLEFLOW_RUNNER_ADDRESS=runner:4100. See docker-compose.yml.
    """

  System.get_env("PURPLEFLOW_RUNNER_SUBNET") ||
    raise """
    environment variable PURPLEFLOW_RUNNER_SUBNET is missing.
    It's the runner's network, which the app refuses web requests from,
    for example PURPLEFLOW_RUNNER_SUBNET=10.250.250.0/24. See docker-compose.yml.
    """

  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :purple_flow, PurpleFlow.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :purple_flow, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :purple_flow, :workflows_dir, System.get_env("WORKFLOWS_DIR", "/app/workflows")

  config :purple_flow, PurpleFlowWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :purple_flow, PurpleFlowWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :purple_flow, PurpleFlowWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
