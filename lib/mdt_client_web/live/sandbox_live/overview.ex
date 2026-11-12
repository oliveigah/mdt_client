defmodule MDTClientWeb.SandboxLive.Overview do
  @moduledoc """
  The overview: the VM and its controls, what waits for you, what is shared
  right now, and the latest activity, on one screen.
  """
  use MDTClientWeb, :html

  import MDTClientWeb.SandboxLive.Components

  alias MDTClient.Sandbox.{Grant, Recipes}
  alias MDTClientWeb.SandboxLive.Approvals

  attr :vm, :any, required: true
  attr :image, :map, required: true
  attr :proxy, :map, required: true
  attr :tools, :map, required: true
  attr :settings, :any, required: true
  attr :grants, :list, required: true
  attr :grant_map, :map, required: true
  attr :waiting, :list, required: true
  attr :requests, :list, required: true
  attr :recent, :list, required: true
  attr :stats, :map, required: true
  attr :now, DateTime, required: true

  def page(assigns) do
    on = Enum.filter(assigns.grants, &Grant.on?/1)
    assigns = assign(assigns, on: on)

    ~H"""
    <section
      id="vm-card"
      class="relative mb-5 overflow-hidden rounded-xl border border-line bg-panel"
    >
      <div class={[
        "pointer-events-none absolute inset-0 opacity-60",
        @vm.status == :running &&
          "bg-[radial-gradient(ellipse_at_top_left,var(--color-ok-soft),transparent_55%)]"
      ]}>
      </div>
      <div class="relative flex flex-wrap items-center gap-5 px-5 py-4">
        <span class={[
          "flex size-12 shrink-0 items-center justify-center rounded-xl border transition-colors",
          if(@vm.status == :running,
            do: "border-ok/35 bg-ok-soft/60 text-ok-strong",
            else: "border-line bg-deep text-muted"
          )
        ]}>
          <.icon name="hero-cube-transparent" class="size-6" />
        </span>
        <div class="min-w-0 flex-1">
          <div class="flex flex-wrap items-center gap-3">
            <h1 class="text-lg font-semibold tracking-tight text-ink">{@vm.name}</h1>
            <.vm_status vm={@vm} id="vm-status" />
            <span :if={@vm.status == :running and @vm.started_at} class="text-xs text-muted">
              for <.clock id="vm-uptime" since={@vm.started_at} duration now={@now} />
            </span>
          </div>
          <p class="mt-1 font-mono text-[11px] text-muted">
            {@image.tag} · {@settings.cpus} CPUs · {@settings.memory_gib} GiB · {length(
              @settings.shares
            )} shared folders
          </p>
        </div>
        <div class="flex items-center gap-2">
          <.button
            :if={@vm.exists? and not @vm.stale? and is_nil(@vm.busy) and @image.loaded?}
            id="vm-recreate-any"
            phx-click="recreate_vm"
            title="Start over from the image, choosing what happens to Home and Cache"
          >
            <.icon name="hero-arrow-path-micro" class="size-3.5" /> Recreate…
          </.button>
          <%= cond do %>
            <% @vm.busy -> %>
              <.button id="vm-busy" disabled>
                <.icon name="hero-arrow-path-micro" class="size-3.5 animate-spin" /> {@vm.busy}
              </.button>
            <% not @image.loaded? -> %>
              <.button id="vm-build" variant="primary" patch={~p"/tools/sandbox/settings"}>
                <.icon name="hero-wrench-screwdriver-micro" class="size-3.5" />
                {if @image.building?, do: "Image building…", else: "Build the image"}
              </.button>
            <% @vm.status == :running -> %>
              <.button id="vm-stop" phx-click="stop_vm">
                <.icon name="hero-stop-micro" class="size-3.5" /> Stop
              </.button>
            <% @vm.exists? -> %>
              <.button id="vm-start" variant="primary" phx-click="start_vm">
                <.icon name="hero-play-micro" class="size-3.5" /> Start
              </.button>
            <% true -> %>
              <.button id="vm-start" variant="primary" phx-click="start_vm">
                <.icon name="hero-play-micro" class="size-3.5" /> Create and start
              </.button>
          <% end %>
        </div>
      </div>
      <div
        :if={@vm.error}
        id="vm-error"
        class="relative flex gap-2.5 border-t border-bad/30 bg-bad-soft/20 px-5 py-2.5"
      >
        <.icon name="hero-exclamation-circle" class="mt-px size-4 shrink-0 text-bad" />
        <pre
          class="min-w-0 flex-1 whitespace-pre-wrap break-words font-mono text-[11px] leading-4 text-ink"
          phx-no-curly-interpolation
        ><%= @vm.error %></pre>
      </div>
      <div
        :if={not @proxy.listening?}
        id="proxy-down"
        class="relative flex gap-2.5 border-t border-bad/30 bg-bad-soft/20 px-5 py-2.5"
      >
        <.icon name="hero-signal-slash" class="mt-px size-4 shrink-0 text-bad" />
        <p class="text-xs text-ink">
          {@proxy.error || "The proxy isn't listening."} The VM has no internet until it is.
        </p>
      </div>
      <div
        :if={not @image.loaded? and not @vm.exists?}
        id="vm-first-run"
        class="relative border-t border-line-soft px-5 py-3 text-xs leading-5 text-muted"
      >
        First, build the image in Settings: your Containerfile plus MDT's layer, with podman.
        Then create the VM. It boots with its traffic pinned to MDT's proxy, your picked folders at their own paths, its own Home, Cache and memory, and nothing else of yours.
        <span :if={not @tools.podman} class="text-bad">podman isn't installed.</span>
        <span :if={is_nil(@tools.msb)} class="text-bad">msb isn't installed.</span>
      </div>
      <div
        :if={@vm.stale?}
        id="vm-stale"
        class="relative flex flex-wrap items-center gap-3 border-t border-warn/30 bg-warn-soft/30 px-5 py-2.5"
      >
        <.icon name="hero-arrow-path" class="size-4 text-warn" />
        <p class="flex-1 text-xs text-ink">
          Settings or the image changed since the VM was created. It keeps the old ones until it is recreated. Recreating asks what happens to its Home (logins, history) and Cache; its memory and your folders stay.
        </p>
        <.button
          id="vm-recreate"
          phx-click="recreate_vm"
          disabled={not is_nil(@vm.busy) or not @image.loaded?}
        >
          Recreate now
        </.button>
      </div>
    </section>

    <div class="mb-6 grid gap-3 sm:grid-cols-3">
      <.link
        patch={~p"/tools/sandbox/approvals"}
        id="stat-waiting"
        class={[
          "group rounded-xl border bg-panel px-4 py-3.5 transition-all hover:-translate-y-0.5 hover:shadow-lg hover:shadow-black/10",
          if(@stats.waiting > 0, do: "border-warn/40", else: "border-line hover:border-accent/50")
        ]}
      >
        <p class="text-[11px] font-medium text-muted">Waiting for you</p>
        <p class={[
          "mt-1 text-2xl font-semibold tabular-nums",
          if(@stats.waiting > 0, do: "text-warn-strong", else: "text-ink")
        ]}>
          {@stats.waiting}
        </p>
        <p class="mt-0.5 text-[11px] text-faint">
          {length(@waiting)} held · {length(@requests)} asking
        </p>
      </.link>
      <.link
        patch={~p"/tools/sandbox/grants"}
        id="stat-grants"
        class="group rounded-xl border border-line bg-panel px-4 py-3.5 transition-all hover:-translate-y-0.5 hover:border-accent/50 hover:shadow-lg hover:shadow-black/10"
      >
        <p class="text-[11px] font-medium text-muted">Grants on</p>
        <p class="mt-1 text-2xl font-semibold tabular-nums text-ink">
          {length(@on)}<span class="text-sm font-normal text-faint"> / {length(@grants)}</span>
        </p>
        <p class="mt-0.5 text-[11px] text-faint">
          {Enum.count(@grants, &Grant.exposes_value?/1)} would hand over a value
        </p>
      </.link>
      <.link
        patch={~p"/tools/sandbox/activity"}
        id="stat-activity"
        class="group rounded-xl border border-line bg-panel px-4 py-3.5 transition-all hover:-translate-y-0.5 hover:border-accent/50 hover:shadow-lg hover:shadow-black/10"
      >
        <p class="text-[11px] font-medium text-muted">Last hour</p>
        <p class="mt-1 text-2xl font-semibold tabular-nums text-ink">
          {@stats.connections}<span class="text-sm font-normal text-faint"> connections</span>
        </p>
        <p class="mt-0.5 text-[11px] text-faint">
          {@stats.credentials} used a credential ·
          <span class={@stats.blocked > 0 && "text-bad"}>{@stats.blocked} blocked</span>
        </p>
      </.link>
    </div>

    <div class="grid gap-5 lg:grid-cols-[minmax(0,1.4fr)_minmax(0,1fr)]">
      <section id="overview-waiting" class="space-y-3">
        <div class="flex items-center gap-2">
          <h2 class="text-[11px] font-semibold uppercase tracking-wide text-muted">
            Waiting for you
          </h2>
          <div class="flex-1"></div>
          <.link
            :if={@waiting != [] or @requests != []}
            patch={~p"/tools/sandbox/approvals"}
            class="text-[11px] text-accent hover:underline"
          >
            See details
          </.link>
        </div>
        <div
          :if={@waiting == [] and @requests == []}
          class="rounded-xl border border-dashed border-line"
        >
          <.empty icon="hero-check-badge" id="overview-nothing-waiting">
            Nothing waits for you. Held requests and agents asking for access show up here, and in the title bar of every tool.
          </.empty>
        </div>
        <Approvals.approval_card
          :for={approval <- Enum.take(@waiting, 3)}
          approval={approval}
          grant={@grant_map[approval.grant_id]}
          hold_seconds={@settings.hold_seconds}
          now={@now}
          compact
        />
        <Approvals.request_card
          :for={request <- Enum.take(@requests, 2)}
          request={request}
          grant={request.grant_id && @grant_map[request.grant_id]}
          now={@now}
        />
      </section>

      <div class="space-y-5">
        <.card id="overview-grants" title="Shared right now" body_class="">
          <:actions>
            <.link patch={~p"/tools/sandbox/grants"} class="text-[11px] text-accent hover:underline">
              All grants
            </.link>
          </:actions>
          <div :if={@on == []}>
            <.empty icon="hero-lock-closed">
              The VM has no credentials or network access beyond the public internet.
            </.empty>
          </div>
          <ul class="divide-y divide-line-soft">
            <li
              :for={grant <- @on}
              id={"overview-grant-#{grant.id}"}
              class="flex items-center gap-3 px-4 py-2.5"
            >
              <.grant_tile recipe={Recipes.fetch!(grant.recipe)} on class="size-7" />
              <.link
                patch={~p"/tools/sandbox/grants/#{grant.id}"}
                class="min-w-0 flex-1 truncate text-xs font-medium text-ink hover:text-accent"
              >
                {grant.name}
              </.link>
              <span class="font-mono text-[11px] text-ok-strong">
                <%= if grant.expires_at do %>
                  <.clock
                    id={"overview-left-#{grant.id}"}
                    deadline={grant.expires_at}
                    done="ending…"
                    now={@now}
                  />
                <% else %>
                  until off
                <% end %>
              </span>
              <.switch
                id={"overview-switch-#{grant.id}"}
                on
                label={"Turn #{grant.name} off"}
                phx-click="turn_off"
                phx-value-id={grant.id}
              />
            </li>
          </ul>
        </.card>

        <.card id="overview-activity" title="Latest activity" body_class="">
          <:actions>
            <.link patch={~p"/tools/sandbox/activity"} class="text-[11px] text-accent hover:underline">
              All activity
            </.link>
          </:actions>
          <ul class="divide-y divide-line-soft">
            <li
              :for={event <- @recent}
              id={"recent-#{event.id}"}
              class="flex items-center gap-2.5 px-4 py-2"
            >
              <.outcome_badge outcome={event.outcome} />
              <p class="min-w-0 flex-1 truncate text-[11px] text-ink" title={event.summary}>
                {event.host || event.summary}
                <span :if={event.host} class="text-faint">· {event.summary}</span>
              </p>
              <span class="shrink-0 text-[10px] text-faint">
                <.clock id={"recent-at-#{event.id}"} since={event.at} now={@now} />
              </span>
            </li>
          </ul>
        </.card>
      </div>
    </div>

    <.connect_card
      vm={@vm}
      settings={@settings}
      msb={@tools.msb}
    />
    """
  end

  @ssh_host "mdt-sandbox"

  attr :vm, :any, required: true
  attr :settings, :any, required: true
  attr :msb, :string, default: nil

  # Everything needed to open the VM in Zed, filled in for this VM.
  defp connect_card(assigns) do
    msb = assigns.msb || "~/.microsandbox/bin/msb"

    folders =
      case assigns.settings.shares do
        [] -> ["/root"]
        shares -> Enum.map(shares, & &1.path)
      end

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
                  "settings" => %{"context_servers" => %{}}
                }
              }
            },
            pretty: true
          )
      )

    ~H"""
    <details id="connect-zed" class="group mt-5 rounded-xl border border-line bg-panel">
      <summary class="flex cursor-pointer list-none items-center gap-3 px-4 py-3 [&::-webkit-details-marker]:hidden">
        <.icon name="hero-command-line" class="size-4 text-accent" />
        <span class="flex-1">
          <span class="block text-[13px] font-semibold text-ink">Connect from Zed</span>
          <span class="block text-[11px] text-muted">
            Zed's UI stays here; its terminals, agents and language servers run in the VM, over SSH.
          </span>
        </span>
        <.icon
          name="hero-chevron-down-micro"
          class="size-4 text-muted transition-transform group-open:rotate-180"
        />
      </summary>
      <ol class="space-y-4 border-t border-line-soft px-4 py-4">
        <.connect_step
          n={1}
          title="Let your SSH key in, once"
          id="connect-authorize"
          text={@authorize}
        >
          Microsandbox keeps its own list of keys; this adds your public key to it.
        </.connect_step>
        <.connect_step
          n={2}
          title="Add the VM to ~/.ssh/config"
          id="connect-ssh-config"
          text={@ssh_config}
        >
          The connection is a local process, not the network, so host keys aren't checked (they change when the VM is recreated). Your SSH agent is not forwarded. Connecting boots the VM if it's stopped; without MDT running it has no internet.
        </.connect_step>
        <.connect_step
          n={3}
          title="Give Zed a profile that keeps your MCP servers out"
          id="connect-profile"
          text={@profile}
        >
          Merge it into your Zed user settings, then pick it with "settings profile selector: toggle". Then use Zed's own Claude Code and Codex agents: on a remote project they install inside the VM, in its Home, so they survive recreating it.
        </.connect_step>
        <.connect_step n={4} title="Open a shared folder" id="connect-open" text={@open}>
          Shared folders keep their paths from this machine; in the VM, ~ is /root, so they are not under ~/projects there. A folder shared after the VM was created appears once it is recreated. Then sign the agents in from a Zed terminal (claude auth login, codex login --device-auth). Logins live in the VM's Home and survive recreating it.
        </.connect_step>
      </ol>
    </details>
    """
  end

  attr :n, :integer, required: true
  attr :title, :string, required: true
  attr :id, :string, required: true
  attr :text, :string, required: true
  slot :inner_block, required: true

  defp connect_step(assigns) do
    ~H"""
    <li class="flex gap-3">
      <span class="flex size-5 shrink-0 items-center justify-center rounded-full bg-accent-soft text-[10px] font-semibold text-accent-strong">
        {@n}
      </span>
      <div class="min-w-0 flex-1">
        <p class="text-xs font-semibold text-ink">{@title}</p>
        <p class="mt-0.5 text-[11px] leading-4 text-muted">{render_slot(@inner_block)}</p>
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
