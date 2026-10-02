defmodule MDTClient.ListsBenchTest do
  @moduledoc """
  Times the lists and searches of the three tools that keep text, filled with
  thousands of entries carrying a good deal of it.

  Excluded from the suite; run it with

      mix test test/bench --only bench

  and size it with `BENCH_HTTP`, `BENCH_NOTES` and `BENCH_DIAGRAMS`. The
  LiveView timings include `Phoenix.LiveViewTest` applying each patch, and the
  test environment's expensive LiveView checks, so they read high next to a
  browser; compare them with each other rather than with a stopwatch.
  """
  use MDTClientWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias MDTClient.Diagrams.Diagram
  alias MDTClient.Diagrams.Library, as: Diagrams
  alias MDTClient.HttpClient.HistoryMetadata
  alias MDTClient.HttpClient.Resources
  alias MDTClient.Notes.Library, as: Notes
  alias MDTClient.Notes.Note

  @moduletag :bench
  @moduletag timeout: :infinity

  @http_count String.to_integer(System.get_env("BENCH_HTTP", "3000"))
  @notes_count String.to_integer(System.get_env("BENCH_NOTES", "3000"))
  @diagrams_count String.to_integer(System.get_env("BENCH_DIAGRAMS", "1000"))

  @words ~w(order customer payment invoice shipping address status pending active
    deploy release cluster node service gateway token session cache database query
    index migration rollback feature flag metric latency throughput error warning retry
    timeout backoff queue worker consumer producer topic partition offset schema
    validation request response header body json payload endpoint resource tenant
    account billing subscription plan trial upgrade downgrade refund charge ledger)

  setup %{conn: conn} do
    :rand.seed(:exsss, {1, 2, 3})
    sign_in(conn)
  end

  test "http history", %{conn: conn, username: username} do
    IO.puts("\n=== HTTP history: #{@http_count} entries ===")

    entries = for i <- 1..@http_count, do: http_entry(i)

    time("record every entry", fn ->
      for {metadata, request, response} <- entries,
          do: Resources.record(username, metadata, request, response)
    end)

    written(Resources, username)

    {metadata, request, response} = hd(entries)
    indexed = HistoryMetadata.with_search_text(metadata, request, response)
    IO.puts("search text of one entry: #{byte_size(indexed.search_text)} bytes")

    median("build one entry's search text", 20, fn ->
      HistoryMetadata.with_search_text(metadata, request, response)
    end)

    for term <- ["", "payment", "zzzz", "zzzz-nomatch", "api3.example.test"] do
      median("summaries(#{inspect(term)})", 5, fn -> Resources.summaries(username, term) end)
    end

    time("seal the whole history", fn ->
      MDTClient.Vault.seal(:crypto.strong_rand_bytes(32), Resources.all(username))
    end)

    {:ok, view, html} = time("mount /tools/http", fn -> live(conn, ~p"/tools/http") end)
    IO.puts("first render: #{byte_size(html)} bytes")

    for term <- ["payment", "zzzz", ""] do
      median("search event #{inspect(term)}", 5, fn ->
        view |> form("#history-search", %{term: term}) |> render_change()
      end)
    end
  end

  test "notes", %{conn: conn, username: username} do
    IO.puts("\n=== Notes: #{@notes_count} notes ===")

    time("save every note", fn ->
      for _ <- 1..@notes_count do
        Notes.save(username, Note.new_id(), %{
          title: sentence(4),
          body: markdown(1_000 + :rand.uniform(7_000))
        })
      end
    end)

    written(Notes, username)

    for term <- ["", "payment", "payment ledger", "zzzz"] do
      median("list(#{inspect(term)})", 5, fn -> Notes.list(username, term) end)
    end

    notes = Notes.all(username)

    median("seal every note", 3, fn ->
      MDTClient.Vault.seal(:crypto.strong_rand_bytes(32), notes)
    end)

    {:ok, view, html} = time("mount /tools/notes", fn -> live(conn, ~p"/tools/notes") end)
    IO.puts("first render: #{byte_size(html)} bytes")

    for term <- ["payment", ""] do
      median("search event #{inspect(term)}", 5, fn ->
        view |> form("#note-search", %{term: term}) |> render_change()
      end)
    end

    {:ok, %{id: id}} = Notes.latest(username)

    median("typing into the open note", 10, fn ->
      render_change(view, "edit", %{"note_id" => id, "body" => markdown(3_000)})
    end)
  end

  test "diagrams", %{conn: conn, username: username} do
    IO.puts("\n=== Diagrams: #{@diagrams_count} diagrams ===")

    time("save every diagram", fn ->
      for _ <- 1..@diagrams_count do
        Diagrams.save(username, Diagram.new_id(), %{
          title: sentence(3),
          elements: elements(20 + :rand.uniform(130))
        })
      end
    end)

    written(Diagrams, username)

    for term <- ["", "payment", "zzzz"] do
      median("list(#{inspect(term)})", 5, fn -> Diagrams.list(username, term) end)
    end

    {:ok, view, html} = time("mount /tools/diagrams", fn -> live(conn, ~p"/tools/diagrams") end)
    IO.puts("first render: #{byte_size(html)} bytes")

    median("search event \"payment\"", 5, fn ->
      view |> form("#diagram-search", %{term: "payment"}) |> render_change()
    end)

    {:ok, %{id: id}} = Diagrams.latest(username)

    median("dropping a shape on the open diagram", 10, fn ->
      render_hook(view, "save", %{"id" => id, "elements" => elements(100)})
    end)
  end

  defp http_entry(i) do
    request =
      Req.new(
        method: Enum.random([:get, :post, :put]),
        url: "https://api#{rem(i, 7)}.example.test/v1/#{word()}/#{i}?q=#{word()}",
        headers: [{"accept", "application/json"}, {"authorization", "Bearer token-#{i}"}],
        body: if(rem(i, 2) == 0, do: json(1_000)),
        decode_body: false,
        retry: false
      )

    response = %Req.Response{
      status: Enum.random([200, 201, 404, 500]),
      headers: %{"content-type" => ["application/json"], "x-request-id" => ["req-#{i}"]},
      body: json(5_000 + :rand.uniform(35_000))
    }

    description = if rem(i, 3) == 0, do: sentence(3)
    {HistoryMetadata.new(%{description: description, tags: [word()]}), request, response}
  end

  defp json(bytes) do
    item = fn ->
      ~s({"id":"#{:rand.uniform(1_000_000)}","name":"#{sentence(3)}",) <>
        ~s("description":"#{sentence(12)}","amount":#{:rand.uniform(10_000)}})
    end

    "[" <> Enum.join(up_to(item, bytes), ",") <> "]"
  end

  defp markdown(bytes) do
    line = fn ->
      case :rand.uniform(5) do
        1 -> "## " <> sentence(4)
        2 -> "- [ ] " <> sentence(8)
        3 -> "```\n" <> sentence(10) <> "\n```"
        _ -> sentence(25)
      end
    end

    Enum.join(up_to(line, bytes), "\n\n")
  end

  defp elements(count) do
    for i <- 1..count do
      case rem(i, 5) do
        0 ->
          %{"id" => "a#{i}", "type" => "arrow", "x1" => 0, "y1" => 0, "x2" => 10, "y2" => 10}
          |> Map.put("text", word())

        4 ->
          %{
            "id" => "t#{i}",
            "type" => "table",
            "x" => i * 10,
            "y" => i * 5,
            "text" => sentence(2)
          }
          |> Map.merge(%{"width" => 200, "height" => 100})
          |> Map.put(
            "rows",
            for(r <- 1..8, do: %{"id" => "r#{r}", "type" => "text", "name" => word()})
          )

        _ ->
          %{
            "id" => "e#{i}",
            "type" => "rectangle",
            "x" => i * 10,
            "y" => i * 5,
            "text" => sentence(6)
          }
          |> Map.merge(%{"width" => 100, "height" => 60})
      end
    end
  end

  # Pieces from `fun` until together they pass `bytes`.
  defp up_to(fun, bytes) do
    fun
    |> Stream.repeatedly()
    |> Enum.reduce_while({[], 0}, fn piece, {pieces, size} ->
      if size > bytes,
        do: {:halt, {pieces, size}},
        else: {:cont, {[piece | pieces], size + byte_size(piece)}}
    end)
    |> elem(0)
  end

  # Saves are written to disk a moment after the last one, by the store's own
  # process; timed before that, a list waits on the write.
  defp written(store, username) do
    Process.sleep(300)
    _ = :sys.get_state(MDTClient.Vault.Store.whereis(store, username))
  end

  defp word, do: Enum.random(@words)
  defp sentence(words), do: Enum.map_join(1..words, " ", fn _ -> word() end)

  defp time(label, fun) do
    {microseconds, result} = :timer.tc(fun)
    report(label, microseconds)
    result
  end

  defp median(label, runs, fun) do
    times = for _ <- 1..runs, do: fun |> :timer.tc() |> elem(0)
    report("#{label} (median of #{runs})", times |> Enum.sort() |> Enum.at(div(runs, 2)))
  end

  defp report(label, microseconds) do
    IO.puts(
      String.pad_trailing(label, 58) <>
        :erlang.float_to_binary(microseconds / 1000, decimals: 2) <> " ms"
    )
  end
end
