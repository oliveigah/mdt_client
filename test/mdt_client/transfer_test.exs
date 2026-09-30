defmodule MDTClient.TransferTest do
  use ExUnit.Case, async: false

  import MDTClient.VaultHelpers

  alias MDTClient.Accounts
  alias MDTClient.Diagrams.Diagram
  alias MDTClient.Diagrams.Library
  alias MDTClient.HttpClient.Core
  alias MDTClient.HttpClient.HistoryMetadata
  alias MDTClient.HttpClient.Resources
  alias MDTClient.Transfer
  alias MDTClient.Transfer.Archive
  alias MDTClient.Transfer.FailingParticipant
  alias MDTClient.Transfer.Plan
  alias MDTClient.Vault.Keyring
  alias MDTClient.Vault.Store

  setup do
    identity = unlocked_identity()
    path = Path.join(Accounts.root(), "exports/test.mdtexport")
    File.mkdir_p!(Path.dirname(path))
    Map.put(identity, :path, path)
  end

  test "the identity that exported a file opens it with nothing more", %{
    username: username,
    path: path
  } do
    record(username, "https://api.example.test/one")
    assert :ok = Transfer.export(username, path)

    assert {:ok,
            %Plan{
              username: ^username,
              sections: [%{summary: "1 request"}, %{summary: "No diagrams"}]
            }} = Transfer.read(username, path)
  end

  test "another identity needs the password the file was exported with", %{
    username: username,
    password: password,
    path: path
  } do
    :ok = Transfer.export(username, path)

    # Even the same password: every identity derives its key with its own salt.
    other = also_unlock("someone-else", password)

    assert Transfer.read(other, path) == {:error, :bad_password}
    assert Transfer.read(other, path, password: "wrong horse") == {:error, :bad_password}
    assert {:ok, %Plan{username: ^username}} = Transfer.read(other, path, password: password)
  end

  test "merging brings another identity's history in beside its own", %{
    username: username,
    password: password,
    path: path
  } do
    record(username, "https://api.example.test/one")
    tagged = record(username, "https://api.example.test/two")
    {:ok, _entry} = Core.add_tag(username, tagged, "smoke")
    :ok = Transfer.export(username, path)

    other = also_unlock("someone-else")
    record(other, "https://api.example.test/theirs")

    {:ok, plan} = Transfer.read(other, path, password: password)

    assert [
             %{label: "HTTP request history", summary: "2 requests"},
             %{label: "Diagrams", summary: "No diagrams"}
           ] = plan.sections

    assert :ok = Transfer.import(other, plan, :merge)

    assert paths(other) == ["/theirs", "/two", "/one"]
    # Search text is left out of the file and rebuilt on the way back in.
    assert [{_, %HistoryMetadata{tags: ["smoke"]}, _, _}] = Resources.search(other, "smoke")

    # Idempotent: the same file again changes nothing.
    assert :ok = Transfer.import(other, plan, :merge)
    assert paths(other) == ["/theirs", "/two", "/one"]
  end

  test "replacing swaps the history for the file's", %{username: username, path: path} do
    record(username, "https://api.example.test/kept")
    :ok = Transfer.export(username, path)

    old = Enum.map(Resources.all(username), &elem(&1, 0))
    record(username, "https://api.example.test/after-the-export")

    {:ok, plan} = Transfer.read(username, path)
    assert :ok = Transfer.import(username, plan, :replace)

    assert [{identifier, _, %Req.Request{url: %URI{path: "/kept"}}, _}] = Resources.all(username)

    # Fresh identifiers, so nothing held from before resolves to another entry.
    refute identifier in old
    assert record(username, "https://api.example.test/next") > identifier
  end

  test "an imported history survives a lock and unlock", %{
    username: username,
    password: password,
    path: path
  } do
    record(username, "https://api.example.test/one")
    :ok = Transfer.export(username, path)
    :ok = Resources.clear(username)

    {:ok, plan} = Transfer.read(username, path)
    :ok = Transfer.import(username, plan, :merge)
    :ok = Store.close(username)

    {:ok, _profile, key} = Accounts.sign_in(username, password)
    :ok = Store.open(username, key)

    assert paths(username) == ["/one"]
  end

  test "an empty history round trips", %{username: username, path: path} do
    :ok = Transfer.export(username, path)

    assert {:ok, %Plan{sections: [%{summary: "No requests"}, %{summary: "No diagrams"}]}} =
             Transfer.read(username, path)
  end

  test "diagrams travel in the same file", %{username: username, password: password, path: path} do
    {:ok, diagram} =
      Library.save(username, Diagram.new_id(), %{
        title: "Checkout",
        elements: [%{"id" => "a", "type" => "rectangle", "text" => "Payment gateway"}]
      })

    :ok = Transfer.export(username, path)

    other = also_unlock("someone-else")
    {:ok, plan} = Transfer.read(other, path, password: password)
    assert [_requests, %{label: "Diagrams", summary: "1 diagram"}] = plan.sections
    assert :ok = Transfer.import(other, plan, :merge)

    assert {:ok, %{title: "Checkout"}} = Library.get(other, diagram.id)
    assert [%{id: id}] = Library.list(other, "gateway")
    assert id == diagram.id
  end

  test "reports a missing file, a file that is not an export and a blank password", %{
    username: username,
    path: path
  } do
    assert Transfer.read(username, path <> ".missing") == {:error, {:file, :enoent}}

    File.write!(path, "not an export")
    assert Transfer.read(username, path) == {:error, :not_an_export}
    assert Transfer.read(username, path, password: "") == {:error, :blank_password}
  end

  test "offers a file name that names the identity" do
    date = ~D[2026-09-22]

    assert Transfer.filename("oliveigah", date) == "mdt-export-oliveigah-2026-09-22.mdtexport"
    assert Transfer.filename("ana.silva@acme.io", date) =~ "mdt-export-ana.silva@acme.io-2026"

    assert Transfer.filename("../etc passwd", date) ==
             "mdt-export-..-etc-passwd-2026-09-22.mdtexport"

    assert Transfer.filename("///", date) == "mdt-export-2026-09-22.mdtexport"
  end

  test "a failed export leaves an earlier one where it was", %{username: username, path: path} do
    :ok = Transfer.export(username, path)
    before = File.read!(path)

    assert {:error, {:file, _reason}} =
             Transfer.export(username, Path.join(path, "not-a-folder.mdtexport"))

    assert File.read!(path) == before
    assert path |> Path.dirname() |> File.ls!() == ["test.mdtexport"]
  end

  test "sections no participant recognises are skipped and reported", %{
    username: username,
    path: path
  } do
    record(username, "https://api.example.test/one")
    {:ok, %{entries: entries}} = MDTClient.HttpClient.Transfer.export(username)

    write_archive(username, path, %{
      "http_client.history" => %{version: 1, data: %{entries: entries}},
      "someday.feature" => %{version: 3, data: :whatever}
    })

    assert {:ok, %Plan{skipped: ["someday.feature"], sections: [%{summary: "1 request"}]}} =
             Transfer.read(username, path)
  end

  test "a section newer than this build is refused whole", %{username: username, path: path} do
    write_archive(username, path, %{"http_client.history" => %{version: 2, data: %{entries: []}}})

    assert Transfer.read(username, path) == {:error, {:newer_section, "HTTP request history"}}
  end

  test "a damaged section is refused before anything changes", %{
    username: username,
    path: path
  } do
    record(username, "https://api.example.test/one")

    write_archive(username, path, %{
      "http_client.history" => %{version: 1, data: %{entries: [:junk]}}
    })

    assert {:error, {:invalid_section, "HTTP request history", _reason}} =
             Transfer.read(username, path)

    assert paths(username) == ["/one"]
  end

  for mode <- [:merge, :replace] do
    test "an import that fails partway puts back what it had already written (#{mode})", %{
      username: username,
      path: path
    } do
      participants = [MDTClient.HttpClient.Transfer, FailingParticipant]

      record(username, "https://api.example.test/in-the-file")
      :ok = Transfer.export(username, path, participants: participants)

      :ok = Resources.clear(username)
      record(username, "https://api.example.test/current")

      {:ok, plan} = Transfer.read(username, path, participants: participants)

      assert Transfer.import(username, plan, unquote(mode)) ==
               {:error, {:import_failed, "Failing section", "the disk is full"}}

      assert paths(username) == ["/current"]
    end
  end

  test "a plan keeps the decrypted history out of inspect", %{username: username, path: path} do
    record(username, "https://api.example.test/secret-path")
    :ok = Transfer.export(username, path)
    {:ok, plan} = Transfer.read(username, path)

    refute inspect(plan) =~ "secret-path"
  end

  defp write_archive(username, path, sections) do
    contents = %{
      created_at: DateTime.utc_now(),
      username: username,
      app_version: "0.0.0",
      sections: sections
    }

    archive = Archive.encode(contents, Keyring.kdf(username), &Keyring.seal(username, &1))
    File.write!(path, archive)
  end

  # Newest first, as the history panel lists them.
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
      %Req.Response{status: 200, body: "ok"}
    )
  end
end
