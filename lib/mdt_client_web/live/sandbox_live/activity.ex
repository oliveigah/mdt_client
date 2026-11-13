defmodule MDTClientWeb.SandboxLive.Activity do
  @moduledoc """
  The activity page: every connection the VM made, every swap, decision and
  refusal, newest first, filterable by what happened, which grant and words.

  It shows one page at a time. The newest page takes new activity in at the
  top while it matches the filters; an older page stays as it is and counts
  what came in since, with a way back to the newest.
  """
  use MDTClientWeb, :html

  import MDTClientWeb.SandboxLive.Components

  @groups [
    {"all", "All"},
    {"traffic", "Passed"},
    {"credentials", "Credentials"},
    {"blocked", "Blocked"},
    {"changes", "Changes"},
    {"commands", "Host commands"}
  ]

  attr :streams, :any, required: true
  attr :filters, :map, required: true
  attr :activity, :map, required: true, doc: "where the page is: cursors, older?, shown, fresh"
  attr :page_size, :integer, required: true
  attr :grants, :list, required: true
  attr :grant_names, :map, required: true
  attr :now, DateTime, required: true

  def page(assigns) do
    page = length(assigns.activity.cursors) + 1
    first = (page - 1) * assigns.page_size + 1

    assigns =
      assign(assigns,
        groups: @groups,
        page: page,
        range: "#{first}–#{first + max(assigns.activity.shown, 1) - 1}"
      )

    ~H"""
    <.page_header id="activity-header" title="Activity">
      <:help>
        What the VM did on the network, as MDT saw it. Values are never logged: a swap records that a placeholder was replaced, not what with. MDT keeps the latest 1,000 events while it runs.
      </:help>
    </.page_header>

    <form
      id="activity-filters"
      phx-change="filter_activity"
      phx-submit="filter_activity"
      class="mb-3 flex flex-wrap items-center gap-2"
      autocomplete="off"
    >
      <div class="relative min-w-56 flex-1">
        <.icon
          name="hero-magnifying-glass"
          class="pointer-events-none absolute left-2 top-1/2 size-3.5 -translate-y-1/2 text-faint"
        />
        <input
          type="text"
          name="q"
          id="activity-search"
          value={@filters.q}
          placeholder="Host, path or words"
          phx-debounce="150"
          class="w-full rounded-md border border-line bg-deep py-1.5 pl-7 pr-2.5 text-xs text-ink outline-none transition-colors placeholder:text-faint focus:border-accent/60 focus:ring-2 focus:ring-accent/15"
        />
      </div>
      <div
        id="activity-groups"
        role="radiogroup"
        class="inline-flex items-center gap-0.5 rounded-md border border-line bg-deep p-0.5"
      >
        <label
          :for={{value, label} <- @groups}
          id={"activity-group-#{value}"}
          class={[
            "cursor-pointer rounded px-2 py-1 text-[11px] font-medium transition-colors",
            if(@filters.group == value,
              do: "bg-active text-ink shadow-sm",
              else: "text-muted hover:bg-hover hover:text-ink"
            )
          ]}
        >
          <input
            type="radio"
            name="group"
            value={value}
            checked={@filters.group == value}
            class="sr-only"
          />
          {label}
        </label>
      </div>
      <select
        name="grant"
        id="activity-grant"
        class="rounded-md border border-line bg-deep px-2 py-1.5 text-xs text-ink outline-none focus:border-accent/60"
      >
        <option value="" selected={@filters.grant == ""}>Any grant</option>
        <option :for={grant <- @grants} value={grant.id} selected={@filters.grant == grant.id}>
          {grant.name}
        </option>
      </select>
    </form>

    <button
      :if={@activity.fresh > 0}
      type="button"
      id="activity-fresh"
      phx-click="latest_activity"
      class="mb-3 flex w-full cursor-pointer items-center justify-center gap-1.5 rounded-lg border border-accent/30 bg-accent-soft/40 px-3 py-1.5 text-[11px] font-medium text-accent-strong transition-colors hover:bg-accent-soft/70"
    >
      <.icon name="hero-arrow-up-micro" class="size-3.5" />
      {@activity.fresh} newer {if @activity.fresh == 1, do: "event", else: "events"} · Back to the latest
    </button>

    <div
      id="activity-table"
      phx-hook=".Paged"
      class="overflow-hidden rounded-xl border border-line bg-panel"
    >
      <div class="grid grid-cols-[4.5rem_6rem_minmax(0,1fr)_8rem_8.5rem] items-center gap-3 border-b border-line-soft bg-deep/40 px-4 py-2 text-[10px] font-semibold uppercase tracking-wide text-faint">
        <span>When</span>
        <span>Outcome</span>
        <span>What</span>
        <span class="text-right">Grant</span>
        <span class="text-right">↑ / ↓</span>
      </div>
      <%!-- The empty states sit outside the stream: a child in it would count against its limit. --%>
      <div :if={@activity.shown == 0} id="activity-empty">
        <%= if @activity.cursors == [] do %>
          <.empty icon="hero-queue-list">Nothing matches these filters.</.empty>
        <% else %>
          <.empty icon="hero-clock" id="activity-aged-out">
            These have aged out: MDT keeps the latest 1,000.
          </.empty>
        <% end %>
      </div>
      <ul id="activity-log" phx-update="stream" class="divide-y divide-line-soft">
        <li
          :for={{dom_id, event} <- @streams.events}
          id={dom_id}
          class={[
            "grid grid-cols-[4.5rem_6rem_minmax(0,1fr)_8rem_8.5rem] items-center gap-3 px-4 py-2 transition-colors hover:bg-hover/40",
            event.outcome == :violation && "bg-bad-soft/20"
          ]}
        >
          <span class="font-mono text-[10px] text-faint" title={DateTime.to_iso8601(event.at)}>
            {Calendar.strftime(event.at, "%H:%M:%S")}
          </span>
          <span><.outcome_badge outcome={event.outcome} /></span>
          <div class="min-w-0">
            <p class="truncate text-xs text-ink">{event.summary}</p>
            <p :if={event.host} class="truncate font-mono text-[10px] text-muted">
              <span :if={event.method} class="font-semibold">{event.method}</span>
              {event.host}<span :if={event.port}>:{event.port}</span><span :if={event.path}>{event.path}</span>
            </p>
          </div>
          <span class="truncate text-right text-[11px] text-muted">
            {(event.grant_id && @grant_names[event.grant_id]) || "—"}
          </span>
          <span class="whitespace-nowrap text-right font-mono text-[10px] text-faint">
            <%= if event.up do %>
              {bytes(event.up)} / {bytes(event.down)}
            <% else %>
              —
            <% end %>
          </span>
        </li>
      </ul>
      <nav
        :if={@activity.cursors != [] or @activity.older?}
        id="activity-pager"
        aria-label="Activity pages"
        class="flex items-center gap-2 border-t border-line-soft bg-deep/30 px-4 py-2"
      >
        <span id="activity-range" class="text-[11px] text-muted">
          <%= if @activity.cursors == [] do %>
            Newest {@activity.shown}
          <% else %>
            Page {@page} · {@range}
          <% end %>
        </span>
        <div class="flex-1"></div>
        <button
          :if={length(@activity.cursors) > 1}
          type="button"
          id="activity-latest"
          phx-click="latest_activity"
          class="cursor-pointer rounded-md px-2 py-1 text-[11px] text-muted transition-colors hover:bg-hover hover:text-ink"
        >
          Latest
        </button>
        <.button
          type="button"
          id="activity-newer"
          phx-click="newer_activity"
          disabled={@activity.cursors == []}
        >
          <.icon name="hero-chevron-left-micro" class="size-3.5" /> Newer
        </.button>
        <.button
          type="button"
          id="activity-older"
          phx-click="older_activity"
          disabled={not @activity.older?}
        >
          Older <.icon name="hero-chevron-right-micro" class="size-3.5" />
        </.button>
      </nav>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Paged">
      export default {
        mounted() {
          // A new page starts at its newest row, not where the last one ended.
          this.handleEvent("activity_paged", () => {
            const still = window.matchMedia("(prefers-reduced-motion: reduce)").matches
            document.getElementById("sandbox-page")?.scrollTo({top: 0, behavior: still ? "auto" : "smooth"})
          })
        },
      }
    </script>
    """
  end
end
