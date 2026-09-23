defmodule MDTClient.HttpClient.RequestsTest do
  use ExUnit.Case, async: false

  import MDTClient.VaultHelpers

  alias MDTClient.HttpClient.Requests
  alias MDTClient.HttpClient.Resources

  setup {Req.Test, :verify_on_exit!}

  setup do
    unlocked_identity()
  end

  test "execution is owned by the vault rather than the initiating process", %{username: username} do
    test_process = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_process, {:request_started, self()})

      receive do
        :finish_request -> Plug.Conn.send_resp(conn, 200, "finished in background")
      end
    end)

    Req.Test.set_req_test_to_shared()
    on_exit(&Req.Test.set_req_test_to_private/0)

    :ok = Requests.subscribe(username)

    {initiator, monitor} =
      spawn_monitor(fn ->
        :ok =
          Requests.start(
            username,
            "background-request",
            Req.new(url: "https://example.test/slow", plug: {Req.Test, __MODULE__}),
            %{}
          )
      end)

    assert_receive {:request_started, request_process}
    assert_receive {:DOWN, ^monitor, :process, ^initiator, :normal}

    send(request_process, :finish_request)

    assert_receive {:http_request_finished, "background-request",
                    %{history_id: history_id, response: response}}

    assert response.status == 200
    assert response.body == nil
    refute response.body_loaded?

    assert {:ok, {^history_id, _metadata, _request, stored_response}} =
             Resources.get(username, history_id)

    assert stored_response.body == "finished in background"
  end

  test "cancels an infinite request without recording a partial response", %{username: username} do
    test_process = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_process, {:infinite_request_started, self()})

      receive do
        :unexpected_finish -> Plug.Conn.send_resp(conn, 200, "too late")
      end
    end)

    Req.Test.set_req_test_to_shared()
    on_exit(&Req.Test.set_req_test_to_private/0)

    :ok = Requests.subscribe(username)

    request =
      Req.new(
        url: "https://example.test/stream",
        plug: {Req.Test, __MODULE__},
        request_timeout: :infinity,
        receive_timeout: :infinity
      )

    :ok = Requests.start(username, "infinite-request", request, %{})
    assert_receive {:infinite_request_started, request_process}
    monitor = Process.monitor(request_process)
    assert Requests.running(username) == ["infinite-request"]

    assert :ok = Requests.cancel(username, "infinite-request")
    assert_receive {:http_request_cancelled, "infinite-request"}
    assert_receive {:DOWN, ^monitor, :process, ^request_process, :shutdown}
    assert Requests.running(username) == []
    assert Resources.all(username) == []
  end
end
