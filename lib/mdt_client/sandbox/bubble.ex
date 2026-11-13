defmodule MDTClient.Sandbox.Bubble do
  @moduledoc """
  The bubble one identity's VM runs in: `bwrap` (bubblewrap) around
  microsandbox, so the process running the VM has

    * namespaces of its own: user, mount, network, PID, IPC, UTS, cgroup;
    * `/usr` read-only and no `/home`, `/etc` or `/run` of yours;
    * no network but loopback, with a default route that leads nowhere.

  Its first process is MDT's relay (`native/mdt_relay`, built to
  `bin/mdt-relay` beside `msb`). The relay joins msb's proxy and DNS ports
  to MDT's sockets, runs the `msb create` or `msb start` it is given,
  answers `control.sock`, and is process 1 in there, so the VM runs exactly
  as long as it does.

  Everything the VM is made of is bound under `/mdt`, a path that exists
  only in the bubble:

      /mdt/runtime    msb, its guest kernel, the relay       read-only
      /mdt/sockets    MDTClient.Sandbox.Sockets
      /mdt/disks      MDTClient.Sandbox.Disks
      /mdt/inbox      MDTClient.Sandbox.Inbox                read-only
      /mdt/optmem     the VM's memory
      /mdt/shares/N   each shared folder, as you set it

  So the VM names its disks and folders by paths the host doesn't have, and
  an `msb` outside the bubble cannot boot it (msb boots a stopped VM by
  itself on `exec` and `ssh`). Only msb's own home keeps its paths, the
  real one and the short link to it (`MDTClient.Sandbox.Msb.home/1`), so
  `msb exec` from the host finds the running VM's sockets.

  The bubble is started detached: nothing ties it to MDT, so an MDT that
  crashes leaves the VM running, without internet until MDT listens again.
  It is found again through `control.sock`.

  Which `bwrap` makes it is `bwrap/0`: MDT's own copy where its package
  installed one, the system's elsewhere. Ubuntu (24.04 and later) lets a
  program hold capabilities in a user namespace only under an AppArmor
  profile that allows it, and its profile for `/usr/bin/bwrap` doesn't, so
  the deb installs a copy of the system's bwrap at `/usr/lib/mdt/bwrap` with
  a profile for what the bubble needs (`scripts/deb/postinst.sh`).
  """

  alias MDTClient.Sandbox.{Msb, Sockets}

  @inside "/mdt"
  @own_bwrap "/usr/lib/mdt/bwrap"

  @type spec :: %{
          required(:username) => String.t(),
          required(:name) => String.t(),
          required(:disks) => Path.t(),
          required(:inbox) => Path.t(),
          required(:optmem) => Path.t(),
          required(:shares) => [{Path.t(), :ro | :rw}]
        }

  @doc "The path in the bubble of one of the VM's parts."
  @spec inside(:runtime | :sockets | :disks | :inbox | :optmem | {:share, non_neg_integer()}) ::
          String.t()
  def inside({:share, index}), do: "#{@inside}/shares/#{index}"

  def inside(part) when part in [:runtime, :sockets, :disks, :inbox, :optmem],
    do: "#{@inside}/#{part}"

  @doc """
  The `bwrap` the bubble is made with, or nil when there is none: MDT's own
  copy when its package installed one, else the system's.
  """
  @spec bwrap() :: String.t() | nil
  def bwrap do
    own = Keyword.get(Application.get_env(:mdt_client, __MODULE__, []), :own_bwrap, @own_bwrap)
    if File.regular?(own), do: own, else: System.find_executable("bwrap")
  end

  @doc "MDT's relay, or nil when this build has no runtime."
  @spec relay() :: String.t() | nil
  def relay do
    path = Path.join(Msb.runtime_dir(), "bin/mdt-relay")
    if File.regular?(path), do: path
  end

  @doc """
  Whether a bubble can be made here, by making one: the namespaces and the
  two capabilities the real one asks for, with MDT's relay inside doing its
  first two steps (`mdt-relay --check`): the route into loopback, then no
  capability left. A system that refuses says so here, before a VM is
  offered, and the message says what to do about it. Without a relay in
  this build, only the namespaces are tried.
  """
  @spec available() :: :ok | {:error, String.t()}
  def available do
    case bwrap() do
      nil ->
        {:error, "bwrap isn't installed (package bubblewrap)."}

      bwrap ->
        args =
          ~w(--unshare-user --unshare-pid --unshare-net --unshare-ipc --unshare-uts --unshare-cgroup) ++
            ~w(--as-pid-1 --uid 0 --gid 0 --cap-add CAP_NET_ADMIN --cap-add CAP_SETPCAP) ++
            ["--ro-bind", "/usr", "/usr"] ++
            usr_links() ++
            ~w(--proc /proc --dev /dev) ++
            if(relay(),
              do:
                ["--ro-bind", Msb.runtime_dir(), inside(:runtime)] ++
                  ["--", inside(:runtime) <> "/bin/mdt-relay", "--check"],
              else: ["--", "/usr/bin/true"]
            )

        case System.cmd(bwrap, args, stderr_to_stdout: true) do
          {_, 0} -> :ok
          {output, _status} -> {:error, refusal(output |> String.trim() |> String.slice(0, 300))}
        end
    end
  end

  # Ubuntu's AppArmor is the one known cause: bwrap may make the namespaces
  # there and still hold no capability in them.
  defp refusal(output) do
    if File.exists?("/proc/sys/kernel/apparmor_restrict_unprivileged_userns") do
      "A bubble can't be made here (#{output}). On Ubuntu, AppArmor lets a program hold " <>
        "capabilities in a user namespace only with a profile for it. MDT's package installs " <>
        "one; for an MDT run from source: sudo sh scripts/deb/postinst.sh"
    else
      "A bubble can't be made here: #{output}"
    end
  end

  @doc """
  The whole `bwrap` command line that runs `msb` with `msb_words` in the
  bubble of `spec`.
  """
  @spec words(spec(), [String.t()]) :: [String.t()]
  def words(spec, msb_words) do
    home = Msb.home(spec.username)
    store = Msb.store(spec.username)

    shares =
      spec.shares
      |> Enum.with_index()
      |> Enum.flat_map(fn {{path, mode}, index} ->
        [if(mode == :rw, do: "--bind", else: "--ro-bind"), path, inside({:share, index})]
      end)

    env =
      Enum.flat_map(
        [
          {"PATH", "/usr/bin:/usr/sbin"},
          {"HOME", home},
          {"MSB_HOME", home},
          {"MSB_PATH", inside(:runtime) <> "/bin/msb"},
          {"MSB_BACKEND", "local"},
          {"NO_COLOR", "1"}
        ],
        fn {name, value} -> ["--setenv", name, value] end
      )

    # The relay is process 1: when it ends, the kernel ends the rest.
    # Root in the bubble only, with the two capabilities the relay uses
    # once (the route) and then gives up for good.
    # msb's home at its real path, which its records name, and at the short
    # one, which its sockets are under.
    [bwrap() || "bwrap"] ++
      ~w(--unshare-user --unshare-pid --unshare-net --unshare-ipc --unshare-uts --unshare-cgroup) ++
      ["--as-pid-1"] ++
      ~w(--uid 0 --gid 0 --cap-add CAP_NET_ADMIN --cap-add CAP_SETPCAP) ++
      ["--ro-bind", "/usr", "/usr"] ++
      usr_links() ++
      ~w(--proc /proc --dev /dev --dev-bind /dev/kvm /dev/kvm --tmpfs /tmp --tmpfs /run) ++
      ["--ro-bind", Msb.runtime_dir(), inside(:runtime)] ++
      ["--bind", Sockets.dir(spec.username), inside(:sockets)] ++
      ["--bind", spec.disks, inside(:disks)] ++
      ["--ro-bind", spec.inbox, inside(:inbox)] ++
      ["--bind", spec.optmem, inside(:optmem)] ++
      shares ++
      ["--bind", store, store, "--bind", store, home] ++
      ~w(--chdir / --clearenv) ++
      env ++
      ["--", inside(:runtime) <> "/bin/mdt-relay", "--sockets", inside(:sockets)] ++
      ["--name", spec.name, "--", inside(:runtime) <> "/bin/msb"] ++ msb_words
  end

  # /bin, /lib and the like are links into /usr on the systems MDT supports.
  defp usr_links do
    Enum.flat_map(~w(bin sbin lib lib64), fn name ->
      if File.exists?("/usr/#{name}"), do: ["--symlink", "usr/#{name}", "/#{name}"], else: []
    end)
  end

  @doc """
  Starts the bubble and waits, up to `seconds`, for the `msb` command in it
  to end. `{:ok, output}` when it went well; the bubble then stays, with the
  VM running in it.
  """
  @spec start(spec(), [String.t()], pos_integer()) :: {:ok, String.t()} | {:error, String.t()}
  def start(spec, msb_words, seconds \\ 300) do
    username = spec.username
    Msb.ensure_home!(username)

    cond do
      is_nil(relay()) ->
        {:error, "MDT's relay is missing"}

      status(username) != :down ->
        {:error, "The VM's bubble is already running."}

      true ->
        # A relay whose control socket is gone can't be asked to stop.
        kill_strays(spec.name)
        File.rm(Sockets.path(username, "start.out"))
        File.rm(Sockets.path(username, "bubble.pid"))

        # Detached (a session of its own), with its output in a file and its
        # process id written down, so a failure before the relay runs shows.
        launcher = ~s(echo $$ > "$MDT_PIDFILE"; exec "$@" > "$MDT_LOG" 2>&1 < /dev/null)

        {_, 0} =
          System.cmd(
            "setsid",
            ["--fork", "sh", "-c", launcher, "mdt-bubble" | words(spec, msb_words)],
            env: [
              {"MDT_PIDFILE", Sockets.path(username, "bubble.pid")},
              {"MDT_LOG", Sockets.path(username, "bubble.log")}
            ],
            stderr_to_stdout: true
          )

        await_start(username, System.monotonic_time(:millisecond) + seconds * 1_000)
    end
  end

  defp await_start(username, deadline) do
    case File.read(Sockets.path(username, "start.out")) do
      {:ok, text} ->
        case String.split(text, "\n", parts: 2) do
          ["0", output] -> {:ok, String.trim(output)}
          [_status, output] -> {:error, String.trim(output)}
          _ -> {:error, "The relay left no word on how the start went."}
        end

      {:error, _not_yet} ->
        cond do
          not bubble_alive?(username) ->
            {:error, "The bubble ended before the VM started: " <> log(username)}

          System.monotonic_time(:millisecond) > deadline ->
            {:error, "The VM took too long to start."}

          true ->
            Process.sleep(50)
            await_start(username, deadline)
        end
    end
  end

  defp bubble_alive?(username) do
    with {:ok, text} <- File.read(Sockets.path(username, "bubble.pid")),
         {pid, _} <- Integer.parse(text) do
      File.exists?("/proc/#{pid}")
    else
      # Not written yet.
      _ -> true
    end
  end

  defp log(username) do
    case File.read(Sockets.path(username, "bubble.log")) do
      {:ok, text} -> text |> String.trim() |> String.slice(-600, 600)
      {:error, _} -> ""
    end
  end

  @doc "Whether the identity's VM is up, as its relay says. `:down` when nothing answers."
  @spec status(String.t()) :: :running | :starting | :down
  def status(username) do
    case ask(username, "status", 2_000) do
      {:ok, "running" <> _} -> :running
      {:ok, "starting" <> _} -> :starting
      _stopped_or_nothing -> :down
    end
  end

  @doc """
  Stops the VM cleanly (`msb stop` in the bubble), which ends the bubble.
  Returns once nothing answers any more.
  """
  @spec stop(String.t(), pos_integer()) :: {:ok, String.t()} | {:error, String.t()}
  def stop(username, seconds \\ 110) do
    case ask(username, "stop", seconds * 1_000) do
      {:ok, "stopped" <> output} ->
        await_down(username, System.monotonic_time(:millisecond) + 5_000)
        {:ok, String.trim(output)}

      {:ok, other} ->
        {:error, String.trim(other)}

      {:error, reason} when reason in [:enoent, :econnrefused] ->
        {:ok, ""}

      {:error, reason} ->
        {:error, "The VM's relay didn't answer: #{inspect(reason)}"}
    end
  end

  # Down is when nothing answers and the relay's lock is free: the relay
  # holds it until its last moment, after its control socket is gone.
  defp await_down(username, deadline) do
    down? = status(username) == :down and lock_free?(username)

    if not down? and System.monotonic_time(:millisecond) < deadline do
      Process.sleep(50)
      await_down(username, deadline)
    end
  end

  defp lock_free?(username) do
    lock = Sockets.path(username, "relay.lock")

    not File.exists?(lock) or
      match?({_, 0}, System.cmd("flock", ["--nonblock", lock, "true"], stderr_to_stdout: true))
  end

  # One line to the relay, and everything it answers.
  defp ask(username, word, timeout) do
    path = Sockets.path(username, "control.sock")

    with {:ok, socket} <- :gen_tcp.connect({:local, path}, 0, [:binary, active: false], 2_000) do
      answer =
        with :ok <- :gen_tcp.send(socket, word <> "\n") do
          read(socket, "", timeout)
        end

      :gen_tcp.close(socket)
      answer
    end
  end

  defp read(socket, acc, timeout) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, data} -> read(socket, acc <> data, timeout)
      {:error, :closed} -> {:ok, acc}
      {:error, reason} -> {:error, reason}
    end
  end

  # Ends relays of this VM that nothing can ask any more. Each is process 1
  # of its bubble, so its VM ends with it: a power cut for the VM.
  defp kill_strays(name) do
    for entry <- File.ls!("/proc"),
        entry =~ ~r/^\d+$/,
        {:ok, raw} <- [File.read("/proc/#{entry}/cmdline")],
        [program | rest] = String.split(raw, <<0>>),
        String.ends_with?(program, "/mdt-relay"),
        Enum.chunk_every(rest, 2, 1, :discard) |> Enum.member?(["--name", name]) do
      System.cmd("kill", ["-KILL", entry], stderr_to_stdout: true)
    end

    :ok
  end
end
