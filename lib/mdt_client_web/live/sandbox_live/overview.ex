defmodule MDTClientWeb.SandboxLive.Overview do
  @moduledoc """
  The overview: the VM and its controls, what waits for you, what is shared
  right now, the VM's memory and the latest activity, on one screen.
  """
  use MDTClientWeb, :html

  import MDTClientWeb.SandboxLive.Components

  alias MDTClient.Sandbox.{Grant, Presets}
  alias MDTClientWeb.SandboxLive.Approvals

  attr :vm, :any, required: true
  attr :image, :map, required: true
  attr :created_ref, :string, default: nil
  attr :proxy, :map, required: true
  attr :tools, :map, required: true
  attr :settings, :any, required: true
  attr :memory, :map, required: true
  attr :grants, :list, required: true
  attr :grant_map, :map, required: true
  attr :waiting, :list, required: true
  attr :running, :list, default: []
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
          <p id="vm-image" class="mt-1 font-mono text-[11px] text-muted">
            {if @vm.exists?, do: @created_ref || "unknown image", else: @image.tag} · {@settings.cpus} CPUs · {@settings.memory_gib} GiB · {@settings.disk_gib} GiB disk · {length(
              @settings.shares
            )} shared folders
          </p>
          <p
            :if={@vm.exists? and @created_ref != @image.tag}
            id="vm-next-image"
            class="mt-1 text-[11px] text-muted"
          >
            Next image: <span class="font-mono">{@image.tag}</span>. Recreate to use it.
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
              <.button id="vm-build" variant="primary" patch={~p"/tools/sandbox/setup"}>
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
        class="relative flex flex-wrap items-center gap-x-3 gap-y-1 border-t border-line-soft px-5 py-3 text-xs leading-5 text-muted"
      >
        <.icon name="hero-sparkles-micro" class="size-4 text-accent" />
        <span>New sandbox: build its image, share your folders, then start it.</span>
        <.link patch={~p"/tools/sandbox/setup"} class="font-medium text-accent hover:underline">
          Open Setup
        </.link>
        <span :if={not @tools.podman} class="text-bad">podman isn't installed.</span>
        <span :for={need <- @tools.needs} class="text-bad">{need}</span>
        <span :if={is_nil(@tools.msb)} class="text-bad">
          This MDT has no microsandbox runtime; in a source checkout, run scripts/build-microsandbox.sh.
        </span>
      </div>
      <div
        :if={@vm.stale?}
        id="vm-stale"
        class="relative flex flex-wrap items-center gap-3 border-t border-warn/30 bg-warn-soft/30 px-5 py-2.5"
      >
        <.icon name="hero-arrow-path" class="size-4 text-warn" />
        <p class="flex flex-1 items-center gap-1.5 text-xs text-ink">
          Settings or the image changed. Recreate the VM to use them.
          <.help id="vm-stale-help" label="About recreating">
            The VM keeps what it was created with until it is recreated. Recreating asks what happens to its Home (logins, history) and Cache; its memory and your folders stay.
          </.help>
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
          {waiting_words(@waiting)}
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
            :if={@waiting != []}
            patch={~p"/tools/sandbox/approvals"}
            class="text-[11px] text-accent hover:underline"
          >
            See details
          </.link>
        </div>
        <div :if={@waiting == []} class="rounded-xl border border-dashed border-line">
          <.empty icon="hero-check-badge" id="overview-nothing-waiting">
            Nothing waits for you. Agents' asks show up here and in the title bar of every tool.
          </.empty>
        </div>
        <Approvals.running :if={@running != []} running={@running} now={@now} />
        <Approvals.approval
          :for={approval <- Enum.take(@waiting, 3)}
          approval={approval}
          grant={approval.grant_id && @grant_map[approval.grant_id]}
          hold_seconds={@settings.hold_seconds}
          now={@now}
          compact
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
              Nothing beyond the public internet.
            </.empty>
          </div>
          <ul class="divide-y divide-line-soft">
            <li
              :for={grant <- @on}
              id={"overview-grant-#{grant.id}"}
              class="flex items-center gap-3 px-4 py-2.5"
            >
              <.grant_tile icon={Presets.icon(grant)} on class="size-7" />
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

        <.memory_card memory={@memory} vm={@vm} />

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
    """
  end

  attr :memory, :map, required: true
  attr :vm, :any, required: true

  # The VM's OptMem and the round trip with yours: the same two buttons as
  # in Settings, for the end of a session.
  defp memory_card(assigns) do
    ~H"""
    <.card id="overview-memory" title="Memory">
      <:help>
        The VM keeps its own OptMem. It can start from a copy of yours, and what it notes joins yours only when you tick it in the review.
      </:help>
      <:actions>
        <.link
          patch={~p"/tools/sandbox/settings?tab=storage"}
          class="text-[11px] text-accent hover:underline"
        >
          Settings
        </.link>
      </:actions>
      <%= if @memory.host? do %>
        <p id="overview-memory-state" class="text-xs leading-5 text-muted">
          <%= if @memory.seeded_at do %>
            Started from {@memory.seed_count} of your memories on {Calendar.strftime(
              @memory.seeded_at,
              "%b %-d"
            )}.
          <% else %>
            Its own, never copied from yours.
          <% end %>
        </p>
        <div class="mt-3 flex flex-wrap gap-2">
          <.button id="overview-memory-review" variant="primary" phx-click="review_memories">
            <.icon name="hero-inbox-arrow-down-micro" class="size-3.5" /> Review what it noted
          </.button>
          <.button
            id="overview-memory-seed"
            phx-click="seed_memory"
            disabled={@vm.status in [:running, :starting] or not is_nil(@vm.busy)}
            title={
              if(@vm.status in [:running, :starting],
                do: "Stop the VM first",
                else: "Replace the VM's memory with a copy of yours"
              )
            }
          >
            <.icon name="hero-document-duplicate-micro" class="size-3.5" /> Copy mine in
          </.button>
        </div>
      <% else %>
        <p id="overview-memory-state" class="text-xs leading-5 text-muted">
          OptMem isn't installed on this machine.
        </p>
      <% end %>
    </.card>
    """
  end

  defp waiting_words(waiting) do
    asks = Enum.count(waiting, &(&1.kind == :activation))
    commands = Enum.count(waiting, &(&1.kind == :command))
    uses = length(waiting) - asks - commands

    "#{uses} #{if uses == 1, do: "use", else: "uses"} · #{asks} #{if asks == 1, do: "agent", else: "agents"} asking" <>
      if(commands > 0,
        do: " · #{commands} #{if commands == 1, do: "command", else: "commands"}",
        else: ""
      )
  end
end
