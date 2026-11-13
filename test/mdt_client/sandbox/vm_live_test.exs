defmodule MDTClient.Sandbox.VMLiveTest do
  @moduledoc """
  A real VM in the bubble, with MDT's own proxy, DNS forwarder and agent
  channel on the other side of its sockets: the guarantees that only a VM
  can show. Not part of `mix test`:

      mix test --only vm

  It needs KVM, `bwrap`, MDT's runtime in `priv/microsandbox`
  (`scripts/build-microsandbox.sh`, `scripts/build-relay.sh`) and the
  internet, for a small Alpine image and for example.com. It makes a
  throwaway identity and removes its VM.
  """
  use ExUnit.Case, async: false

  alias MDTClient.Accounts
  alias MDTClient.Sandbox
  alias MDTClient.Sandbox.{Bubble, Disks, Guest, HostGit, Msb, PullRequest, PullRequests, Server}
  alias MDTClient.Vault.Store

  @moduletag :vm
  @moduletag timeout: 600_000

  setup do
    # Other tests keep the runtime away; this one is about it.
    saved = Application.get_env(:mdt_client, Msb)

    Application.put_env(
      :mdt_client,
      Msb,
      Keyword.put(saved, :runtime_dir, Application.app_dir(:mdt_client, "priv/microsandbox"))
    )

    on_exit(fn -> Application.put_env(:mdt_client, Msb, saved) end)

    context = MDTClient.VaultHelpers.unlocked_identity("vm")
    username = context.username
    name = Server.vm_name(username)

    # Whatever the test leaves running ends with it.
    on_exit(fn -> Bubble.stop(username, 60) end)

    dir = Path.join(Accounts.dir(username), "sandbox")
    folders = dir |> Disks.paths() |> Map.put(:optmem, Path.join(dir, "optmem"))
    share = Path.join(System.tmp_dir!(), "vm-share-#{System.unique_integer([:positive])}")
    File.mkdir_p!(share)
    File.write!(Path.join(share, "hello.txt"), "from your machine\n")
    on_exit(fn -> File.rm_rf!(share) end)

    Map.merge(context, %{name: name, folders: folders, share: share})
  end

  defp machine_pid(name) do
    Enum.find(File.ls!("/proc"), fn entry ->
      with true <- entry =~ ~r/^\d+$/,
           {:ok, raw} <- File.read("/proc/#{entry}/cmdline"),
           [_msb, "machine" | rest] <- String.split(raw, <<0>>) do
        Enum.chunk_every(rest, 2, 1, :discard) |> Enum.member?(["--name", name])
      else
        _ -> false
      end
    end)
  end

  defp events(username, outcome) do
    _ = :sys.get_state(Store.whereis(Server, username))
    for %{outcome: ^outcome} = event <- Sandbox.events(username), do: event
  end

  test "a VM in the bubble: confined, reached only through MDT, its disks kept", context do
    %{username: username, name: name, folders: folders, share: share} = context
    assert Bubble.available() == :ok
    assert Bubble.relay(), "build the relay first: scripts/build-relay.sh"

    assert {:ok, _} = Msb.run(username, ["pull", "alpine"], 180)
    :ok = Disks.ensure!(folders, %{home: 1, cache: 1, work: 2})
    File.mkdir_p!(folders.optmem)

    bubble = %{
      username: username,
      name: name,
      disks: folders.dir,
      inbox: Sandbox.snapshot(username).inbox,
      optmem: folders.optmem,
      shares: [{share, :ro}]
    }

    create =
      Msb.create_args(%{
        name: name,
        image: "alpine",
        shell: "/bin/sh",
        cpus: 2,
        memory_gib: 1,
        disk_gib: 4,
        write_budget_gib: 1,
        shares: [{share, :ro}],
        env: [{"MDT_TEST", "placeholder"}]
      })

    exec = fn script -> Msb.run(username, ["exec", name, "--", "sh", "-c", script], 120) end

    ## Created and started by the relay, in the bubble

    assert {:ok, _} = Bubble.start(bubble, create, 180)
    assert Bubble.status(username) == :running
    assert {:error, "The VM's bubble is already running."} = Bubble.start(bubble, create, 5)

    ## What the VM is made of

    assert {:ok, mounts} = exec.("mount | awk '{print $3, $5}' | sort")
    mounts = String.split(mounts, "\n", trim: true)

    for expected <- [
          "/root ext4",
          "/cache ext4",
          "/work ext4",
          "/mnt/mdt virtiofs",
          "/root/.optmem virtiofs",
          "#{share} virtiofs"
        ] do
      assert expected in mounts, "#{expected} is missing from:\n#{Enum.join(mounts, "\n")}"
    end

    assert {:ok, "from your machine\n"} = exec.("cat #{share}/hello.txt")
    assert {:ok, readonly} = exec.("touch #{share}/new 2>&1; echo done")
    assert readonly =~ "Read-only"
    refute File.exists?(Path.join(share, "new"))
    assert {:ok, "placeholder\n"} = exec.("echo $MDT_TEST")

    ## Guarantee 11: the process running the VM

    pid = machine_pid(name)
    assert pid, "no msb machine process for #{name}"

    for namespace <- ~w(user mnt net pid ipc uts cgroup) do
      refute File.read_link!("/proc/#{pid}/ns/#{namespace}") ==
               File.read_link!("/proc/self/ns/#{namespace}"),
             "the VM's process shares this machine's #{namespace} namespace"
    end

    root = File.ls!("/proc/#{pid}/root")
    refute "home" in root
    refute "etc" in root
    assert File.ls!("/proc/#{pid}/root/run") == []

    cards =
      File.read!("/proc/#{pid}/net/dev")
      |> String.split("\n", trim: true)
      |> Enum.drop(2)
      |> Enum.map(&(&1 |> String.split(":") |> hd() |> String.trim()))

    assert cards == ["lo"]
    status = File.read!("/proc/#{pid}/status")
    assert status =~ ~r/^NoNewPrivs:\s+1$/m
    assert status =~ ~r/^CapEff:\s+0+$/m
    assert status =~ ~r/^CapBnd:\s+0+$/m

    ## Guarantees 6 and 12: out only through MDT, DNS included

    assert {:ok, "<!doctype html>"} = exec.("wget -q -T 30 -O - http://example.com/ | head -c 15")
    assert [%{port: 80} | _] = events(username, :tunnel)
    assert "example.com" in Enum.map(events(username, :lookup), & &1.host)

    assert {:ok, elsewhere} =
             exec.("nslookup -type=a example.org 8.8.8.8 2>&1 | tail -2; echo done")

    refute elsewhere =~ "Address"
    refute "example.org" in Enum.map(events(username, :lookup), & &1.host)

    ## The agent channel and the boot script, with tools fetched through MDT

    # bash and socat for the `mdt` command, python3 for memo: Alpine has none.
    assert {:ok, _} =
             exec.(
               "apk add --no-cache bash socat python3 >/dev/null 2>&1; bash --version | head -1"
             )

    assert {:ok, grants} = exec.("/mnt/mdt/bin/mdt grants")
    assert grants =~ "No grants yet"

    assert {:ok, ""} = Msb.run(username, ["exec", name, "--", "/mnt/mdt/bin/mdt-boot"], 60)
    assert {:ok, block} = exec.("head -1 /root/.claude/CLAUDE.md; head -1 /root/.codex/AGENTS.md")
    assert block =~ ~r/\A<!-- mdt:begin.*\n<!-- mdt:begin/

    # The VM's memory is the one folder of its own that stays a folder here:
    # what the VM's memo made in it shows on this machine.
    if MDTClient.Sandbox.Memory.host_memo() do
      assert File.regular?(Path.join(folders.optmem, "memo"))
      assert File.regular?(Path.join(folders.optmem, "memory/LOG.txt"))
    end

    ## A pull request: the VM's work back through msb's pipe

    # Your repository, in the folder shared read-only, where the agent
    # clones it from: that clone's remote says which repository it is for.
    repo = Path.join(share, "app")
    File.mkdir_p!(repo)

    git = fn dir, args ->
      {out, 0} =
        System.cmd(
          "git",
          ["-C", dir, "-c", "user.name=Me", "-c", "user.email=me@example.test" | args],
          stderr_to_stdout: true
        )

      out
    end

    git.(repo, ["init", "-q", "-b", "master"])
    File.write!(Path.join(repo, "a.txt"), "from your machine\n")
    git.(repo, ["add", "--all"])
    git.(repo, ["commit", "-q", "-m", "first"])

    # The sandbox doesn't run this VM, so it is named to it.
    Application.put_env(:mdt_client, PullRequests, guest: Guest.vm(username, name))
    on_exit(fn -> Application.delete_env(:mdt_client, PullRequests) end)

    assert {:ok, _} = exec.("apk add --no-cache git >/dev/null 2>&1; git --version")

    assert {:ok, _} =
             exec.("""
             git -c safe.directory='*' clone -q #{repo} /work/app && cd /work/app &&
             git checkout -q -b fix && echo 'from the vm' >> a.txt && echo new > b.txt &&
             git add --all && git -c user.name=Agent -c user.email=agent@vm.invalid commit -q -m 'the fix'
             """)

    refs = git.(repo, ["for-each-ref"])

    assert {:ok, %PullRequest{repo: ^repo, base: "master", stats: %{commits: 1, files: 2}} = pull,
            :opened} =
             PullRequests.open(username, %{cwd: "/work/app", title: "The fix", agent: "test"})

    assert git.(repo, ["for-each-ref"]) == refs

    head = git.(repo, ["rev-parse", "HEAD"])
    here = %{how: :changes, where: {:worktree, repo}}
    assert {:ok, _} = PullRequests.land(username, pull.id, here)
    assert File.read!(Path.join(repo, "a.txt")) == "from your machine\nfrom the vm\n"
    assert git.(repo, ["status", "--porcelain"]) == " M a.txt\n?? b.txt\n"
    assert git.(repo, ["rev-parse", "HEAD"]) == head
    assert {:ok, _} = PullRequests.undo(username, pull.id)
    assert git.(repo, ["status", "--porcelain"]) == ""

    # Your branch moved; sent back with it, it arrives in the VM's repository.
    File.write!(Path.join(repo, "c.txt"), "yours\n")
    git.(repo, ["add", "--all"])
    git.(repo, ["commit", "-q", "-m", "second"])
    assert {:ok, _} = PullRequests.send_back(username, pull.id, "Merge mine.", true)
    assert {:ok, sent} = exec.("git -C /work/app rev-parse host/master")
    assert sent == git.(repo, ["rev-parse", "master"])

    # What the VM plants in its repository runs there, never here.
    assert {:ok, _} =
             exec.("""
             cd /work/app &&
             printf '#!/bin/sh\\ntouch /tmp/planted-hook-ran\\n' > .git/hooks/reference-transaction &&
             chmod +x .git/hooks/reference-transaction &&
             git config core.fsmonitor 'touch /tmp/planted-fsmonitor-ran; false' &&
             git -c user.name=Agent -c user.email=agent@vm.invalid merge -q host/master &&
             echo more >> b.txt && git -c user.name=Agent -c user.email=agent@vm.invalid commit -q -am more
             """)

    File.rm("/tmp/planted-hook-ran")
    File.rm("/tmp/planted-fsmonitor-ran")

    assert {:ok, %PullRequest{revision: 2, status: :open}, :updated} =
             PullRequests.open(username, %{cwd: "/work/app", agent: "test"})

    assert {:ok, _} =
             PullRequests.land(username, pull.id, %{how: :commits, where: {:worktree, repo}})

    assert File.read!(Path.join(repo, "b.txt")) == "new\nmore\n"
    refute File.exists?("/tmp/planted-hook-ran")
    refute File.exists?("/tmp/planted-fsmonitor-ran")
    assert {:ok, "ran in the vm\n"} = exec.("test -e /tmp/planted-hook-ran && echo ran in the vm")
    Application.delete_env(:mdt_client, PullRequests)

    ## The disks across a stop, a start and a recreate

    assert {:ok, _} =
             exec.("echo work > /work/marker; echo home > /root/marker; echo root > /var/marker")

    assert {:ok, stopped} = Bubble.stop(username)
    assert stopped =~ "Stopped"
    assert Bubble.status(username) == :down
    assert machine_pid(name) == nil

    # msb boots a stopped VM by itself on `start` and `exec`. Outside the
    # bubble it can't: the VM's disks aren't there.
    assert {:error, _} = Msb.run(username, ["start", name], 60)
    assert {:error, _} = exec.("echo booted")
    assert machine_pid(name) == nil

    assert {:ok, _} = Bubble.start(bubble, ["start", name], 180)
    assert {:ok, "work\nhome\nroot\n"} = exec.("cat /work/marker /root/marker /var/marker")

    assert {:ok, _} = Bubble.stop(username)
    assert {:ok, _} = Bubble.start(bubble, create, 180)
    # A recreate keeps the three disks and starts the root disk empty.
    assert {:ok, "work\nhome\nthe root disk is new\n"} =
             exec.(
               "cat /work/marker /root/marker; test -e /var/marker || echo the root disk is new"
             )

    ## Guarantee 6: a locked MDT leaves the VM without internet

    :ok = Store.close(username)
    assert Bubble.status(username) == :running

    assert {:ok, offline} =
             exec.("wget -q -T 8 -O - http://example.com/ 2>&1 | head -c 60; echo; echo done")

    refute offline =~ "<!doctype"

    assert {:ok, _} = Bubble.stop(username)
    assert machine_pid(name) == nil
  end

  # The same VM, driven the way the pages drive it: through the sandbox of
  # an unlocked identity, which the other tests keep away from microsandbox.
  defp wait_vm(username, wanted) do
    Enum.find_value(1..1_200, fn _ ->
      vm = Sandbox.snapshot(username).vm

      cond do
        vm.busy -> Process.sleep(100) && nil
        vm.error -> flunk("the VM reported: #{vm.error}")
        vm.status == wanted -> vm
        true -> Process.sleep(100) && nil
      end
    end) || flunk("the VM never became #{wanted}")
  end

  test "the sandbox creates, stops, starts and recreates its VM, and stops it when you lock",
       context do
    %{username: username, key: key, name: name} = context
    saved = Application.get_env(:mdt_client, Server)
    on_exit(fn -> Application.put_env(:mdt_client, Server, saved) end)

    # This identity's sandbox, started again as it runs outside the tests.
    :ok = Store.close(username)
    Application.put_env(:mdt_client, Server, Keyword.put(saved, :external, true))
    :ok = Store.open(username, key)

    assert Sandbox.snapshot(username).tools.needs == []
    assert {:ok, _} = Msb.run(username, ["pull", "alpine"], 180)
    server = Store.whereis(Server, username)
    :sys.replace_state(server, &%{&1 | image: %{&1.image | tag: "alpine", loaded?: true}})
    exec = fn script -> Msb.run(username, ["exec", name, "--", "sh", "-c", script], 120) end

    assert :ok = Sandbox.start_vm(username)
    assert %{exists?: true, record: %{id: first}} = wait_vm(username, :running)
    assert Bubble.status(username) == :running
    # The VM knows which it is.
    assert {:ok, "id=" <> rest} = exec.("cat /etc/mdt-vm")
    assert String.starts_with?(rest, first <> "\n")
    assert {:ok, "ext4\n"} = exec.("stat -f -c %T /work | sed 's#ext2/ext3#ext4#'")
    assert {:ok, _} = exec.("echo mine > /work/marker; echo mine > /root/marker")

    assert :ok = Sandbox.stop_vm(username)
    wait_vm(username, :stopped)
    assert Bubble.status(username) == :down

    assert :ok = Sandbox.start_vm(username)
    wait_vm(username, :running)
    assert {:ok, "mine\nmine\n"} = exec.("cat /work/marker /root/marker")

    # Home started empty; Work is never emptied; the Home it had is kept.
    assert :ok = Sandbox.recreate_vm(username, %{home: :empty})
    wait_vm(username, :running)

    assert {:ok, "mine\nhome is new\n"} =
             exec.("cat /work/marker; test -e /root/marker || echo home is new")

    # A new VM, a new record, in MDT and in the VM.
    assert %{record: %{id: second}} = Sandbox.snapshot(username).vm
    assert second != first
    assert {:ok, "id=" <> ^second <> _} = exec.("cat /etc/mdt-vm")

    assert [%{id: _}] = Sandbox.snapshot(username).snapshots

    # A pull request, opened by the real `mdt` command in the VM.
    repo = Path.join(System.tmp_dir!(), "vm-flow-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(repo) end)
    File.mkdir_p!(repo)

    git = fn args ->
      {out, 0} =
        System.cmd(
          "git",
          ["-C", repo, "-c", "user.name=Me", "-c", "user.email=me@example.test" | args],
          stderr_to_stdout: true
        )

      out
    end

    git.(["init", "-q", "-b", "master"])
    File.write!(Path.join(repo, "a.txt"), "yours\n")
    git.(["add", "--all"])
    git.(["commit", "-q", "-m", "first"])

    assert {:ok, _} = exec.("apk add --no-cache git bash socat >/dev/null 2>&1; git --version")

    # `mdt vm`, and the line an interactive login shell prints.
    assert {:ok, said} = exec.("/mnt/mdt/bin/mdt vm")
    assert said =~ "This is the VM MDT runs" and said =~ "vm #{second}"
    assert {:ok, login} = exec.("bash -lic true 2>&1")
    assert login =~ "This is the VM MDT runs"

    # The agent's repository starts from yours, sent through msb's pipe; it
    # has no remote, so `mdt pr` is told which repository it is for.
    guest = Guest.vm(username, name)
    assert {:ok, _} = exec.("git init -q -b main /work/app")

    assert {:ok, _} =
             HostGit.run(repo, ["push", guest.git_url.("/work/app"), "master:refs/heads/start"],
               env: guest.env
             )

    assert {:ok, handed} =
             exec.("""
             cd /work/app && git checkout -q -b task start && echo 'the vm' >> a.txt &&
             git -c user.name=Agent -c user.email=agent@vm.invalid commit -q -am 'the task' &&
             /mnt/mdt/bin/mdt pr --title 'The task' --repo #{repo} && /mnt/mdt/bin/mdt prs
             """)

    assert handed =~ "Opened pull request #1" and handed =~ "open, waiting for the user"

    assert [%PullRequest{id: id, title: "The task", source: %{branch: "task"}, status: :open}] =
             Sandbox.snapshot(username).pulls

    assert {:ok, %PullRequest{status: :merged}} =
             PullRequests.land(username, id, %{how: :commits, where: {:worktree, repo}})

    assert File.read!(Path.join(repo, "a.txt")) == "yours\nthe vm\n"
    assert git.(["status", "--porcelain"]) == ""
    assert git.(["log", "-1", "--format=%s %an"]) == "the task Agent\n"

    # A command grant, asked through the real `mdt` in the VM. With none,
    # nothing can be asked; with a script of yours, the agent sends no text,
    # and `mdt` doesn't sit waiting on a stdin nobody writes to.
    assert {:error, refused} =
             exec.("/mnt/mdt/bin/mdt run shell --reason r --wait 0 -- echo hi 2>&1")

    assert refused =~ "No grant lets you run a command"

    {:ok, _} =
      Sandbox.create_grant(username, %{
        "kind" => "command",
        "name" => "where",
        "purpose" => "Say where it runs",
        "script" => "pwd",
        "dir" => repo
      })

    {:ok, _} = Sandbox.turn_on(username, "where", :until_off, :ask)
    assert {:error, waiting} = exec.("/mnt/mdt/bin/mdt run where --reason 'see it' --wait 0 2>&1")
    assert waiting =~ "mdt wait run-"

    assert [%{kind: :command, grant_id: "where", script: "pwd", dir: ^repo} = command] =
             Sandbox.snapshot(username).waiting

    :ok = Sandbox.decide(username, command.id, :decline)

    # The launcher goes into the VM while it runs, and only then.
    launcher = Sandbox.snapshot(username).tools.launcher
    assert {"in the vm\n", 0} = System.cmd(launcher, ["exec", name, "--", "echo", "in the vm"])

    :ok = Store.close(username)
    assert Bubble.status(username) == :down
    assert machine_pid(name) == nil

    assert {output, 1} =
             System.cmd(launcher, ["exec", name, "--", "true"], stderr_to_stdout: true)

    assert output =~ "isn't running"
    assert machine_pid(name) == nil
  end
end
