defmodule MDTClient.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    pubsub = System.get_env("ELIXIRKIT_PUBSUB")
    discard_legacy_history()

    children = [
      MDTClientWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:mdt_client, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: MDTClient.PubSub},
      MDTClient.Preferences,
      MDTClient.Vault.Store,
      MDTClientWeb.Session,
      # Start a worker by calling: MDTClient.Worker.start_link(arg)
      # {MDTClient.Worker, arg},
      # Start to serve requests, typically the last entry
      {ElixirKit.PubSub, connect: pubsub || :ignore, on_exit: fn -> System.stop() end},
      MDTClientWeb.Endpoint,
      {Task,
       fn ->
         if pubsub do
           ElixirKit.PubSub.broadcast("messages", "ready")
         end
       end}
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: MDTClient.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Request history predates per identity encryption and was written in the
  # clear. There is no identity to migrate it into, so it goes.
  defp discard_legacy_history do
    legacy = Path.join(MDTClient.Accounts.root(), "http_client_history.ets")

    if File.exists?(legacy) do
      File.rm(legacy)
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    MDTClientWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
