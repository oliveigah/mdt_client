defmodule MDTClient.Sandbox.SharesTest do
  use ExUnit.Case, async: true

  alias MDTClient.Sandbox.{Share, Shares}

  setup do
    root = Path.join(System.tmp_dir!(), "shares-#{System.unique_integer([:positive])}")
    home = Path.join(root, "home")
    data = Path.join(home, ".mdt_client")

    for dir <- ["projects/app/lib", "projects/other", ".ssh", ".config/gcloud", ".mdt_client"] do
      File.mkdir_p!(Path.join(home, dir))
    end

    File.write!(Path.join(home, "projects/notes.txt"), "")
    on_exit(fn -> File.rm_rf!(root) end)
    %{home: home, opts: [home: home, data_dir: data]}
  end

  test "shares a project folder by its resolved path", %{home: home, opts: opts} do
    assert {:ok, %Share{path: path, mode: :ro}} =
             Shares.validate("~/projects/app", :ro, [], opts)

    assert path == Path.join(home, "projects/app")
  end

  test "refuses credential folders, folders holding them, home and root", %{
    home: home,
    opts: opts
  } do
    assert {:error, {:refused, _, "SSH keys"}} = Shares.validate("~/.ssh", :rw, [], opts)

    assert {:error, {:refused, _, "Google Cloud credentials"}} =
             Shares.validate(Path.join(home, ".config"), :ro, [], opts)

    assert {:error, {:refused, _, "MDT's own data"}} =
             Shares.validate("~/.mdt_client", :rw, [], opts)

    assert {:error, :home} = Shares.validate("~", :rw, [], opts)
    assert {:error, :root} = Shares.validate("/", :ro, [], opts)
  end

  test "resolves symlinks before judging, so a link can't smuggle a refused folder in",
       %{home: home, opts: opts} do
    link = Path.join(home, "projects/app/keys")
    File.ln_s!(Path.join(home, ".ssh"), link)

    assert {:error, {:refused, folder, "SSH keys"}} = Shares.validate(link, :ro, [], opts)
    assert folder == Path.join(home, ".ssh")
  end

  test "refuses overlaps either way, and the same folder reached another way",
       %{home: home, opts: opts} do
    app = %Share{path: Path.join(home, "projects/app"), mode: :rw}

    assert {:error, {:overlaps, _}} = Shares.validate("~/projects/app/lib", :ro, [app], opts)
    assert {:error, {:overlaps, _}} = Shares.validate("~/projects", :ro, [app], opts)
    assert {:error, :duplicate} = Shares.validate("~/projects/other/../app", :rw, [app], opts)
    assert {:ok, _} = Shares.validate("~/projects/other", :rw, [app], opts)
  end

  test "refuses what is not a folder", %{opts: opts} do
    assert {:error, :blank} = Shares.validate("  ", :rw, [], opts)
    assert {:error, :not_absolute} = Shares.validate("projects/app", :rw, [], opts)
    assert {:error, :missing} = Shares.validate("~/projects/gone", :rw, [], opts)
    assert {:error, :not_a_folder} = Shares.validate("~/projects/notes.txt", :rw, [], opts)
  end

  test "explains every refusal in a sentence" do
    for reason <- [
          :blank,
          :not_absolute,
          :missing,
          :not_a_folder,
          :loop,
          :root,
          :home,
          :duplicate
        ] do
      assert Shares.explain(reason) =~ "."
    end

    assert Shares.explain({:overlaps, "/a"}) =~ "/a"
    assert Shares.explain({:refused, "/h/.ssh", "SSH keys"}) =~ "SSH keys"
  end
end
