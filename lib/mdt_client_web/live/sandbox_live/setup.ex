defmodule MDTClientWeb.SandboxLive.Setup do
  @moduledoc """
  The setup page: the few steps from nothing to an agent working in the VM
  (build the image, share folders, start it), each with where it stands,
  and everything needed to open the VM in Zed, filled in for this VM.
  """
  use MDTClientWeb, :html

  import MDTClientWeb.SandboxLive.Components

  @ssh_host MDTClient.Sandbox.Zed.ssh_host()

  @doc "The host name the VM has in your SSH config."
  def ssh_host, do: @ssh_host

  attr :vm, :any, required: true
  attr :image, :map, required: true
  attr :settings, :any, required: true
  attr :tools, :map, required: true

  attr :ssh_entry, :any,
    default: :missing,
    doc: "how ~/.ssh/config reaches the VM (`MDTClient.Sandbox.Msb.ssh_entry/2`)"

  def page(assigns) do
    ~H"""
    <.page_header id="setup-header" title="Setup">
      <:help>
        The VM boots from an image built here, sees only the folders you share, and sends all its traffic through MDT. Do these once; after that the Overview is enough.
      </:help>
    </.page_header>

    <div
      :if={@tools.needs != []}
      id="setup-needs"
      class="mb-4 rounded-lg border border-bad/40 bg-bad-soft/30 px-4 py-3 text-xs leading-5 text-bad"
    >
      <p class="flex items-center gap-1.5 font-medium">
        <.icon name="hero-exclamation-triangle-micro" class="size-3.5" />
        This machine can't run the VM yet
      </p>
      <ul class="mt-1 list-disc space-y-0.5 pl-5">
        <li :for={need <- @tools.needs}>{need}</li>
      </ul>
    </div>

    <ol id="setup-steps" class="mb-6 grid gap-3 md:grid-cols-3">
      <.step
        id="setup-step-image"
        n={1}
        done={@image.loaded?}
        title="Build the image"
        text={
          cond do
            @image.building? -> "Building…"
            @image.loaded? -> @image.tag |> String.split(":") |> List.last()
            true -> "Bash, runtimes and dev CLIs, ready."
          end
        }
      >
        <.button
          :if={not @image.loaded?}
          id="setup-build"
          variant="primary"
          phx-click="build_image"
          disabled={@image.building? or not @tools.podman}
        >
          <.icon
            name={
              if @image.building?, do: "hero-arrow-path-micro", else: "hero-wrench-screwdriver-micro"
            }
            class={["size-3.5", @image.building? && "animate-spin"]}
          />
          {if @image.building?, do: "Building…", else: "Build"}
        </.button>
        <.link
          patch={~p"/tools/sandbox/settings?tab=image"}
          class="text-[11px] text-accent hover:underline"
        >
          {if @image.loaded?, do: "Change the recipe", else: "Customize first"}
        </.link>
        <p :if={not @tools.podman} class="w-full text-[11px] text-bad">podman isn't installed.</p>
      </.step>

      <.step
        id="setup-step-folders"
        n={2}
        done={@settings.shares != []}
        title="Share your folders"
        text={
          case length(@settings.shares) do
            0 -> "Project folders only, one by one."
            1 -> "1 folder shared."
            n -> "#{n} folders shared."
          end
        }
      >
        <.button
          id="setup-folders"
          variant={if(@settings.shares == [], do: "primary", else: "secondary")}
          patch={~p"/tools/sandbox/settings"}
        >
          <.icon name="hero-folder-plus-micro" class="size-3.5" />
          {if @settings.shares == [], do: "Choose folders", else: "Change"}
        </.button>
      </.step>

      <.step
        id="setup-step-vm"
        n={3}
        done={@vm.status == :running}
        title="Start the VM"
        text={
          cond do
            @vm.status == :running -> "Running."
            @vm.exists? -> "Created, stopped."
            true -> "You choose what it keeps first."
          end
        }
      >
        <.button
          :if={@vm.status != :running}
          id="setup-start"
          variant="primary"
          phx-click="start_vm"
          disabled={not @image.loaded? or not is_nil(@vm.busy)}
        >
          <.icon name="hero-play-micro" class="size-3.5" /> {start_label(@vm)}
        </.button>
      </.step>
    </ol>

    <.connect_card
      vm={@vm}
      settings={@settings}
      launcher={@tools.launcher}
      ssh_entry={@ssh_entry}
    />
    """
  end

  defp start_label(%{busy: busy}) when is_binary(busy), do: busy
  defp start_label(%{exists?: true}), do: "Start"
  defp start_label(_vm), do: "Create and start"

  @doc "Whether the steps before connecting an editor are all done."
  @spec done?(map(), map(), map()) :: boolean()
  def done?(vm, image, settings),
    do: image.loaded? and settings.shares != [] and vm.exists?

  attr :id, :string, required: true
  attr :n, :integer, required: true
  attr :done, :boolean, required: true
  attr :title, :string, required: true
  attr :text, :string, required: true
  slot :inner_block

  defp step(assigns) do
    ~H"""
    <li
      id={@id}
      data-done={@done && "true"}
      class={[
        "flex flex-col gap-3 rounded-xl border bg-panel p-4 transition-colors",
        if(@done, do: "border-ok/30", else: "border-line")
      ]}
    >
      <div class="flex items-start gap-3">
        <span class={[
          "flex size-6 shrink-0 items-center justify-center rounded-full text-[11px] font-semibold",
          if(@done, do: "bg-ok-soft text-ok-strong", else: "bg-accent-soft text-accent-strong")
        ]}>
          <.icon :if={@done} name="hero-check-micro" class="size-3.5" />
          <span :if={not @done}>{@n}</span>
        </span>
        <div class="min-w-0 flex-1">
          <p class="text-[13px] font-semibold text-ink">{@title}</p>
          <p class="mt-0.5 truncate text-[11px] text-muted" title={@text}>{@text}</p>
        </div>
      </div>
      <div class="mt-auto flex flex-wrap items-center gap-x-3 gap-y-2">
        {render_slot(@inner_block)}
      </div>
    </li>
    """
  end

  attr :vm, :any, required: true
  attr :settings, :any, required: true
  attr :launcher, :string, required: true
  attr :ssh_entry, :any, required: true

  # Everything needed to open the VM in Zed, filled in for this VM. The
  # launcher runs MDT's own msb with this identity's microsandbox home, and
  # reaches the VM only while MDT runs it.
  defp connect_card(assigns) do
    msb = assigns.launcher

    folders =
      ["/work" | Enum.map(assigns.settings.shares, & &1.path)]

    assigns =
      assign(assigns,
        authorize: "#{msb} ssh authorize --file ~/.ssh/id_ed25519.pub",
        ssh_config:
          """
          Host #{@ssh_host}
            HostName #{@ssh_host}
            User root
            ProxyCommand #{msb} ssh serve #{assigns.vm.name} --stdio --no-inactivity-timeout
            IdentityFile ~/.ssh/id_ed25519
            IdentitiesOnly yes
            ForwardAgent no
            StrictHostKeyChecking no
            UserKnownHostsFile /dev/null
            LogLevel ERROR
          """
          |> String.trim_trailing(),
        open: Enum.map_join(folders, "\n", &"zed ssh://#{@ssh_host}#{&1}"),
        profile:
          Jason.encode!(
            %{
              "profiles" => %{
                "MDT Sandbox" => %{
                  "base" => "default",
                  "settings" => %{
                    "context_servers" => %{},
                    "terminal" => %{
                      "shell" => %{
                        "with_arguments" => %{"program" => "/bin/bash", "args" => ["--login"]}
                      }
                    }
                  }
                }
              }
            },
            pretty: true
          )
      )

    ~H"""
    <.card id="connect-zed" title="Connect from Zed" body_class="">
      <:help>
        Zed's window stays on this machine; its terminals, agents and language servers run in the VM, over SSH.
      </:help>
      <ol class="space-y-5 px-4 py-4">
        <.connect_step
          n={1}
          title="Let your SSH key in, once"
          id="connect-authorize"
          text={@authorize}
        >
          <:help>
            Microsandbox keeps its own list of keys; this adds your public key to MDT's. The command is MDT's own msb, which MDT keeps at this path across updates.
          </:help>
        </.connect_step>
        <li :if={match?({:other, _}, @ssh_entry)} id="connect-ssh-stale">
          <div class="rounded-lg border border-bad/40 bg-bad-soft/30 px-3 py-2.5 text-xs leading-5 text-bad">
            <p class="flex items-center gap-1.5 font-medium">
              <.icon name="hero-exclamation-triangle-micro" class="size-3.5" />
              Your ~/.ssh/config reaches {ssh_host()} another way
            </p>
            <p class="mt-1">
              It runs <code class="font-mono break-all">{elem(@ssh_entry, 1)}</code>, not this VM's launcher. Zed would open a VM MDT doesn't run, which has no internet. Replace that entry with the one in step 2, then reconnect.
            </p>
          </div>
        </li>
        <.connect_step
          n={2}
          title="Add the VM to ~/.ssh/config"
          id="connect-ssh-config"
          text={@ssh_config}
        >
          <:help>
            The connection is a local process, not the network, so host keys aren't checked (they change when the VM is recreated). Your SSH agent is not forwarded. The launcher reaches the VM only while MDT runs it: with MDT stopped or the VM down, connecting fails instead of finding another one.
          </:help>
        </.connect_step>
        <.connect_step
          n={3}
          title="Give Zed a sandbox profile"
          id="connect-profile"
          text={@profile}
        >
          Merge it into your Zed user settings, then pick it with "settings profile selector: toggle".
          <:help>
            It starts terminals in Bash and keeps your host MCP servers out. Zed's own Claude Code and Codex agents install inside the VM, in its Home, so they survive recreating it.
          </:help>
        </.connect_step>
        <.connect_step n={4} title="Open a project" id="connect-open" text={@open}>
          Then sign the agents in from a Zed terminal: <code class="font-mono">claude auth login</code>, <code class="font-mono">codex login --device-auth</code>.
          <:help>
            Agents work in /work, a disk of the VM, and offer their work back as pull requests; a shared folder keeps its path from this machine. A folder shared after the VM was created appears once it is recreated. Logins live in the VM's Home disk and survive recreating it.
          </:help>
        </.connect_step>
      </ol>
    </.card>
    """
  end

  attr :n, :integer, required: true
  attr :title, :string, required: true
  attr :id, :string, required: true
  attr :text, :string, required: true
  slot :help
  slot :inner_block

  defp connect_step(assigns) do
    ~H"""
    <li class="flex gap-3">
      <span class="flex size-5 shrink-0 items-center justify-center rounded-full bg-accent-soft text-[10px] font-semibold text-accent-strong">
        {@n}
      </span>
      <div class="min-w-0 flex-1">
        <p class="flex items-center gap-1.5 text-xs font-semibold text-ink">
          {@title}
          <.help :if={@help != []} id={"#{@id}-help"} label={"About: #{@title}"}>
            {render_slot(@help)}
          </.help>
        </p>
        <p :if={@inner_block != []} class="mt-0.5 text-[11px] leading-4 text-muted">
          {render_slot(@inner_block)}
        </p>
        <div class="mt-2 overflow-hidden rounded-lg border border-line-soft bg-deep">
          <div class="flex justify-end border-b border-line-soft px-2 py-1">
            <button
              id={"#{@id}-copy"}
              type="button"
              phx-hook="CopyText"
              phx-update="ignore"
              data-copy-target={@id}
              class="cursor-pointer rounded px-2 py-0.5 text-[10px] text-accent transition-colors hover:bg-accent-soft"
            >Copy</button>
          </div>
          <pre id={@id} class="overflow-x-auto px-3 py-2 font-mono text-[11px] leading-5 text-ink">{@text}</pre>
        </div>
      </div>
    </li>
    """
  end
end
