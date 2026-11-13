defmodule MDTClientWeb.SandboxLive.Activity do
  @moduledoc """
  The activity page: every connection the VM made, every swap, decision and
  refusal, newest first, filterable by what happened, which grant and words.
  New activity streams in at the top while it matches the filters.
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
  attr :grants, :list, required: true
  attr :grant_names, :map, required: true
  attr :now, DateTime, required: true

  def page(assigns) do
    assigns = assign(assigns, :groups, @groups)

    ~H"""
    <.page_header
      title="Activity"
      subtitle="What the VM did on the network, as MDT saw it. Values are never logged: a swap records that a placeholder was replaced, not what with."
    />

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

    <div class="overflow-hidden rounded-xl border border-line bg-panel">
      <div class="grid grid-cols-[4.5rem_6rem_minmax(0,1fr)_8rem_8.5rem] items-center gap-3 border-b border-line-soft bg-deep/40 px-4 py-2 text-[10px] font-semibold uppercase tracking-wide text-faint">
        <span>When</span>
        <span>Outcome</span>
        <span>What</span>
        <span class="text-right">Grant</span>
        <span class="text-right">↑ / ↓</span>
      </div>
      <ul id="activity-log" phx-update="stream" class="divide-y divide-line-soft">
        <li id="activity-empty" class="hidden only:block">
          <.empty icon="hero-queue-list">Nothing matches these filters.</.empty>
        </li>
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
    </div>
    """
  end
end
