defmodule MDTClientWeb.SandboxLive.Grants do
  @moduledoc """
  The grants page: every credential and piece of network access the VM can be
  given, each with a switch; one grant's details, rules and allowances; and
  the dialog that adds a grant from a recipe.
  """
  use MDTClientWeb, :html

  import MDTClientWeb.SandboxLive.Components

  alias MDTClient.Sandbox.{Grant, Recipes, Rule}

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
      subtitle="Turn access on for as long as a task needs. Credentials sent over HTTP never enter the VM: it gets a placeholder, and MDT swaps the real value in on the way out."
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
    assigns = assign(assigns, recipe: Recipes.fetch!(assigns.grant.recipe))

    ~H"""
    <li
      id={"grant-row-#{@grant.id}"}
      class="group/row flex items-center gap-3 px-4 py-3 transition-colors hover:bg-hover/40"
    >
      <.grant_tile recipe={@recipe} on={Grant.on?(@grant)} />
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
        </div>
        <p class="mt-0.5 truncate font-mono text-[11px] text-muted">{summary(@grant)}</p>
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
  def summary(%Grant{kind: :http} = grant) do
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
    assigns = assign(assigns, recipe: Recipes.fetch!(assigns.grant.recipe))

    ~H"""
    <.link
      patch={~p"/tools/sandbox/grants"}
      id="grant-back"
      class="mb-4 inline-flex items-center gap-1.5 text-xs text-muted transition-colors hover:text-accent"
    >
      <.icon name="hero-arrow-left-micro" class="size-3.5" /> All grants
    </.link>

    <header id={"grant-detail-#{@grant.id}"} class="mb-5 flex flex-wrap items-center gap-3">
      <.grant_tile recipe={@recipe} on={Grant.on?(@grant)} class="size-11" />
      <div class="min-w-0 flex-1">
        <div class="flex flex-wrap items-center gap-2">
          <h1 class="text-lg font-semibold tracking-tight text-ink">{@grant.name}</h1>
          <.exposure grant={@grant} />
        </div>
        <p class="mt-0.5 text-[13px] text-muted">{@recipe.name} · {@recipe.blurb}</p>
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
          :if={@grant.kind in [:http, :file] and @grant.source == :stored}
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
          :if={@grant.kind == :http}
          id="grant-rules"
          title="Rules"
          subtitle="Checked in order for every request that carries the placeholder. Ask holds the request until you decide."
          body_class=""
        >
          <ul class="divide-y divide-line-soft">
            <li
              :for={rule <- @grant.rules}
              id={"rule-#{@grant.id}-#{rule.id}"}
              class="flex items-center gap-3 px-4 py-2.5"
            >
              <div class="min-w-0 flex-1">
                <p class="text-xs font-medium text-ink">{rule.label}</p>
                <p class="mt-0.5 truncate font-mono text-[10px] text-faint">{rule.match}</p>
              </div>
              <.segmented
                id={"rule-action-#{@grant.id}-#{rule.id}"}
                options={for action <- Rule.actions(), do: {action, action_word(action)}}
                value={rule.action}
                event="set_rule"
                name="action"
                values={%{"id" => @grant.id, "rule" => rule.id}}
                tone={:actions}
              />
            </li>
            <li
              id={"rule-#{@grant.id}-default"}
              class="flex items-center gap-3 bg-deep/40 px-4 py-2.5"
            >
              <div class="min-w-0 flex-1">
                <p class="text-xs font-medium text-ink">Anything else</p>
                <p class="mt-0.5 text-[10px] text-faint">When no rule above matches</p>
              </div>
              <.segmented
                id={"rule-default-#{@grant.id}"}
                options={for action <- Rule.actions(), do: {action, action_word(action)}}
                value={@grant.default_action}
                event="set_default"
                name="action"
                values={%{"id" => @grant.id}}
                tone={:actions}
              />
            </li>
          </ul>
        </.card>

        <.card
          :if={@grant.kind == :network}
          id="grant-connections"
          title="Connections"
          subtitle="Raw connections can't be read like HTTP, so the choice is per connection."
        >
          <div class="flex items-center gap-3">
            <p class="flex-1 text-xs text-muted">
              When the VM opens a connection to one of these destinations
            </p>
            <.segmented
              id={"per-connection-#{@grant.id}"}
              options={[{:allow, "Let it through"}, {:ask, "Ask me"}]}
              value={@grant.per_connection}
              event="set_per_connection"
              name="choice"
              values={%{"id" => @grant.id}}
              tone={:actions}
            />
          </div>
        </.card>
      </div>

      <div class="space-y-5">
        <.card
          :if={@grant.kind == :http}
          id="grant-allowances"
          title="Allowed for now"
          subtitle="Added by “Allow similar” on an approval. They end with their time, or when the grant turns off."
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
                <p class="break-all font-mono text-[11px] text-ink">{allowance.pattern}</p>
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

  defp delivery(%{grant: %Grant{kind: :http}} = assigns) do
    ~H"""
    <div class="space-y-4">
      <p class="text-xs leading-5 text-muted">
        The VM sees a placeholder. When a request carrying it goes to one of the hosts below, MDT checks the rules, swaps in the real value and sends it on. Sent anywhere else, it is blocked and logged.
      </p>
      <dl class="grid grid-cols-[8rem_minmax(0,1fr)] gap-x-4 gap-y-3 text-xs">
        <dt class="pt-0.5 text-muted">In the VM</dt>
        <dd class="space-y-1">
          <p :for={var <- @grant.env} class="font-mono text-[11px] text-ink">
            {var}=<span class="select-all text-muted">{@grant.placeholder}</span>
          </p>
          <p :if={@grant.recipe == :github} class="text-[11px] text-faint">
            plus a git credential helper for https://github.com
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

        <dt class="pt-0.5 text-muted">Carried in</dt>
        <dd class="space-y-0.5">
          <p :for={carrier <- @grant.carriers} class="font-mono text-[11px] text-ink">{carrier}</p>
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

  @doc "The dialog that adds a grant: first what kind, then its details."
  attr :adding, :map, required: true
  attr :requests, :list, required: true

  def add_dialog(assigns) do
    assigns =
      assign(assigns,
        request: Enum.find(assigns.requests, &(&1.id == assigns.adding[:request_id]))
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
            title="Pick another kind"
            class="flex size-7 cursor-pointer items-center justify-center rounded text-muted transition-colors hover:bg-hover hover:text-ink"
          >
            <.icon name="hero-arrow-left-micro" class="size-4" />
          </button>
          <div class="min-w-0 flex-1">
            <h2 id="add-grant-title" class="text-sm font-semibold text-ink">
              {if @adding.step == :recipe, do: "Add a grant", else: "Add #{@adding.recipe.name}"}
            </h2>
            <p class="mt-0.5 text-[11px] text-muted">
              <%= if @request do %>
                {@request.agent} asked for: {@request.need}
              <% else %>
                {if @adding.step == :recipe,
                  do: "Pick what it is. Each kind starts from the safest way to deliver it.",
                  else: @adding.recipe.blurb}
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
          <div :if={@adding.step == :recipe} id="recipe-grid" class="grid gap-2.5 sm:grid-cols-2">
            <button
              :for={recipe <- Recipes.all()}
              type="button"
              id={"recipe-#{recipe.id}"}
              phx-click="pick_recipe"
              phx-value-recipe={recipe.id}
              class="group flex cursor-pointer items-start gap-3 rounded-lg border border-line p-3 text-left transition-all hover:-translate-y-px hover:border-accent/50 hover:bg-accent-soft/20 focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-accent"
            >
              <span class="flex size-8 shrink-0 items-center justify-center rounded-lg bg-deep text-muted transition-colors group-hover:text-accent">
                <.icon name={recipe.icon} class="size-4" />
              </span>
              <span class="min-w-0 flex-1">
                <span class="block text-xs font-semibold text-ink">{recipe.name}</span>
                <span class="mt-0.5 block text-[11px] leading-4 text-muted">{recipe.blurb}</span>
                <span class={[
                  "mt-1.5 inline-flex items-center gap-1 text-[10px] font-medium",
                  if(recipe.kind == :file, do: "text-warn-strong", else: "text-ok-strong")
                ]}>
                  <.icon
                    name={
                      if recipe.kind == :file,
                        do: "hero-exclamation-triangle-micro",
                        else: "hero-shield-check-micro"
                    }
                    class="size-3"
                  />
                  {exposure_words(recipe)}
                </span>
              </span>
            </button>
          </div>

          <.form
            :if={@adding.step == :details}
            for={@adding.form}
            id="add-grant-form"
            phx-change="validate_grant"
            phx-submit="create_grant"
            class="space-y-4"
          >
            <input type="hidden" name="grant[recipe]" value={@adding.recipe.id} />
            <ol
              id="recipe-guide"
              class="space-y-1.5 rounded-lg border border-accent/25 bg-accent-soft/20 p-3"
            >
              <li
                :for={{step, index} <- Enum.with_index(@adding.recipe.guide, 1)}
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

            <%= if @adding.recipe.kind == :http do %>
              <div class="grid gap-4 sm:grid-cols-2">
                <div>
                  <.input
                    field={@adding.form[:env]}
                    label="Variables in the VM"
                    placeholder="API_TOKEN"
                  />
                  <p class="mt-1 text-[10px] text-faint">
                    Comma separated. They hold the placeholder.
                  </p>
                  <.field_error errors={@adding.errors} field={:env} />
                </div>
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
              </div>
              <div :if={@adding.recipe.source == :minted}>
                <.input
                  field={@adding.form[:mint]}
                  label="Command that prints a short-lived token"
                  placeholder="gcloud auth print-access-token --impersonate-service-account=… --lifetime=1800s"
                />
                <p class="mt-1 text-[10px] text-faint">
                  Runs on this machine, with your host login. Only its output is used, and only until it expires.
                </p>
                <.field_error errors={@adding.errors} field={:mint} />
              </div>
              <div :if={@adding.recipe.source == :stored}>
                <label class="mb-1 block text-[11px] font-medium uppercase tracking-wide text-muted">
                  Value
                </label>
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
            <% end %>

            <div :if={@adding.recipe.kind == :network}>
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

            <div :if={@adding.recipe.kind == :file} class="space-y-3">
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

            <div
              :if={@adding.recipe.rules != []}
              class="rounded-lg border border-line-soft bg-deep/50 p-3"
            >
              <p class="text-[10px] font-semibold uppercase tracking-wide text-muted">
                Starts with these rules
              </p>
              <ul class="mt-2 space-y-1">
                <li :for={rule <- @adding.recipe.rules} class="flex items-center gap-2 text-[11px]">
                  <span class={[
                    "w-10 shrink-0 rounded px-1 py-px text-center text-[9px] font-semibold uppercase",
                    rule.action == :allow && "bg-ok-soft text-ok-strong",
                    rule.action == :ask && "bg-warn-soft text-warn-strong",
                    rule.action == :deny && "bg-bad-soft text-bad"
                  ]}>
                    {action_word(rule.action)}
                  </span>
                  <span class="text-ink">{rule.label}</span>
                  <span class="truncate font-mono text-[10px] text-faint">{rule.match}</span>
                </li>
              </ul>
            </div>

            <footer class="flex items-center justify-end gap-2 pt-1">
              <.button type="button" phx-click="close_add_grant" variant="ghost">Cancel</.button>
              <.button type="submit" id="create-grant" variant="primary">
                {if @request, do: "Add and turn on for #{@request.minutes} min", else: "Add grant"}
              </.button>
            </footer>
          </.form>
        </div>
      </div>
    </div>
    """
  end

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

  defp exposure_words(%{kind: :http, source: :minted}), do: "Minted here, VM gets a placeholder"
  defp exposure_words(%{kind: :http}), do: "VM gets a placeholder"
  defp exposure_words(%{id: :database}), do: "Login stays in the tunnel"
  defp exposure_words(%{kind: :network}), do: "Nothing to hold"
  defp exposure_words(%{kind: :file}), do: "VM holds the value"
end
