defmodule MDTClient.FakeTunnel do
  @moduledoc false
  # A tunnel for `MDTClient.Sandbox.Forwarder` in tests. Its opts (or, when
  # the Server builds them, `config :mdt_client, MDTClient.FakeTunnel`) name
  # the test process, told of every call, and an agent holding what the VM
  # lists (`ss`), which forwards fail (`fail`) and whether opening works.

  @behaviour MDTClient.Sandbox.Forwarder

  def agent(attrs \\ %{}) do
    {:ok, agent} = Agent.start_link(fn -> Map.merge(%{ss: "", fail: %{}, open: :ok}, attrs) end)
    agent
  end

  def set(agent, key, value), do: Agent.update(agent, &Map.put(&1, key, value))

  @impl true
  def open(opts) do
    %{test: test, agent: agent} =
      Map.merge(Map.new(Application.get_env(:mdt_client, __MODULE__, [])), opts)

    case Agent.get(agent, & &1.open) do
      :ok ->
        ref = make_ref()
        send(test, {:tunnel, :open, ref, opts})
        {:ok, %{port: ref, test: test, agent: agent}}

      {:error, message} ->
        send(test, {:tunnel, :open_failed})
        {:error, message}
    end
  end

  @impl true
  def listeners(%{agent: agent}) do
    case Agent.get(agent, & &1.ss) do
      {:error, message} -> {:error, message}
      text -> {:ok, text}
    end
  end

  @impl true
  def forward(%{test: test, agent: agent}, address, port, target) do
    send(test, {:tunnel, :forward, address, port, target})

    case Agent.get(agent, &Map.get(&1.fail, port)) do
      nil -> :ok
      message -> {:error, message}
    end
  end

  @impl true
  def cancel(%{test: test}, address, port, target) do
    send(test, {:tunnel, :cancel, address, port, target})
    :ok
  end

  @impl true
  def close(%{test: test, port: ref}) do
    send(test, {:tunnel, :close, ref})
    :ok
  end

  @doc "`ss -ltnpH` lines for `{bind, port, process}`."
  def ss(listeners) do
    Enum.map_join(listeners, "\n", fn {bind, port, process} ->
      "LISTEN 0      4096   #{bind}:#{port}   0.0.0.0:*    users:((\"#{process}\",pid=7,fd=3))"
    end)
  end
end
