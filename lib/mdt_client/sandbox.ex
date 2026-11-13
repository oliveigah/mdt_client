defmodule MDTClient.Sandbox do
  @moduledoc """
  The agent sandbox: a microsandbox VM that agents run in, the grants that
  give it access, and the approvals that hold its requests.

  This module is the only way in for the control panel. Behind it,
  `MDTClient.Sandbox.Server` keeps one identity's sandbox and
  `MDTClient.Sandbox.Egress` is the proxy all of the VM's traffic goes
  through. `docs/agent_sandbox.md` has the design.

  Every function takes the username it belongs to. Changes are broadcast to
  `subscribe/1`rs as `{:sandbox_changed, area}`, new activity as
  `{:sandbox_event, event}` and image build output as
  `{:sandbox_build_line, line}`. `subscribe_waiting/1` delivers only
  `{:sandbox_waiting, count}`, for the title bar of every page.

  Approvals are of three types, in one queue: agents asking for a grant to
  be turned on (activations) or to run a command on the host (commands),
  both arriving through `MDTClient.Sandbox.Channel`, and uses of a grant
  held by the proxy. See `MDTClient.Sandbox.Approval`.
  """

  alias MDTClient.Sandbox.{
    Approval,
    Build,
    Destinations,
    Event,
    Grant,
    Memory,
    Server,
    Settings,
    Share,
    Shares,
    Snapshot,
    VM
  }

  @type username :: String.t()

  @type snapshot :: %{
          vm: VM.t(),
          settings: Settings.t(),
          grants: [Grant.t()],
          values: %{String.t() => boolean()},
          waiting: [Approval.t()],
          running: [Approval.t()],
          history: [Approval.t()],
          image: map(),
          builds: [Build.t()],
          created_ref: String.t() | nil,
          snapshots: [Snapshot.t()],
          memory: map(),
          folders: map(),
          proxy: map(),
          tools: map(),
          inbox: String.t(),
          host: map()
        }

  @typedoc """
  What creating the VM does to what it keeps:

    * `home` - `:keep` it, go back to `{:snapshot, id}`, or start `:empty`;
    * `cache` - `:keep` it or `:clear` it;
    * `seed_memory` - start the VM's memory from a copy of yours.

  Home is copied into a snapshot first whenever it holds anything.
  """
  @type create_options :: %{
          optional(:home) => :keep | :empty | {:snapshot, String.t()},
          optional(:cache) => :keep | :clear,
          optional(:seed_memory) => boolean()
        }

  @doc "Subscribes the caller to every change."
  @spec subscribe(username()) :: :ok | {:error, term()}
  def subscribe(username), do: Phoenix.PubSub.subscribe(MDTClient.PubSub, Server.topic(username))

  @doc "Subscribes the caller to the count of approvals waiting."
  @spec subscribe_waiting(username()) :: :ok | {:error, term()}
  def subscribe_waiting(username),
    do: Phoenix.PubSub.subscribe(MDTClient.PubSub, Server.waiting_topic(username))

  @doc "Everything the control panel shows, apart from activity."
  @spec snapshot(username()) :: snapshot()
  def snapshot(username), do: Server.call(username, :snapshot)

  @doc "How many approvals of either type wait for you; 0 while locked."
  @spec waiting_count(username()) :: non_neg_integer()
  def waiting_count(username) do
    Server.call(username, :waiting_count)
  catch
    :exit, _locked -> 0
  end

  @doc """
  Activity, newest first.

  ## Filters

    * `:group` - one of the keys of `Event.groups/0`, or `"all"`
    * `:grant` - a grant id, or `""` for any
    * `:q` - words to look for in the summary, host and path
    * `:limit` - at most this many, 200 by default

  """
  @spec events(username(), map()) :: [Event.t()]
  def events(username, filters \\ %{}), do: Server.call(username, {:events, filters})

  @doc "The certificate of the CA only the VM trusts, as PEM."
  @spec ca_pem(username()) :: String.t()
  def ca_pem(username), do: Server.call(username, :ca_pem)

  @doc "Builds the VM image with podman and loads it into microsandbox."
  @spec build_image(username()) :: :ok | {:error, :busy | :no_podman | :no_msb}
  def build_image(username), do: Server.call(username, :build_image)

  @doc """
  Starts the VM, creating it first when it does not exist or its settings
  changed; `options` apply only then.
  """
  @spec start_vm(username(), create_options()) :: :ok | {:error, atom()}
  def start_vm(username, options \\ %{}), do: Server.call(username, {:start_vm, options})

  @doc "Stops the VM."
  @spec stop_vm(username()) :: :ok | {:error, :busy}
  def stop_vm(username), do: Server.call(username, :stop_vm)

  @doc "Creates the VM again from the current image, with the current settings."
  @spec recreate_vm(username(), create_options()) :: :ok | {:error, atom()}
  def recreate_vm(username, options \\ %{}), do: Server.call(username, {:recreate_vm, options})

  @doc "Makes a kept build current again. The VM picks it up when recreated."
  @spec use_build(username(), String.t()) :: :ok | {:error, :busy | :not_found}
  def use_build(username, ref), do: Server.call(username, {:use_build, ref})

  @doc """
  The VM's memories you haven't reviewed: those noted after its memory was
  copied from yours, or after your last review. `upto` is what to pass to
  `bring_back/4` or `dismiss_memories/2` once you are done with them.
  """
  @spec vm_memories(username()) :: %{entries: [Memory.entry()], upto: non_neg_integer()}
  def vm_memories(username) do
    %{optmem: optmem, from: from} = Server.call(username, :memory)
    %{entries: Memory.entries(optmem, from), upto: Memory.count(optmem)}
  end

  @doc """
  Adds `texts`, chosen from the VM's memories, to your memory with
  `memo note`, and marks everything up to `upto` reviewed when all of them
  went in. Returns memo's answer per text.
  """
  @spec bring_back(username(), [String.t()], non_neg_integer()) ::
          [:ok | {:error, String.t()}]
  def bring_back(username, texts, upto) do
    results = Memory.bring_back(texts)
    added = Enum.count(results, &(&1 == :ok))

    if Enum.all?(results, &(&1 == :ok)),
      do: Server.call(username, {:reviewed, upto, added}),
      else: if(added > 0, do: Server.call(username, {:reviewed, 0, added}))

    results
  end

  @doc "Marks the VM's memories up to `upto` reviewed without adding any."
  @spec dismiss_memories(username(), non_neg_integer()) :: :ok
  def dismiss_memories(username, upto), do: Server.call(username, {:reviewed, upto, 0})

  @doc "Replaces the VM's memory with a copy of yours. Only while the VM is stopped."
  @spec seed_memory(username()) :: :ok | {:error, :busy | :running | :no_memory}
  def seed_memory(username), do: Server.call(username, :seed_memory)

  @doc """
  Turns a grant on for `minutes`, or `:until_off`. With `uses: :all`, every
  use goes through without asking while it stays on; otherwise each one
  waits for you. Agents waiting for it hear it is on.
  """
  @spec turn_on(username(), String.t(), pos_integer() | :until_off, :ask | :all) ::
          {:ok, Grant.t()} | {:error, :not_found}
  def turn_on(username, id, minutes, uses \\ :ask),
    do: Server.call(username, {:turn_on, id, minutes, uses})

  @doc "Turns a grant off. Requests waiting on it are refused."
  @spec turn_off(username(), String.t()) :: {:ok, Grant.t()} | {:error, :not_found}
  def turn_off(username, id), do: Server.call(username, {:turn_off, id})

  @doc """
  Lets every use of an `on` grant through without asking, for `minutes` or
  while it stays on (`:grant`). Uses waiting on it go through at once.
  """
  @spec allow_all(username(), String.t(), pos_integer() | :grant) ::
          {:ok, Grant.t()} | {:error, :not_found | :off}
  def allow_all(username, id, duration), do: Server.call(username, {:allow_all, id, duration})

  @doc "Ends a temporary allowance early."
  @spec revoke_allowance(username(), String.t(), String.t()) ::
          {:ok, Grant.t()} | {:error, :not_found}
  def revoke_allowance(username, id, allowance_id),
    do: Server.call(username, {:revoke_allowance, id, allowance_id})

  @doc """
  Adds a grant from the add dialog's params. It starts off.

    * every type: `"kind"` (`"token"`, `"network"` or `"file"`), `"name"`,
      `"purpose"` (what it is for, which agents read), and `"preset"` when a
      preset filled the form;
    * `"token"`: `"hosts"`, `"env"`, `"file_env"`, `"git"`, `"prefix"` (how
      the placeholder starts), `"source"` (`"stored"` with `"value"`, or
      `"minted"` with `"mint"`, a command printing a short-lived token);
    * `"network"`: `"destinations"`, one per line;
    * `"file"`: `"path"` (a file name) and `"value"`.

  Lists are comma or newline separated.
  """
  @spec create_grant(username(), map()) :: {:ok, Grant.t()} | {:error, %{atom() => String.t()}}
  def create_grant(username, attrs), do: Server.call(username, {:create_grant, attrs})

  @doc "Replaces a grant's stored value."
  @spec set_value(username(), String.t(), String.t()) :: :ok | {:error, :not_found | :minted}
  def set_value(username, id, value), do: Server.call(username, {:set_value, id, value})

  @doc "Removes a grant. Requests waiting on it are refused."
  @spec delete_grant(username(), String.t()) :: :ok | {:error, :not_found}
  def delete_grant(username, id), do: Server.call(username, {:delete_grant, id})

  @doc """
  Decides a waiting approval.

  A use (a request or a connection):

    * `:allow_once`;
    * `{:allow, :similar, duration}` - this one, and uses like it for
      `duration` (minutes, or `:grant` while the grant stays on);
    * `{:allow, :all, duration}` - every use of its grant for `duration`;
    * `:deny`, or `:deny_and_turn_off`, which also turns its grant off.

  An activation (an agent asking for a grant):

    * `{:turn_on, minutes | :until_off, :ask | :all}` - turns the grant on;
      `:all` lets every use through while it stays on;
    * `{:set_up, grant_id}` - for an ask no grant met: the grant you just
      added for it, turned on for the minutes asked;
    * `:decline`.

  A command (an agent asking to run something on the host), waiting to run:

    * `{:run, :send}` - runs it once; its output goes back to the agent;
    * `{:run, :review}` - runs it once; when it ends, it waits again for
      you with its output;
    * `:decline`.

  A command that ran and waits with its output: `:send_output` or
  `:keep_output`.
  """
  @spec decide(username(), String.t(), Approval.decision()) ::
          :ok | {:error, :not_waiting | :bad_decision}
  def decide(username, approval_id, decision),
    do: Server.call(username, {:decide, approval_id, decision})

  @doc "Stops a command running on the host: TERM to its processes, KILL 5 seconds later."
  @spec stop_command(username(), String.t()) :: :ok | {:error, :not_running}
  def stop_command(username, approval_id),
    do: Server.call(username, {:stop_command, approval_id})

  @doc """
  Looks again for the command-line tools agents are told about (`mdt host`),
  in the background.
  """
  @spec probe_host(username()) :: :ok | {:error, :busy}
  def probe_host(username), do: Server.call(username, :probe_host)

  @doc """
  Changes resources, the hold time, the proxy port, the image name, the
  Containerfile or your notes about this machine (`"host_notes"`) from the
  settings forms.
  """
  @spec update_settings(username(), map()) ::
          {:ok, Settings.t()} | {:error, %{atom() => String.t()}}
  def update_settings(username, attrs), do: Server.call(username, {:update_settings, attrs})

  @doc "Shares a folder, if `MDTClient.Sandbox.Shares` allows it."
  @spec add_share(username(), String.t(), :rw | :ro) ::
          {:ok, Share.t()} | {:error, Shares.reason()}
  def add_share(username, path, mode), do: Server.call(username, {:add_share, path, mode})

  @doc "Stops sharing a folder."
  @spec remove_share(username(), String.t()) :: :ok
  def remove_share(username, path), do: Server.call(username, {:remove_share, path})

  @doc "Makes a shared folder read-write or read-only."
  @spec set_share_mode(username(), String.t(), :rw | :ro) :: :ok
  def set_share_mode(username, path, mode),
    do: Server.call(username, {:set_share_mode, path, mode})

  @doc """
  The addresses MDT always refuses for the VM: loopback, link-local,
  unspecified and every address of this machine's own interfaces.
  """
  @spec refused_addresses() :: [String.t()]
  def refused_addresses do
    own = Enum.map(Destinations.host_addresses(), &to_string(:inet.ntoa(&1)))
    Enum.uniq(Destinations.refused_ranges() ++ own)
  end
end
