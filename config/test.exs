import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :mdt_client, MDTClientWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "es3iXg62cZ/nhOeFiFoKUtbMcjvDfNcQFanIwcNKukmDNW0YShvqkHTEQAYQ68JZ",
  server: false

config :mdt_client,
  data_dir: Path.join(System.tmp_dir!(), "mdt_client_test_data"),
  log_dir: Path.join(System.tmp_dir!(), "mdt_client_test_logs_#{System.pid()}"),
  http_client_history_sync_interval: :timer.seconds(1)

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
