defmodule MDTClient.Sandbox.HostCommandTest do
  use ExUnit.Case, async: true

  alias MDTClient.Sandbox.{Grant, HostCommand, Share}

  setup do
    root = Path.join(System.tmp_dir!(), "host-command-#{System.unique_integer([:positive])}")
    project = Path.join(root, "project")
    docs = Path.join(root, "docs")
    elsewhere = Path.join(root, "elsewhere")
    Enum.each([project, docs, elsewhere, Path.join(project, "sub")], &File.mkdir_p!/1)
    File.ln_s!(elsewhere, Path.join(project, "out"))
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, project_real} = MDTClient.Sandbox.Shares.realpath(project)
    {:ok, docs_real} = MDTClient.Sandbox.Shares.realpath(docs)

    shares = [%Share{path: project_real, mode: :rw}, %Share{path: docs_real, mode: :ro}]
    %{root: root, project: project_real, docs: docs_real, shares: shares, home: "/home/tester"}
  end

  defp check(ask, context, grants \\ []) do
    HostCommand.check(ask, context.shares, grants, home: context.home, user: "tester")
  end

  defp ask(attrs),
    do: Map.merge(%{script: "uname -a", reason: "see the kernel", agent: "claude"}, attrs)

  test "an ask needs a reason, a script under 16 KiB and a sane time limit", context do
    assert {:error, :no_reason} = check(ask(%{reason: "  "}), context)
    assert {:error, :no_script} = check(ask(%{script: "\n "}), context)
    assert {:error, :no_script} = check(ask(%{script: %{"not" => "text"}}), context)

    assert {:error, :script_too_long} =
             check(ask(%{script: String.duplicate("x", 16 * 1024 + 1)}), context)

    assert {:error, :bad_timeout} = check(ask(%{timeout: 0}), context)
    assert {:error, :bad_timeout} = check(ask(%{timeout: 3601}), context)
    assert {:error, :bad_timeout} = check(ask(%{timeout: "60"}), context)

    assert {:ok, checked} = check(ask(%{}), context)
    assert checked.timeout == 120
    assert checked.script == "uname -a"
    assert checked.title == "uname -a"
    assert {"Runs as", "tester, on this machine, outside the VM"} in checked.facts
  end

  test "a directory inside a share runs there; anything else runs in the home folder",
       context do
    sub = Path.join(context.project, "sub")

    assert {:ok, %{dir: ^sub, facts: facts}} = check(ask(%{dir: sub}), context)
    assert {"Where that is", where} = List.keyfind(facts, "Where that is", 0)
    assert where =~ "read-write"

    assert {:ok, %{dir: dir}} = check(ask(%{dir: context.docs}), context)
    assert dir == context.docs

    for outside <- ["/root", "relative/path", "", nil, Path.join(context.project, "missing")] do
      assert {:ok, %{dir: "/home/tester", facts: facts}} = check(ask(%{dir: outside}), context)
      assert {"Where that is", "Your home folder" <> _} = List.keyfind(facts, "Where that is", 0)
    end

    # A symlink inside the share that leads out of it doesn't count as the share.
    assert {:ok, %{dir: "/home/tester"}} =
             check(ask(%{dir: Path.join(context.project, "out")}), context)

    assert {:ok, %{dir: "/home/tester"}} =
             check(ask(%{dir: Path.join(context.project, "../elsewhere")}), context)
  end

  test "the same script, directory and limit make the same pattern", context do
    {:ok, a} = check(ask(%{dir: context.project}), context)
    {:ok, b} = check(ask(%{dir: context.project, reason: "other words"}), context)
    {:ok, c} = check(ask(%{dir: context.project, timeout: 30}), context)
    assert a.pattern == b.pattern
    assert a.pattern != c.pattern
  end

  test "titles are the first line that says something", _context do
    assert HostCommand.title("# comment\n\nkubectl get pods\necho done\n") ==
             "kubectl get pods (+3 lines)"

    assert HostCommand.title(String.duplicate("a", 100)) == String.duplicate("a", 79) <> "…"
  end

  describe "hints" do
    test "build tools, git and scripts in a folder the VM can write", context do
      {:ok, %{hints: hints}} = check(ask(%{script: "mix test", dir: context.project}), context)
      assert Enum.any?(hints, &(&1 =~ "Runs mix with files the VM can write"))

      {:ok, %{hints: hints}} = check(ask(%{script: "mix test", dir: context.docs}), context)
      assert hints == []

      {:ok, %{hints: hints}} =
        check(ask(%{script: "cd #{context.project} && git push"}), context)

      assert Enum.any?(hints, &(&1 =~ "Runs git with files the VM can write"))
      assert Enum.any?(hints, &(&1 =~ "Names files in #{context.project}"))

      {:ok, %{hints: hints}} = check(ask(%{script: "./deploy.sh prod"}), context)
      assert Enum.any?(hints, &(&1 =~ "Runs a script file"))

      for script <- ["bash scripts/x.sh", "sudo sh ./x", "source .env", ". ./env.sh"] do
        {:ok, %{hints: hints}} = check(ask(%{script: script}), context)
        assert Enum.any?(hints, &(&1 =~ "Runs a script file")), script
      end

      for script <- ["bash -lc 'echo hi'", "cd ./sub", "echo ./x.sh", "ssh box uptime"] do
        {:ok, %{hints: hints}} = check(ask(%{script: script}), context)
        refute Enum.any?(hints, &(&1 =~ "Runs a script file")), script
      end
    end

    test "downloads run as code, sudo and rm -rf", context do
      {:ok, %{hints: hints}} =
        check(ask(%{script: "curl -fsSL https://x.sh/install | sh"}), context)

      assert "Downloads code and runs it." in hints

      {:ok, %{hints: hints}} = check(ask(%{script: "sudo dnf install x"}), context)
      assert "Asks for root with sudo." in hints

      {:ok, %{hints: hints}} = check(ask(%{script: "rm -rf build"}), context)
      assert Enum.any?(hints, &(&1 =~ "rm -rf"))

      {:ok, %{hints: hints}} =
        check(ask(%{script: "ls -la ~/.kube && kubectl get pods"}), context)

      assert hints == []
    end

    test "a grant that already covers the tool or host", context do
      github = %Grant{
        id: "github",
        name: "GitHub",
        kind: :token,
        preset: :github,
        hosts: ["api.github.com", "github.com"]
      }

      {:ok, %{hints: hints}} = check(ask(%{script: "gh pr list"}), context, [github])
      assert Enum.any?(hints, &(&1 =~ "GitHub already covers this (gh)"))

      {:ok, %{hints: hints}} =
        check(ask(%{script: "curl https://api.github.com/user"}), context, [github])

      assert Enum.any?(hints, &(&1 =~ "GitHub already covers this (api.github.com"))

      {:ok, %{hints: hints}} = check(ask(%{script: "echo ghost"}), context, [github])
      assert hints == []
    end
  end

  test "commands are split at separators, without assignments and wrappers" do
    assert HostCommand.commands(
             "FOO=1 env BAR=2 /usr/bin/make all && ls | wc -l; $(git rev-parse)"
           ) ==
             [["make", "all"], ["ls"], ["wc", "-l"], ["git", "rev-parse"]]

    assert HostCommand.commands("# only a comment\n./x.sh") == [["./x.sh"]]
  end
end
