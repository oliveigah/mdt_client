defmodule MDTClientWeb.SandboxLive.Grants do
  @moduledoc """
  The grants page: every piece of access the VM can be given, each with a
  switch; one grant's details, how its uses are approved, and its
  allowances; and the dialog that adds a grant, of a type or from a preset.
  """
  use MDTClientWeb, :html

  import MDTClientWeb.SandboxLive.Components

  alias MDTClient.Sandbox.{Grant, Presets}

  @durations [{15, "15 min"}, {60, "1 h"}, {240, "4 h"}, {"until_off", "Until off"}]

  @doc "The durations a grant can be turned on for."
  def durations, do: @durations

  attr :grants, :list, required: true
  attr :durations, :map, required: true, doc: "the duration picked for each grant id"
  attr :now, DateTime, required: true

  def page(assigns) do
    {on, off} = Enum.split_with(assigns.grants, &Grant.on?/1)
    assigns = assign(assigns, on: on, off: off)

    ~H"""
    <.page_header
      title="Grants"
      subtitle="Turn access on for as long as a task needs; agents in the VM can ask for it with mdt request. Tokens never enter the VM: it gets a placeholder, and MDT swaps the real value in on the way out, once you approve the use."
    >
      <:actions>
        <.button id="add-grant" variant="primary" phx-click="open_add_grant">
          <.icon name="hero-plus-micro" class="size-3.5" /> Add grant
        </.button>
      </:actions>
    </.page_header>

    <div class="space-y-5">
      <.card
        id="grants-on"
        title="On now"
        subtitle={if(@on == [], do: "Nothing is shared with the VM right now.", else: nil)}
        body_class=""
      >
        <ul class="divide-y divide-line-soft">
          <.grant_row
            :for={grant <- @on}
            grant={grant}
            duration={@durations[grant.id]}
            now={@now}
          />
        </ul>
      </.card>

      <.card id="grants-off" title="Off" body_class="">
        <div :if={@off == []}>
          <.empty icon="hero-key">Every grant is on.</.empty>
        </div>
        <ul class="divide-y divide-line-soft">
          <.grant_row
            :for={grant <- @off}
            grant={grant}
            duration={@durations[grant.id]}
            now={@now}
          />
        </ul>
      </.card>
    </div>
    """
  end

  attr :grant, Grant, required: true
  attr :duration, :any, required: true
  attr :now, DateTime, required: true

  defp grant_row(assigns) do
    ~H"""
    <li
      id={"grant-row-#{@grant.id}"}
      class="group/row flex items-center gap-3 px-4 py-3 transition-colors hover:bg-hover/40"
    >
      <.grant_tile icon={Presets.icon(@grant)} on={Grant.on?(@grant)} />
      <div class="min-w-0 flex-1">
        <div class="flex flex-wrap items-center gap-2">
          <.link
            patch={~p"/tools/sandbox/grants/#{@grant.id}"}
            id={"grant-link-#{@grant.id}"}
            class="truncate text-[13px] font-semibold text-ink transition-colors hover:text-accent"
          >
            {@grant.name}
          </.link>
          <.exposure grant={@grant} />
          <span
            :if={Enum.any?(@grant.allowances, &(&1.pattern == :all))}
            class="rounded border border-ok/30 bg-ok-soft/30 px-1.5 py-0.5 text-[10px] font-medium text-ok-strong"
          >
            Every use allowed
          </span>
        </div>
        <p :if={@grant.purpose != ""} class="mt-0.5 truncate text-[11px] text-muted">
          {@grant.purpose}
        </p>
        <p class="mt-0.5 truncate font-mono text-[10px] text-faint">{summary(@grant)}</p>
      </div>

      <div class="hidden shrink-0 text-right text-[11px] text-faint sm:block">
        <p :if={@grant.last_used_at}>
          Used <.clock id={"used-#{@grant.id}"} since={@grant.last_used_at} now={@now} />
        </p>
        <p :if={is_nil(@grant.last_used_at)}>Never used</p>
        <p :if={@grant.uses > 0} class="font-mono text-[10px]">{@grant.uses} uses</p>
      </div>

      <div class="flex shrink-0 items-center gap-3">
        <%= if Grant.on?(@grant) do %>
          <span
            id={"grant-left-#{@grant.id}"}
            class="rounded-md bg-ok-soft/40 px-2 py-1 font-mono text-[11px] font-semibold text-ok-strong"
          >
            <%= if @grant.expires_at do %>
              <.clock
                id={"grant-clock-#{@grant.id}"}
                deadline={@grant.expires_at}
                suffix=" left"
                done="ending…"
                now={@now}
              />
            <% else %>
              until off
            <% end %>
          </span>
        <% else %>
          <.segmented
            id={"grant-duration-#{@grant.id}"}
            options={durations()}
            value={@duration}
            event="pick_duration"
            name="minutes"
            values={%{"id" => @grant.id}}
          />
        <% end %>
        <.switch
          id={"grant-switch-#{@grant.id}"}
          on={Grant.on?(@grant)}
          label={if(Grant.on?(@grant), do: "Turn #{@grant.name} off", else: "Turn #{@grant.name} on")}
          phx-click={if(Grant.on?(@grant), do: "turn_off", else: "turn_on")}
          phx-value-id={@grant.id}
        />
      </div>
    </li>
    """
  end

  @doc "A one-line description of what a grant reaches."
  def summary(%Grant{kind: :token} = grant) do
    hosts =
      case grant.hosts do
        [first, second | [_ | _] = rest] -> "#{first}, #{second} +#{length(rest)}"
        hosts -> Enum.join(hosts, ", ")
      end

    case grant.env do
      [] -> "→ #{hosts}"
      env -> "#{Enum.join(env, ", ")} → #{hosts}"
    end
  end

  def summary(%Grant{kind: :network, destinations: destinations}),
    do: Enum.join(destinations, "  ·  ")

  def summary(%Grant{kind: :file, path: path}), do: path

  ## One grant

  attr :grant, Grant, required: true
  attr :has_value, :boolean, required: true
  attr :value_form, :any, required: true
  attr :events, :list, required: true
  attr :duration, :any, required: true
  attr :now, DateTime, required: true

  def detail(assigns) do
    ~H"""
    <.link
      patch={~p"/tools/sandbox/grants"}
      id="grant-back"
      class="mb-4 inline-flex items-center gap-1.5 text-xs text-muted transition-colors hover:text-accent"
    >
      <.icon name="hero-arrow-left-micro" class="size-3.5" /> All grants
    </.link>

    <header id={"grant-detail-#{@grant.id}"} class="mb-5 flex flex-wrap items-center gap-3">
      <.grant_tile icon={Presets.icon(@grant)} on={Grant.on?(@grant)} class="size-11" />
      <div class="min-w-0 flex-1">
        <div class="flex flex-wrap items-center gap-2">
          <h1 class="text-lg font-semibold tracking-tight text-ink">{@grant.name}</h1>
          <.exposure grant={@grant} />
          <span class="font-mono text-[10px] text-faint">id {@grant.id}</span>
        </div>
        <p class="mt-0.5 text-[13px] text-muted">
          {Presets.kind_name(@grant.kind)} · <span class="text-ink">{@grant.purpose}</span>
        </p>
      </div>
      <div class="flex items-center gap-3">
        <%= if Grant.on?(@grant) do %>
          <span class="rounded-md bg-ok-soft/40 px-2 py-1 font-mono text-xs font-semibold text-ok-strong">
            <%= if @grant.expires_at do %>
              <.clock
                id={"detail-clock-#{@grant.id}"}
                deadline={@grant.expires_at}
                suffix=" left"
                done="ending…"
                now={@now}
              />
            <% else %>
              On until turned off
            <% end %>
          </span>
        <% else %>
          <.segmented
            id={"detail-duration-#{@grant.id}"}
            options={durations()}
            value={@duration}
            event="pick_duration"
            name="minutes"
            values={%{"id" => @grant.id}}
          />
        <% end %>
        <.switch
          id={"detail-switch-#{@grant.id}"}
          on={Grant.on?(@grant)}
          label={if(Grant.on?(@grant), do: "Turn #{@grant.name} off", else: "Turn #{@grant.name} on")}
          phx-click={if(Grant.on?(@grant), do: "turn_off", else: "turn_on")}
          phx-value-id={@grant.id}
        />
      </div>
    </header>

    <div class="grid gap-5 lg:grid-cols-[minmax(0,1.35fr)_minmax(0,1fr)]">
      <div class="space-y-5">
        <.card id="grant-delivery" title="What the VM gets">
          <.delivery grant={@grant} />
        </.card>

        <.card
          :if={@grant.kind in [:token, :file] and @grant.source == :stored}
          id="grant-value-card"
          title="The real value"
          subtitle="Kept in your vault, encrypted with your password. MDT never shows it again."
        >
          <div
            :if={not @has_value}
            id="grant-no-value"
            class="mb-3 flex gap-2 rounded-lg border border-warn/35 bg-warn-soft/30 p-2.5 text-xs text-ink"
          >
            <.icon name="hero-exclamation-triangle-micro" class="mt-px size-3.5 shrink-0 text-warn" />
            No value yet: requests carrying the placeholder are refused with mdt_no_value.
          </div>
          <.form for={@value_form} id="grant-value-form" phx-submit="set_value" class="flex gap-2">
            <%= if @grant.kind == :file do %>
              <textarea
                name={@value_form[:value].name}
                id="grant-new-value"
                rows="3"
                spellcheck="false"
                autocomplete="off"
                placeholder="Paste the new content"
                class={[input_classes(), "font-mono text-xs"]}
              ></textarea>
            <% else %>
              <input
                type="password"
                name={@value_form[:value].name}
                id="grant-new-value"
                autocomplete="new-password"
                placeholder={
                  if(@has_value, do: "Paste a new value to replace it", else: "Paste the value")
                }
                class={input_classes()}
              />
            <% end %>
            <.button type="submit" id="grant-value-save" class="shrink-0 self-start">
              {if @has_value, do: "Replace", else: "Save"}
            </.button>
          </.form>
        </.card>

        <.card
          :if={@grant.kind != :file}
          id="grant-uses"
          title="Uses"
          subtitle={
            if(@grant.kind == :network,
              do:
                "Every connection to these destinations waits for your approval, unless an allowance covers it.",
              else:
                "Every request carrying the placeholder waits for your approval, unless an allowance covers it."
            )
          }
        >
          <div class="flex flex-wrap items-center gap-3">
            <p class="flex-1 text-xs text-muted">
              <%= if Grant.on?(@grant) do %>
                Let every use through without asking
              <% else %>
                Turn it on first to let every use through
              <% end %>
            </p>
            <div class="inline-flex items-center gap-0.5 rounded-md border border-line bg-deep p-0.5">
              <button
                :for={{value, label} <- [{"10", "10 min"}, {"60", "1 h"}, {"grant", "While on"}]}
                type="button"
                id={"allow-all-#{@grant.id}-#{value}"}
                phx-click="allow_all"
                phx-value-id={@grant.id}
                phx-value-minutes={value}
                disabled={not Grant.on?(@grant)}
                class="cursor-pointer rounded px-2 py-1 text-[11px] font-medium text-muted transition-colors hover:bg-ok-soft/50 hover:text-ok-strong disabled:cursor-not-allowed disabled:opacity-40 disabled:hover:bg-transparent disabled:hover:text-muted"
              >
                {label}
              </button>
            </div>
          </div>
          <p class="mt-3 text-[11px] leading-4 text-faint">
            On an approval you can also allow uses like that one for a while. Allowances end with their time, or when the grant turns off.
          </p>
        </.card>
      </div>

      <div class="space-y-5">
        <.card
          :if={@grant.kind != :file}
          id="grant-allowances"
          title="Allowed for now"
          subtitle="Uses these cover go through without asking. They end with their time, or when the grant turns off."
          body_class=""
        >
          <div :if={@grant.allowances == []}>
            <.empty icon="hero-clock">None right now.</.empty>
          </div>
          <ul class="divide-y divide-line-soft">
            <li
              :for={allowance <- @grant.allowances}
              id={"allowance-#{allowance.id}"}
              class="flex items-center gap-3 px-4 py-2.5"
            >
              <div class="min-w-0 flex-1">
                <p :if={allowance.pattern == :all} class="text-[11px] font-medium text-ok-strong">
                  Every use
                </p>
                <p :if={allowance.pattern != :all} class="break-all font-mono text-[11px] text-ink">
                  {allowance.pattern}
                </p>
                <p class="mt-0.5 text-[10px] text-faint">
                  <%= if allowance.until do %>
                    <.clock
                      id={"allowance-left-#{allowance.id}"}
                      deadline={allowance.until}
                      suffix=" left"
                      now={@now}
                    />
                  <% else %>
                    While the grant stays on
                  <% end %>
                </p>
              </div>
              <button
                type="button"
                id={"revoke-allowance-#{allowance.id}"}
                phx-click="revoke_allowance"
                phx-value-id={@grant.id}
                phx-value-allowance={allowance.id}
                class="cursor-pointer rounded px-2 py-1 text-[11px] text-muted transition-colors hover:bg-bad-soft/40 hover:text-bad"
              >
                End now
              </button>
            </li>
          </ul>
        </.card>

        <.card id="grant-activity" title="Recent use" body_class="">
          <div :if={@events == []}>
            <.empty icon="hero-queue-list">Nothing has used this grant yet.</.empty>
          </div>
          <ul class="divide-y divide-line-soft">
            <li
              :for={event <- @events}
              id={"grant-event-#{event.id}"}
              class="flex items-start gap-2.5 px-4 py-2"
            >
              <.outcome_badge outcome={event.outcome} />
              <p class="min-w-0 flex-1 text-[11px] leading-4 text-ink">{event.summary}</p>
              <span class="shrink-0 text-[10px] text-faint">
                <.clock id={"grant-event-at-#{event.id}"} since={event.at} now={@now} />
              </span>
            </li>
          </ul>
        </.card>

        <section
          id="grant-danger"
          class="flex items-center gap-3 rounded-xl border border-bad/25 px-4 py-3"
        >
          <p class="flex-1 text-[11px] leading-4 text-muted">
            Removing it refuses anything waiting on it. The VM keeps the placeholder, which is worthless on its own.
          </p>
          <.button
            id="delete-grant"
            variant="danger"
            phx-click="confirm_delete_grant"
            phx-value-id={@grant.id}
          >
            Remove
          </.button>
        </section>
      </div>
    </div>
    """
  end

  attr :grant, Grant, required: true

  defp delivery(%{grant: %Grant{kind: :token}} = assigns) do
    ~H"""
    <div class="space-y-4">
      <p class="text-xs leading-5 text-muted">
        The VM sees a placeholder. When a request carrying it goes to one of the hosts below, MDT asks you, swaps in the real value and sends it on. Sent anywhere else, it is blocked and logged.
      </p>
      <dl class="grid grid-cols-[8rem_minmax(0,1fr)] gap-x-4 gap-y-3 text-xs">
        <dt class="pt-0.5 text-muted">In the VM</dt>
        <dd class="space-y-1">
          <p :for={var <- @grant.env} class="font-mono text-[11px] text-ink">
            {var}=<span class="select-all text-muted">{@grant.placeholder}</span>
          </p>
          <p :for={var <- @grant.file_env} class="font-mono text-[11px] text-ink">
            {var}=<span class="text-muted">{Grant.token_file(@grant)}</span>
          </p>
          <p class="text-[11px] text-faint">
            The file {Grant.token_file(@grant)} holds the placeholder too.
          </p>
          <p :if={Grant.git_hosts(@grant) != []} class="text-[11px] text-faint">
            git over HTTPS gets it from MDT's credential helper for {Enum.join(
              Grant.git_hosts(@grant),
              ", "
            )}.
          </p>
        </dd>

        <dt class="pt-0.5 text-muted">May go to</dt>
        <dd class="flex flex-wrap gap-1.5">
          <span
            :for={host <- @grant.hosts}
            class="rounded border border-line bg-deep px-1.5 py-0.5 font-mono text-[11px] text-ink"
          >
            {host}
          </span>
        </dd>

        <dt class="pt-0.5 text-muted">Swapped in</dt>
        <dd class="text-[11px] text-ink">
          Any header carrying the placeholder, Basic credentials included.
        </dd>

        <dt class="pt-0.5 text-muted">Real value</dt>
        <dd>
          <%= case @grant.source do %>
            <% {:minted, command} -> %>
              <p class="text-[11px] text-ink">Minted on this machine when needed, by</p>
              <code class="mt-1 block break-all rounded-md border border-line-soft bg-deep px-2 py-1.5 font-mono text-[10px] leading-4 text-muted">
                {command}
              </code>
            <% :stored -> %>
              <p class="text-[11px] text-ink">Stored in your vault</p>
          <% end %>
        </dd>
      </dl>
    </div>
    """
  end

  defp delivery(%{grant: %Grant{kind: :network}} = assigns) do
    ~H"""
    <div class="space-y-4">
      <p class="text-xs leading-5 text-muted">
        Nothing to hold. While this is on, MDT lets the VM's connections to these destinations through, from this machine, so they reach whatever your network or VPN reaches.
      </p>
      <ul class="space-y-1.5">
        <li
          :for={destination <- @grant.destinations}
          class="flex items-center gap-2 rounded-md border border-line-soft bg-deep px-2.5 py-1.5"
        >
          <.icon name="hero-signal-micro" class="size-3.5 text-accent" />
          <span class="font-mono text-[11px] text-ink">{destination}</span>
        </li>
      </ul>
      <p class="text-[11px] leading-4 text-faint">
        Services behind a VPN often trust where a connection comes from, so the VM acts as you there. List destinations, not whole networks, where you can.
      </p>
    </div>
    """
  end

  defp delivery(%{grant: %Grant{kind: :file}} = assigns) do
    ~H"""
    <div class="space-y-3">
      <div class="flex gap-2.5 rounded-lg border border-warn/35 bg-warn-soft/30 p-3">
        <.icon name="hero-exclamation-triangle" class="mt-px size-4 shrink-0 text-warn" />
        <p class="text-xs leading-5 text-ink">
          Some tools must read a value themselves: a key that signs, a kubeconfig with client certificates. There is nothing on the wire to swap, so the VM gets the real value. Turning this off deletes the file, but anything the VM copied keeps working until the value expires at its provider. Prefer short-lived values.
        </p>
      </div>
      <dl class="grid grid-cols-[8rem_minmax(0,1fr)] gap-x-4 gap-y-2 text-xs">
        <dt class="text-muted">In the VM</dt>
        <dd class="font-mono text-[11px] text-ink">{@grant.path}</dd>
        <dt class="text-muted">Real value</dt>
        <dd class="text-[11px] text-ink">
          Stored in your vault, written to the file only while on.
        </dd>
      </dl>
    </div>
    """
  end

  ## Adding a grant

  @doc """
  The dialog that adds a grant: first a type or a preset, then the form.
  Opened from an agent's ask, it says what the agent asked for, and the new
  grant answers it.
  """
  attr :adding, :map, required: true
  attr :waiting, :list, required: true

  def add_dialog(assigns) do
    assigns =
      assign(assigns,
        ask:
          Enum.find(
            assigns.waiting,
            &(&1.id == assigns.adding[:approval_id] and &1.kind == :activation)
          )
      )

    ~H"""
    <div
      id="add-grant-dialog"
      class="fixed inset-0 z-50 flex items-center justify-center p-6"
      role="dialog"
      aria-modal="true"
      aria-labelledby="add-grant-title"
      phx-window-keydown="close_add_grant"
      phx-key="Escape"
    >
      <div class="absolute inset-0 bg-black/50 backdrop-blur-[1px]" phx-click="close_add_grant"></div>
      <div class="relative flex max-h-full w-full max-w-2xl flex-col overflow-hidden rounded-xl border border-line bg-panel shadow-2xl shadow-black/30 transition duration-150 ease-out motion-safe:starting:scale-[0.98] starting:opacity-0 dark:shadow-black/60">
        <header class="flex items-center gap-3 border-b border-line-soft px-5 py-3.5">
          <button
            :if={@adding.step == :details}
            type="button"
            id="add-grant-back"
            phx-click="add_grant_back"
            title="Pick another type"
            class="flex size-7 cursor-pointer items-center justify-center rounded text-muted transition-colors hover:bg-hover hover:text-ink"
          >
            <.icon name="hero-arrow-left-micro" class="size-4" />
          </button>
          <div class="min-w-0 flex-1">
            <h2 id="add-grant-title" class="text-sm font-semibold text-ink">
              {if @adding.step == :pick, do: "Add a grant", else: "Add #{@adding.preset.name}"}
            </h2>
            <p class="mt-0.5 text-[11px] text-muted">
              <%= cond do %>
                <% @ask -> %>
                  {@ask.agent} asked for: {@ask.need}
                <% @adding.step == :pick -> %>
                  Pick what it is, or start from a preset.
                <% true -> %>
                  {@adding.preset.blurb}
              <% end %>
            </p>
          </div>
          <button
            type="button"
            id="add-grant-close"
            phx-click="close_add_grant"
            title="Close"
            class="flex size-7 cursor-pointer items-center justify-center rounded text-muted transition-colors hover:bg-hover hover:text-ink"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </header>

        <div class="min-h-0 overflow-y-auto p-5">
          <div :if={@adding.step == :pick} class="space-y-5">
            <div id="type-grid" class="grid gap-2.5 sm:grid-cols-3">
              <button
                :for={type <- Presets.types()}
                type="button"
                id={"type-#{type.id}"}
                phx-click="pick_preset"
                phx-value-preset={type.id}
                class="group flex cursor-pointer flex-col items-start gap-2 rounded-lg border border-line p-3 text-left transition-all hover:-translate-y-px hover:border-accent/50 hover:bg-accent-soft/20 focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-accent"
              >
                <span class="flex size-8 items-center justify-center rounded-lg bg-deep text-muted transition-colors group-hover:text-accent">
                  <.icon name={type.icon} class="size-4" />
                </span>
                <span class="block text-xs font-semibold text-ink">{type.name}</span>
                <span class="block text-[11px] leading-4 text-muted">{type.blurb}</span>
                <span class={[
                  "inline-flex items-center gap-1 text-[10px] font-medium",
                  if(type.kind == :file, do: "text-warn-strong", else: "text-ok-strong")
                ]}>
                  <.icon
                    name={
                      if type.kind == :file,
                        do: "hero-exclamation-triangle-micro",
                        else: "hero-shield-check-micro"
                    }
                    class="size-3"
                  />
                  {exposure_words(type.kind)}
                </span>
              </button>
            </div>

            <div>
              <p class="mb-2 text-[10px] font-semibold uppercase tracking-wide text-muted">
                Presets
              </p>
              <div id="preset-grid" class="grid gap-2 sm:grid-cols-2">
                <button
                  :for={preset <- Presets.presets()}
                  type="button"
                  id={"preset-#{preset.id}"}
                  phx-click="pick_preset"
                  phx-value-preset={preset.id}
                  class="group flex cursor-pointer items-center gap-2.5 rounded-lg border border-line-soft px-3 py-2 text-left transition-all hover:border-accent/50 hover:bg-accent-soft/20"
                >
                  <.icon
                    name={preset.icon}
                    class="size-4 shrink-0 text-muted transition-colors group-hover:text-accent"
                  />
                  <span class="min-w-0 flex-1">
                    <span class="block text-xs font-medium text-ink">{preset.name}</span>
                    <span class="block truncate text-[10px] text-faint">{preset.blurb}</span>
                  </span>
                  <span class="shrink-0 rounded bg-deep px-1.5 py-0.5 text-[9px] font-medium uppercase tracking-wide text-faint">
                    {Presets.kind_name(preset.kind)}
                  </span>
                </button>
              </div>
              <p class="mt-2 text-[11px] leading-4 text-faint">
                A preset only fills the form. What it makes is a plain grant you can change.
              </p>
            </div>
          </div>

          <.form
            :if={@adding.step == :details}
            for={@adding.form}
            id="add-grant-form"
            phx-change="validate_grant"
            phx-submit="create_grant"
            class="space-y-4"
          >
            <input type="hidden" name="grant[kind]" value={@adding.preset.kind} />
            <input type="hidden" name="grant[preset]" value={@adding.preset.id} />
            <ol
              id="preset-guide"
              class="space-y-1.5 rounded-lg border border-accent/25 bg-accent-soft/20 p-3"
            >
              <li
                :for={{step, index} <- Enum.with_index(@adding.preset.guide, 1)}
                class="flex gap-2.5 text-xs leading-5 text-ink"
              >
                <span class="flex size-5 shrink-0 items-center justify-center rounded-full bg-accent-soft text-[10px] font-semibold text-accent-strong">
                  {index}
                </span>
                <span>{step}</span>
              </li>
            </ol>

            <.input
              field={@adding.form[:name]}
              label="Name"
              placeholder="Shown on switches and approvals"
              phx-mounted={JS.focus()}
            />
            <.field_error errors={@adding.errors} field={:name} />

            <div>
              <.input
                field={@adding.form[:purpose]}
                type="textarea"
                label="What it's for"
                rows="2"
                placeholder="Push to github.com/me/project and open pull requests there"
              />
              <p class="mt-1 text-[10px] text-faint">
                Agents in the VM read this to find the grant they need. Say what it opens, and for what.
              </p>
              <.field_error errors={@adding.errors} field={:purpose} />
            </div>

            <%= if @adding.preset.kind == :token do %>
              <div class="grid gap-4 sm:grid-cols-2">
                <div>
                  <.input
                    field={@adding.form[:hosts]}
                    label="Hosts it may go to"
                    placeholder="api.example.com"
                  />
                  <p class="mt-1 text-[10px] text-faint">
                    Comma separated. *.example.com covers subdomains.
                  </p>
                  <.field_error errors={@adding.errors} field={:hosts} />
                </div>
                <div>
                  <.input
                    field={@adding.form[:env]}
                    label="Variables holding the placeholder"
                    placeholder="API_TOKEN"
                  />
                  <p class="mt-1 text-[10px] text-faint">
                    Comma separated. Optional: a file holds it too.
                  </p>
                  <.field_error errors={@adding.errors} field={:env} />
                </div>
              </div>

              <details
                id="token-more"
                class="group rounded-lg border border-line-soft"
                open={
                  @adding.form[:file_env].value not in [nil, ""] or
                    @adding.form[:git].value == "true" or @adding.errors[:prefix] != nil
                }
              >
                <summary class="flex cursor-pointer list-none items-center gap-1.5 px-3 py-2 text-[11px] font-medium text-muted transition-colors hover:text-ink [&::-webkit-details-marker]:hidden">
                  <.icon
                    name="hero-chevron-right-micro"
                    class="size-3.5 transition-transform group-open:rotate-90"
                  /> More ways the VM gets it
                </summary>
                <div class="grid gap-4 border-t border-line-soft p-3 sm:grid-cols-2">
                  <div>
                    <.input
                      field={@adding.form[:file_env]}
                      label="Variables naming the token file"
                      placeholder="CLOUDSDK_AUTH_ACCESS_TOKEN_FILE"
                    />
                    <p class="mt-1 text-[10px] text-faint">
                      For tools that read the token from a file.
                    </p>
                  </div>
                  <div>
                    <.input
                      field={@adding.form[:prefix]}
                      label="Placeholder starts with"
                      placeholder="mdt_"
                    />
                    <p class="mt-1 text-[10px] text-faint">
                      For clients that check the format: ghp_, sk-, ….
                    </p>
                    <.field_error errors={@adding.errors} field={:prefix} />
                  </div>
                  <label class="flex cursor-pointer items-start gap-2 sm:col-span-2">
                    <input type="hidden" name="grant[git]" value="false" />
                    <input
                      type="checkbox"
                      name="grant[git]"
                      id="grant-git"
                      value="true"
                      checked={@adding.form[:git].value == "true"}
                      class="mt-0.5 size-3.5 cursor-pointer accent-accent"
                    />
                    <span class="text-xs text-ink">
                      Answer git over HTTPS for these hosts
                      <span class="block text-[10px] text-faint">
                        MDT's credential helper gives git the placeholder as the password.
                      </span>
                    </span>
                  </label>
                </div>
              </details>

              <div>
                <p class="mb-1.5 text-[11px] font-medium uppercase tracking-wide text-muted">
                  The real value
                </p>
                <div
                  id="grant-source"
                  class="mb-2 inline-flex items-center gap-0.5 rounded-md border border-line bg-deep p-0.5"
                >
                  <label
                    :for={
                      {value, label} <- [
                        {"stored", "Stored in your vault"},
                        {"minted", "Minted by a command"}
                      ]
                    }
                    class="relative"
                  >
                    <input
                      type="radio"
                      name="grant[source]"
                      id={"grant-source-#{value}"}
                      value={value}
                      checked={source(@adding.form) == value}
                      class="peer sr-only"
                    />
                    <span class="block cursor-pointer rounded px-2 py-1 text-[11px] font-medium text-muted transition-colors hover:text-ink peer-checked:bg-active peer-checked:text-ink peer-checked:shadow-sm">
                      {label}
                    </span>
                  </label>
                </div>
                <div :if={source(@adding.form) == "minted"}>
                  <.input
                    field={@adding.form[:mint]}
                    placeholder="gcloud auth print-access-token --impersonate-service-account=… --lifetime=1800s"
                  />
                  <p class="mt-1 text-[10px] text-faint">
                    Runs on this machine, with your host login, when the VM needs a token. Only its output is used, for up to 10 minutes.
                  </p>
                  <.field_error errors={@adding.errors} field={:mint} />
                </div>
                <div :if={source(@adding.form) == "stored"}>
                  <input
                    type="password"
                    name="grant[value]"
                    id="grant-value"
                    autocomplete="new-password"
                    placeholder="Paste the token"
                    class={input_classes()}
                  />
                  <p class="mt-1 text-[10px] text-faint">
                    Kept in your vault, encrypted with your password. The VM only ever gets the placeholder.
                  </p>
                  <.field_error errors={@adding.errors} field={:value} />
                </div>
              </div>
            <% end %>

            <div :if={@adding.preset.kind == :network}>
              <.input
                field={@adding.form[:destinations]}
                type="textarea"
                label="Destinations"
                placeholder="10.20.0.0/16:443,5432\ngit.corp.internal:443"
              />
              <p class="mt-1 text-[10px] text-faint">
                One per line: an address, a range or a host name, then optionally :ports. Anything after # is a note.
              </p>
              <.field_error errors={@adding.errors} field={:destinations} />
            </div>

            <div :if={@adding.preset.kind == :file} class="space-y-3">
              <div class="flex gap-2.5 rounded-lg border border-warn/35 bg-warn-soft/30 p-3">
                <.icon name="hero-exclamation-triangle" class="mt-px size-4 shrink-0 text-warn" />
                <p class="text-xs leading-5 text-ink">
                  The VM will hold the real value. Turning this off deletes the file, but not copies. Use it only when nothing else works, and prefer a value that expires.
                </p>
              </div>
              <div>
                <.input field={@adding.form[:path]} label="File name" placeholder="kubeconfig" />
                <p class="mt-1 text-[10px] text-faint">
                  Written to /mnt/mdt/files/ while the grant is on.
                </p>
                <.field_error errors={@adding.errors} field={:path} />
              </div>
              <div>
                <label class="mb-1 block text-[11px] font-medium uppercase tracking-wide text-muted">
                  Content
                </label>
                <textarea
                  name="grant[value]"
                  id="grant-value"
                  rows="5"
                  spellcheck="false"
                  autocomplete="off"
                  class={[input_classes(), "font-mono text-xs"]}
                ></textarea>
                <.field_error errors={@adding.errors} field={:value} />
              </div>
            </div>

            <p
              :if={@adding.preset.kind != :file}
              class="flex items-start gap-2 rounded-lg border border-line-soft bg-deep/50 p-3 text-[11px] leading-4 text-muted"
            >
              <.icon name="hero-hand-raised-micro" class="mt-px size-3.5 shrink-0 text-warn" />
              Once on, every {if @adding.preset.kind == :network, do: "connection", else: "request"} using it waits for your approval. From an approval, or the grant's page, you can let uses through for a while.
            </p>

            <footer class="flex items-center justify-end gap-2 pt-1">
              <.button type="button" phx-click="close_add_grant" variant="ghost">Cancel</.button>
              <.button type="submit" id="create-grant" variant="primary">
                {if @ask,
                  do: "Add and turn on for #{minutes_words(@ask.minutes)}",
                  else: "Add grant"}
              </.button>
            </footer>
          </.form>
        </div>
      </div>
    </div>
    """
  end

  defp source(form), do: if(form[:source].value == "minted", do: "minted", else: "stored")

  defp minutes_words(60), do: "1 h"
  defp minutes_words(minutes) when rem(minutes, 60) == 0, do: "#{div(minutes, 60)} h"
  defp minutes_words(minutes), do: "#{minutes} min"

  attr :errors, :map, required: true
  attr :field, :atom, required: true

  defp field_error(assigns) do
    ~H"""
    <p
      :if={@errors[@field]}
      id={"grant-error-#{@field}"}
      class="mt-1 flex items-center gap-1.5 text-[11px] text-bad"
    >
      <.icon name="hero-exclamation-circle-micro" class="size-3.5" /> {@errors[@field]}
    </p>
    """
  end

  defp exposure_words(:token), do: "VM gets a placeholder"
  defp exposure_words(:network), do: "Nothing to hold"
  defp exposure_words(:file), do: "VM holds the value"
end
