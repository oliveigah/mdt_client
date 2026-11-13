defmodule MDTClient.Sandbox.DnsTest do
  # The resolver is application config, so these tests take turns.
  use ExUnit.Case, async: false

  alias MDTClient.Sandbox
  alias MDTClient.Sandbox.Dns

  doctest Dns

  # A question for `name`, as a resolver library builds it.
  defp question(name, type \\ 1, id \\ 0x1234) do
    labels =
      for label <- String.split(name, "."), into: <<>>, do: <<byte_size(label), label::binary>>

    <<id::16, 0x0100::16, 1::16, 0::48, labels::binary, 0, type::16, 1::16>>
  end

  # Stands in for this machine's resolver: answers each question with the
  # question itself and `tail`, over UDP, and tells the test what it got.
  defp fake_resolver(tail, flags \\ 0x8180) do
    {:ok, udp} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(udp)

    {:ok, tcp} =
      :gen_tcp.listen(port, [
        :binary,
        active: false,
        ip: {127, 0, 0, 1},
        packet: 2,
        reuseaddr: true
      ])

    test = self()

    spawn_link(fn -> serve_udp(udp, tail, flags, test) end)
    spawn_link(fn -> serve_tcp(tcp, tail, test) end)

    saved = Application.get_env(:mdt_client, Dns)
    Application.put_env(:mdt_client, Dns, resolver: {{127, 0, 0, 1}, port})

    on_exit(fn ->
      if saved,
        do: Application.put_env(:mdt_client, Dns, saved),
        else: Application.delete_env(:mdt_client, Dns)
    end)
  end

  defp serve_udp(socket, tail, flags, test) do
    {:ok, {address, port, <<id::16, _flags::16, rest::binary>> = asked}} =
      :gen_udp.recv(socket, 0)

    send(test, {:resolver_udp, asked})
    :gen_udp.send(socket, address, port, <<id::16, flags::16, rest::binary, tail::binary>>)
    serve_udp(socket, tail, flags, test)
  end

  defp serve_tcp(listen, tail, test) do
    {:ok, socket} = :gen_tcp.accept(listen)
    {:ok, <<id::16, _flags::16, rest::binary>> = asked} = :gen_tcp.recv(socket, 0, 5_000)
    send(test, {:resolver_tcp, asked})
    :gen_tcp.send(socket, <<id::16, 0x8180::16, rest::binary, tail::binary, "whole">>)
    :gen_tcp.close(socket)
    serve_tcp(listen, tail, test)
  end

  # What the relay does for each question the VM asks.
  defp ask(username, message) do
    {:ok, socket} =
      :gen_tcp.connect({:local, Dns.path(username)}, 0, [:binary, active: false, packet: 2])

    :ok = :gen_tcp.send(socket, message)
    answer = :gen_tcp.recv(socket, 0, 5_000)
    :gen_tcp.close(socket)
    answer
  end

  defp lookups(username) do
    _ = :sys.get_state(MDTClient.Vault.Store.whereis(Sandbox.Server, username))
    for %{outcome: :lookup} = event <- Sandbox.events(username), do: {event.host, event.summary}
  end

  setup do
    MDTClient.VaultHelpers.unlocked_identity("dns")
  end

  test "what a message asks for is read; anything else is not a question" do
    assert Dns.question(question("api.GitHub.com", 28)) == {:ok, "api.github.com", "AAAA"}
    assert Dns.question(question("example.com", 999)) == {:ok, "example.com", "type 999"}
    assert Dns.question(<<1, 2, 3>>) == :error
    assert Dns.question(<<0::16, 0::16, 2::16, 0::48, 0, 1::16, 1::16>>) == :error
    # A label that says it is longer than the message.
    assert Dns.question(<<0::16, 0::16, 1::16, 0::48, 50, "short">>) == :error
  end

  test "a question goes to this machine's resolver and its answer comes back unchanged", %{
    username: username
  } do
    fake_resolver("the answer")
    asked = question("example.com")

    assert {:ok, answer} = ask(username, asked)
    assert_received {:resolver_udp, ^asked}
    <<_id::16, _flags::16, rest::binary>> = asked
    assert answer == <<0x1234::16, 0x8180::16, rest::binary, "the answer">>
  end

  test "every name is in the activity log, once in a while", %{username: username} do
    fake_resolver("x")

    assert {:ok, _} = ask(username, question("one.example.com"))
    assert {:ok, _} = ask(username, question("one.example.com"))
    assert {:ok, _} = ask(username, question("one.example.com", 28))
    assert {:ok, _} = ask(username, question("two.example.com"))

    assert Enum.sort(lookups(username)) == [
             {"one.example.com", "Looked up (A)"},
             {"one.example.com", "Looked up (AAAA)"},
             {"two.example.com", "Looked up (A)"}
           ]
  end

  test "an answer cut short over UDP is asked again over TCP", %{username: username} do
    # 0x8380: the same answer flags with TC set.
    fake_resolver("part", 0x8380)
    asked = question("big.example.com", 16)

    assert {:ok, answer} = ask(username, asked)
    assert_received {:resolver_udp, ^asked}
    assert_received {:resolver_tcp, ^asked}
    assert String.ends_with?(answer, "partwhole")
  end

  test "bytes that aren't a question get no answer and reach no resolver", %{username: username} do
    fake_resolver("x")

    assert {:error, :closed} = ask(username, "not a dns message at all")
    refute_received {:resolver_udp, _}
    assert lookups(username) == []
  end
end
