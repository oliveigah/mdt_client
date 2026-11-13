defmodule MDTClient.Sandbox.BubbleTest do
  use ExUnit.Case, async: true

  alias MDTClient.Sandbox.{Bubble, Msb, Sockets}

  # Only paths are made from it: no identity needs to exist.
  @user "bubble-tester"

  @spec_ %{
    username: @user,
    name: "mdt-abc",
    disks: "/data/sandbox/disks",
    inbox: "/data/sandbox/inbox",
    optmem: "/data/sandbox/optmem",
    shares: [{"/home/me/docs", :ro}, {"/home/me/scratch", :rw}]
  }

  defp pairs(words, flag) do
    words
    |> Enum.chunk_every(3, 1, :discard)
    |> Enum.filter(&(hd(&1) == flag))
    |> Enum.map(fn [_flag, from, to] -> {from, to} end)
  end

  test "the VM's process gets namespaces of its own and nothing of your account" do
    words = Bubble.words(@spec_, ["start", "mdt-abc"])

    for flag <-
          ~w(--unshare-user --unshare-pid --unshare-net --unshare-ipc --unshare-uts --unshare-cgroup --as-pid-1 --clearenv) do
      assert flag in words, flag
    end

    # Read-only: the system's programs, MDT's runtime, the inbox, a share
    # set read-only.
    assert pairs(words, "--ro-bind") == [
             {"/usr", "/usr"},
             {Msb.runtime_dir(), "/mdt/runtime"},
             {"/data/sandbox/inbox", "/mdt/inbox"},
             {"/home/me/docs", "/mdt/shares/0"}
           ]

    # Read-write: the sockets to MDT, the VM's disks and memory, a share set
    # read-write, and msb's own home, the only paths that are the same
    # outside: its real folder, and the short link its sockets are under.
    assert pairs(words, "--bind") == [
             {Sockets.dir(@user), "/mdt/sockets"},
             {"/data/sandbox/disks", "/mdt/disks"},
             {"/data/sandbox/optmem", "/mdt/optmem"},
             {"/home/me/scratch", "/mdt/shares/1"},
             {Msb.store(@user), Msb.store(@user)},
             {Msb.store(@user), Msb.home(@user)}
           ]

    # Nothing else of the host's is there: no home folder, no /etc, no /run
    # of yours, and no device but KVM.
    assert pairs(words, "--dev-bind") == [{"/dev/kvm", "/dev/kvm"}]
    refute "/" in (words -- ["--chdir", "/"])
    refute Enum.any?(words, &(&1 in ["/home", "/etc", System.user_home!()]))
  end

  test "the relay is the bubble's first process and runs msb from the bubble's paths" do
    words = Bubble.words(@spec_, ["create", "box:1", "--name", "mdt-abc"])
    {_bwrap, ["--" | command]} = Enum.split_while(words, &(&1 != "--"))

    assert command == [
             "/mdt/runtime/bin/mdt-relay",
             "--sockets",
             "/mdt/sockets",
             "--name",
             "mdt-abc",
             "--",
             "/mdt/runtime/bin/msb",
             "create",
             "box:1",
             "--name",
             "mdt-abc"
           ]

    assert {"MSB_PATH", "/mdt/runtime/bin/msb"} in pairs(words, "--setenv")
    assert {"MSB_HOME", Msb.home(@user)} in pairs(words, "--setenv")
  end

  test "with no relay answering, the VM is down and stopping it is done already" do
    assert Bubble.status(@user) == :down
    assert Bubble.stop(@user) == {:ok, ""}
  end

  test "whether a bubble can be made here comes back as :ok or as words" do
    case Bubble.available() do
      :ok -> :ok
      {:error, words} -> assert words =~ ~r/bwrap|bubble/
    end
  end

  test "the bubble is made with the system's bwrap unless MDT's package installed its own" do
    # No package installed one on a machine that runs the tests from source.
    assert Bubble.bwrap() in [System.find_executable("bwrap"), "/usr/lib/mdt/bwrap"]
    assert hd(Bubble.words(@spec_, ["start", "mdt-abc"])) == (Bubble.bwrap() || "bwrap")
  end
end
