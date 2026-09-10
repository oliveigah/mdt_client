defmodule MDTClient.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    pubsub = System.get_env("ELIXIRKIT_PUBSUB")

    children = [
      MDTClientWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:mdt_client, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: MDTClient.PubSub},
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

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    MDTClientWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
