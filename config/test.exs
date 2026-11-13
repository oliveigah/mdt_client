import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :mdt_client, MDTClientWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "es3iXg62cZ/nhOeFiFoKUtbMcjvDfNcQFanIwcNKukmDNW0YShvqkHTEQAYQ68JZ",
  server: false

config :mdt_client,
  data_dir: Path.join(System.tmp_dir!(), "mdt_client_test_data_#{System.pid()}"),
  log_dir: Path.join(System.tmp_dir!(), "mdt_client_test_logs_#{System.pid()}"),
  # Tests add remotes that do not exist; the ones about fetching turn it on.
  git_auto_fetch: false

# The sandbox never calls msb in tests, and its proxy takes any free port.
config :mdt_client, MDTClient.Sandbox.Server,
  external: false,
  proxy_port: 0,
  channel_dir: Path.join(System.tmp_dir!(), "mdt-test-channels")

# A runtime built into priv/microsandbox stays out of tests; the ones about
# msb make their own.
config :mdt_client, MDTClient.Sandbox.Msb,
  runtime_dir: Path.join(System.tmp_dir!(), "mdt_client_test_msb_#{System.pid()}")

# Tests never show desktop notifications; the service only keeps track of
# what it would show. The D-Bus tests start their own bus.
config :mdt_client, MDTClient.Desktop.Notifications, address: nil

# Host commands, minted values and the tool probe run `bash -lc`, which reads
# the login profile of whoever runs the tests and prints whatever it prints.
# A home that doesn't exist keeps it out; /etc/profile still runs.
config :mdt_client, MDTClient.Sandbox.HostRun,
  home: Path.join(System.tmp_dir!(), "mdt_client_test_home_#{System.pid()}")

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
