defmodule MDTClientWeb.TransferLiveTest do
  use MDTClientWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MDTClient.Accounts
  alias MDTClient.HttpClient.HistoryMetadata
  alias MDTClient.HttpClient.Resources
  alias MDTClient.Transfer
  alias MDTClient.VaultHelpers

  # Opening a file with a typed password stretches it, which takes ~150ms on
  # purpose; render_async/1 only waits 100ms.
  @derive_timeout 5_000

  setup %{conn: conn} do
    %{username: username} = identity = sign_in(conn)

    folder = Path.join(Accounts.dir(username), "exports")
    File.mkdir_p!(folder)

    Map.put(identity, :folder, folder)
  end

  test "the title bar leads here", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tools")

    {:ok, transfer, _html} =
      view
      |> element("#transfer-link")
      |> render_click()
      |> follow_redirect(conn, ~p"/transfer")

    assert has_element?(transfer, "#export-form")
    assert has_element?(transfer, "#import-form")
  end

  test "offers a file name that names the signed in user, and asks for no password", %{
    conn: conn,
    username: username
  } do
    {:ok, view, _html} = live(conn, ~p"/transfer")

    assert has_element?(view, "#export_path[value*='mdt-export-#{username}-']")
    refute has_element?(view, "#export-form input[type=password]")
  end

  test "exports where it is told to", %{conn: conn, username: username, folder: folder} do
    record(username, "https://api.example.test/health")
    path = Path.join(folder, "mine.mdtexport")
    {:ok, view, _html} = live(conn, ~p"/transfer")

    view |> form("#export-form", export: %{path: path}) |> render_submit()
    render_async(view, @derive_timeout)

    assert has_element?(view, "#exported")

    assert {:ok,
            %{
              sections: [
                %{summary: "1 request"},
                %{summary: "No diagrams"},
                %{summary: "No notes"}
              ]
            }} = Transfer.read(username, path)
  end

  test "gives a path without an extension the export extension", %{conn: conn, folder: folder} do
    {:ok, view, _html} = live(conn, ~p"/transfer")

    view |> form("#export-form", export: %{path: Path.join(folder, "mine")}) |> render_submit()
    render_async(view, @derive_timeout)

    assert File.exists?(Path.join(folder, "mine.mdtexport"))
  end

  test "reports a folder it cannot write to", %{conn: conn, folder: folder} do
    {:ok, view, _html} = live(conn, ~p"/transfer")

    view
    |> form("#export-form", export: %{path: Path.join([folder, "missing", "mine.mdtexport"])})
    |> render_submit()

    render_async(view, @derive_timeout)

    assert has_element?(view, "#export-error")
    refute has_element?(view, "#exported")
  end

  test "merges by default, and changes nothing until confirmed", %{
    conn: conn,
    username: username,
    folder: folder
  } do
    path = Path.join(folder, "mine.mdtexport")
    record(username, "https://api.example.test/in-the-file")
    :ok = Transfer.export(username, path)
    :ok = Resources.clear(username)
    record(username, "https://api.example.test/current")

    {:ok, view, _html} = live(conn, ~p"/transfer")
    view |> form("#import-form", import: %{path: path}) |> render_submit()
    render_async(view, @derive_timeout)

    assert has_element?(view, "#import-plan")
    assert has_element?(view, "#import-section-http_client-history")
    assert has_element?(view, "#import-mode-merge[aria-checked=true]")
    refute has_element?(view, "#import-replace-warning")
    assert paths(username) == ["/current"]

    view |> element("#import-confirm") |> render_click()
    render_async(view, @derive_timeout)

    assert has_element?(view, "#imported")
    assert paths(username) == ["/current", "/in-the-file"]
  end

  test "replaces when asked to, after a warning", %{
    conn: conn,
    username: username,
    folder: folder
  } do
    path = Path.join(folder, "mine.mdtexport")
    record(username, "https://api.example.test/in-the-file")
    :ok = Transfer.export(username, path)
    :ok = Resources.clear(username)
    record(username, "https://api.example.test/current")

    {:ok, view, _html} = live(conn, ~p"/transfer")
    view |> form("#import-form", import: %{path: path}) |> render_submit()
    render_async(view, @derive_timeout)

    view |> element("#import-mode-replace") |> render_click()
    assert has_element?(view, "#import-mode-replace[aria-checked=true]")
    assert has_element?(view, "#import-replace-warning")

    view |> element("#import-confirm") |> render_click()
    render_async(view, @derive_timeout)

    assert has_element?(view, "#imported")
    assert paths(username) == ["/in-the-file"]
  end

  test "cancelling goes back to the form and keeps the data", %{
    conn: conn,
    username: username,
    folder: folder
  } do
    path = Path.join(folder, "mine.mdtexport")
    :ok = Transfer.export(username, path)
    record(username, "https://api.example.test/current")

    {:ok, view, _html} = live(conn, ~p"/transfer")
    view |> form("#import-form", import: %{path: path}) |> render_submit()
    render_async(view, @derive_timeout)
    view |> element("#import-cancel") |> render_click()

    assert has_element?(view, "#import-form")
    assert has_element?(view, "#import_path[value='#{path}']")
    refute has_element?(view, "#import-plan")
    assert paths(username) == ["/current"]
  end

  test "asks for the password of a file the sign in password does not open", %{
    conn: conn,
    username: username,
    folder: folder
  } do
    path = Path.join(folder, "theirs.mdtexport")
    other = VaultHelpers.also_unlock("someone-else", "their password")
    record(other, "https://api.example.test/theirs")
    :ok = Transfer.export(other, path)
    record(username, "https://api.example.test/mine")

    {:ok, view, _html} = live(conn, ~p"/transfer")
    refute has_element?(view, "#import_password")

    view |> form("#import-form", import: %{path: path}) |> render_submit()
    render_async(view, @derive_timeout)

    assert has_element?(view, "#import-error")
    assert has_element?(view, "#import_custom_password[checked]")
    assert has_element?(view, "#import_password")
    refute has_element?(view, "#import-plan")

    view
    |> form("#import-form",
      import: %{path: path, custom_password: "true", password: "their password"}
    )
    |> render_submit()

    render_async(view, @derive_timeout)

    assert has_element?(view, "#import-plan")
    view |> element("#import-confirm") |> render_click()
    render_async(view, @derive_timeout)

    # Theirs ran first, so it lands below this identity's own request.
    assert paths(username) == ["/mine", "/theirs"]
  end

  test "a wrong typed password is reported against the form", %{
    conn: conn,
    username: username,
    folder: folder
  } do
    path = Path.join(folder, "mine.mdtexport")
    :ok = Transfer.export(username, path)

    {:ok, view, _html} = live(conn, ~p"/transfer")
    view |> form("#import-form", import: %{custom_password: "true"}) |> render_change()

    view
    |> form("#import-form", import: %{path: path, custom_password: "true", password: "wrong pw"})
    |> render_submit()

    render_async(view, @derive_timeout)

    assert has_element?(view, "#import-error")
    refute has_element?(view, "#import-plan")
  end

  test "a picked path fills in the form", %{conn: conn, folder: folder} do
    {:ok, view, _html} = live(conn, ~p"/transfer")

    view
    |> element("#export-browse")
    |> render_hook("select_path", %{"target" => "export", "path" => Path.join(folder, "picked")})

    assert has_element?(view, "#export_path[value='#{folder}/picked.mdtexport']")

    view
    |> element("#import-browse")
    |> render_hook("select_path", %{"target" => "import", "path" => "/some/where.mdtexport"})

    assert has_element?(view, "#import_path[value='/some/where.mdtexport']")
  end

  test "without the desktop shell the picker says to type the path", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/transfer")

    view
    |> element("#import-browse")
    |> render_hook("picker_unavailable", %{"target" => "import", "reason" => "Type it"})

    assert has_element?(view, "#import-card-notice")
    refute has_element?(view, "#export-card-notice")
  end

  defp paths(username) do
    Enum.map(Resources.all(username), fn {_id, _metadata, request, _response} ->
      request.url.path
    end)
  end

  defp record(username, url) do
    Resources.record(
      username,
      HistoryMetadata.new(%{}),
      Req.new(url: url),
      %Req.Response{status: 200}
    )
  end
end
