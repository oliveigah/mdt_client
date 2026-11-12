defmodule MDTClientWeb.SandboxLive.Approvals do
  @moduledoc """
  The approvals page, and the cards it shares with the overview: requests and
  connections held for a decision, agents asking for access, and what was
  decided before.

  A card keeps what MDT saw apart from what the agent wrote. Facts sit in a
  plain list; the agent's words sit in a dashed box marked as unverified, so
  a commit message cannot pass for a description of the request.
  """
  use MDTClientWeb, :html

  import MDTClientWeb.SandboxLive.Components

  alias MDTClient.Sandbox.{AgentRequest, Approval, Recipes}

  attr :waiting, :list, required: true
  attr :requests, :list, required: true
  attr :history, :list, required: true
  attr :answered, :list, required: true
  attr :grants, :map, required: true, doc: "grants by id"
  attr :hold_seconds, :integer, required: true
  attr :now, DateTime, required: true

  def page(assigns) do
    ~H"""
    <.page_header
      title="Approvals"
      subtitle="Requests that use a credential, and connections through a network grant, wait here until you decide. Undecided ones give up on their own and the agent gets a clear refusal."
    />

    <div class="space-y-6">
      <section id="waiting-approvals" aria-label="Waiting for a decision" class="space-y-3">
        <h2 class="flex items-center gap-2 text-[11px] font-semibold uppercase tracking-wide text-muted">
          Held requests
          <span class="rounded bg-deep px-1.5 py-0.5 font-mono text-[10px] text-faint">
            {length(@waiting)}
          </span>
        </h2>
        <div :if={@waiting == []} class="rounded-xl border border-dashed border-line">
          <.empty icon="hero-hand-raised" id="no-waiting-approvals">
            Nothing is waiting. Requests that a rule says to ask about will appear here, with what MDT saw and the agent's own words kept apart.
          </.empty>
        </div>
        <.approval_card
          :for={approval <- @waiting}
          approval={approval}
          grant={@grants[approval.grant_id]}
          hold_seconds={@hold_seconds}
          now={@now}
        />
      </section>

      <section id="agent-requests" aria-label="Agents asking for access" class="space-y-3">
        <h2 class="flex items-center gap-2 text-[11px] font-semibold uppercase tracking-wide text-muted">
          Agents asking for access
          <span class="rounded bg-deep px-1.5 py-0.5 font-mono text-[10px] text-faint">
            {length(@requests)}
          </span>
        </h2>
        <div :if={@requests == []} class="rounded-xl border border-dashed border-line">
          <.empty icon="hero-sparkles" id="no-agent-requests">
            Agents in the VM can ask for a grant through the agent channel. Their requests, and their reasons, show up here.
          </.empty>
        </div>
        <.request_card
          :for={request <- @requests}
          request={request}
          grant={request.grant_id && @grants[request.grant_id]}
          now={@now}
        />
      </section>

      <.card
        id="approval-history"
        title="Decided"
        subtitle="The latest 100 decisions, newest first."
        body_class=""
      >
        <div :if={@history == [] and @answered == []}>
          <.empty icon="hero-clock">Decisions you make will be listed here.</.empty>
        </div>
        <ul class="divide-y divide-line-soft">
          <li
            :for={approval <- @history}
            id={"decided-#{approval.id}"}
            class="flex items-center gap-3 px-4 py-2.5"
          >
            <.outcome_badge outcome={approval.status} />
            <div class="min-w-0 flex-1">
              <p class="truncate text-xs text-ink">{approval.title}</p>
              <p class="truncate text-[11px] text-faint">
                {grant_name(@grants, approval.grant_id)} · {decision_words(approval)}
              </p>
            </div>
            <span class="shrink-0 text-[11px] text-faint">
              <.clock id={"decided-at-#{approval.id}"} since={approval.decided_at} now={@now} />
            </span>
          </li>
          <li
            :for={request <- @answered}
            id={"answered-#{request.id}"}
            class="flex items-center gap-3 px-4 py-2.5"
          >
            <span class={[
              "inline-flex shrink-0 items-center rounded px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide",
              if(request.status == :granted,
                do: "bg-violet/15 text-violet-strong",
                else: "bg-hover text-muted"
              )
            ]}>
              {if request.status == :granted, do: "Granted", else: "Declined"}
            </span>
            <p class="min-w-0 flex-1 truncate text-xs text-ink">
              {request.agent} asked for {(request.grant_id && grant_name(@grants, request.grant_id)) ||
                request.need}
            </p>
            <span class="shrink-0 text-[11px] text-faint">
              <.clock id={"answered-at-#{request.id}"} since={request.answered_at} now={@now} />
            </span>
          </li>
        </ul>
      </.card>
    </div>
    """
  end

  @doc "One held request or connection, with everything needed to decide it."
  attr :approval, Approval, required: true
  attr :grant, :any, required: true
  attr :hold_seconds, :integer, required: true
  attr :now, DateTime, required: true
  attr :compact, :boolean, default: false

  def approval_card(assigns) do
    left = max(DateTime.diff(assigns.approval.deadline, assigns.now, :second), 0)

    assigns =
      assign(assigns,
        left: left,
        fraction: Float.round(min(left / max(assigns.hold_seconds, 1), 1.0), 3),
        recipe: recipe(assigns.grant)
      )

    ~H"""
    <article
      id={"approval-#{@approval.id}"}
      class="group/card rounded-xl border border-warn/35 bg-panel shadow-sm shadow-black/5 transition-shadow hover:shadow-md dark:shadow-black/30"
    >
      <div class="h-0.5 overflow-hidden rounded-t-xl bg-warn/15">
        <div
          id={"approval-drain-#{@approval.id}-#{@left}"}
          class="sandbox-drain h-full origin-left bg-warn"
          style={"--drain-from: #{@fraction}; animation-duration: #{@left}s"}
        >
        </div>
      </div>

      <header class="flex items-start gap-3 px-4 pb-3 pt-3.5">
        <.grant_tile recipe={@recipe} on={true} />
        <div class="min-w-0 flex-1">
          <div class="flex flex-wrap items-center gap-x-2 gap-y-1 text-[11px] text-muted">
            <span class="font-medium text-ink/80">{(@grant && @grant.name) || "Removed grant"}</span>
            <span class="text-faint">·</span>
            <span>{if @approval.kind == :connection, do: "Connection", else: "Request"}</span>
            <span
              :if={@approval.retries > 0}
              id={"approval-retries-#{@approval.id}"}
              title="The client retried while this waited. The retries joined this card; your decision answers them too."
              class="rounded bg-deep px-1.5 py-0.5 font-mono text-[10px] text-faint"
            >
              +{@approval.retries} {if @approval.retries == 1, do: "retry", else: "retries"}
            </span>
          </div>
          <h3 class="mt-0.5 text-sm font-semibold leading-5 text-ink">{@approval.title}</h3>
          <p class="mt-0.5 break-all font-mono text-[11px] text-muted">
            <span :if={@approval.method} class="font-semibold text-ink/70">{@approval.method}</span>
            {@approval.host}{@approval.path}
          </p>
        </div>
        <div class="shrink-0 text-right">
          <p class="text-[10px] font-medium uppercase tracking-wide text-faint">Gives up in</p>
          <.clock
            id={"approval-left-#{@approval.id}"}
            deadline={@approval.deadline}
            done="0:00"
            now={@now}
            class="font-mono text-sm font-semibold text-warn-strong"
          />
        </div>
      </header>

      <div
        :if={not @compact}
        class={[
          "grid gap-3 px-4 pb-4",
          @approval.claims != [] && "lg:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]"
        ]}
      >
        <div id={"approval-facts-#{@approval.id}"}>
          <p class="mb-1.5 flex items-center gap-1.5 text-[10px] font-semibold uppercase tracking-wide text-muted">
            <.icon name="hero-eye-micro" class="size-3" /> What MDT saw
          </p>
          <dl class="grid grid-cols-[auto_minmax(0,1fr)] gap-x-4 gap-y-1 text-xs">
            <%= for {label, value} <- @approval.facts do %>
              <dt class="text-muted">{label}</dt>
              <dd class="break-words font-mono text-[11px] leading-5 text-ink">{value}</dd>
            <% end %>
          </dl>
        </div>
        <div
          :if={@approval.claims != []}
          id={"approval-claims-#{@approval.id}"}
          class="rounded-lg border border-dashed border-line bg-deep/60 p-3"
        >
          <p class="mb-1.5 flex items-center gap-1.5 text-[10px] font-semibold uppercase tracking-wide text-muted">
            <.icon name="hero-chat-bubble-left-ellipsis-micro" class="size-3" /> The agent says
            <span class="rounded border border-line px-1 py-px text-[9px] font-medium normal-case tracking-normal text-faint">
              not verified
            </span>
          </p>
          <ul class="space-y-1.5">
            <li :for={{label, text} <- @approval.claims} class="text-xs leading-5">
              <span class="mr-1.5 text-[10px] uppercase tracking-wide text-faint">{label}</span>
              <span class="italic text-muted">“{text}”</span>
            </li>
          </ul>
        </div>
      </div>

      <footer class="flex flex-wrap items-center gap-2 rounded-b-xl border-t border-line-soft bg-deep/40 px-4 py-2.5">
        <button
          type="button"
          id={"allow-once-#{@approval.id}"}
          phx-click="decide"
          phx-value-id={@approval.id}
          phx-value-decision="allow_once"
          class="inline-flex cursor-pointer items-center gap-1.5 rounded-md bg-ok px-3 py-1.5 text-xs font-semibold text-deep transition-all hover:brightness-110 active:brightness-95 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ok"
        >
          <.icon name="hero-check-micro" class="size-3.5" /> Allow once
        </button>

        <details :if={@approval.pattern} id={"allow-similar-#{@approval.id}"} class="group relative">
          <summary class="inline-flex cursor-pointer list-none items-center gap-1 rounded-md border border-line bg-panel px-2.5 py-1.5 text-xs font-medium text-ink transition-colors hover:bg-hover [&::-webkit-details-marker]:hidden">
            Allow similar
            <.icon
              name="hero-chevron-down-micro"
              class="size-3.5 text-muted transition-transform group-open:rotate-180"
            />
          </summary>
          <div class="absolute left-0 top-full z-30 mt-1.5 w-80 rounded-lg border border-line bg-panel p-1.5 shadow-xl shadow-black/20">
            <p class="px-2 pb-1.5 pt-1 text-[11px] leading-4 text-muted">
              Lets these through without asking:
              <span class="mt-1 block break-all font-mono text-[10px] text-ink">{@approval.pattern}</span>
            </p>
            <button
              :for={
                {value, label} <- [
                  {"10", "For 10 minutes"},
                  {"60", "For 1 hour"},
                  {"grant", "While #{(@grant && @grant.name) || "the grant"} stays on"}
                ]
              }
              type="button"
              id={"allow-for-#{value}-#{@approval.id}"}
              phx-click="decide"
              phx-value-id={@approval.id}
              phx-value-decision="allow_for"
              phx-value-minutes={value}
              class="flex w-full cursor-pointer items-center gap-2 rounded-md px-2 py-1.5 text-left text-xs text-ink transition-colors hover:bg-hover"
            >
              <.icon name="hero-clock-micro" class="size-3.5 text-faint" />
              {label}
            </button>
          </div>
        </details>

        <div class="flex-1"></div>

        <button
          type="button"
          id={"deny-#{@approval.id}"}
          phx-click="decide"
          phx-value-id={@approval.id}
          phx-value-decision="deny"
          class="inline-flex cursor-pointer items-center gap-1.5 rounded-md border border-line bg-panel px-3 py-1.5 text-xs font-medium text-ink transition-colors hover:border-bad/50 hover:bg-bad-soft/40 hover:text-bad"
        >
          Deny
        </button>
        <button
          :if={@grant}
          type="button"
          id={"deny-off-#{@approval.id}"}
          phx-click="decide"
          phx-value-id={@approval.id}
          phx-value-decision="deny_and_turn_off"
          title={"Deny, and turn #{@grant.name} off so nothing else uses it"}
          class="inline-flex cursor-pointer items-center gap-1.5 rounded-md px-2.5 py-1.5 text-xs font-medium text-bad transition-colors hover:bg-bad-soft/40"
        >
          <.icon name="hero-no-symbol-micro" class="size-3.5" /> Deny and turn off
        </button>
      </footer>
    </article>
    """
  end

  @doc "An agent asking for access, in its own words."
  attr :request, AgentRequest, required: true
  attr :grant, :any, required: true
  attr :now, DateTime, required: true

  def request_card(assigns) do
    ~H"""
    <article
      id={"request-#{@request.id}"}
      class="overflow-hidden rounded-xl border border-violet/30 bg-panel shadow-sm shadow-black/5 dark:shadow-black/30"
    >
      <div class="flex items-start gap-3 px-4 pb-3 pt-3.5">
        <span class="flex size-8 shrink-0 items-center justify-center rounded-lg border border-violet/30 bg-violet/10 text-violet-strong">
          <.icon name="hero-sparkles" class="size-4" />
        </span>
        <div class="min-w-0 flex-1">
          <p class="text-[11px] text-muted">
            <span class="font-medium text-ink/80">{@request.agent}</span>
            in the VM ·
            <.clock id={"request-at-#{@request.id}"} since={@request.requested_at} now={@now} />
          </p>
          <h3 class="mt-0.5 text-sm font-semibold leading-5 text-ink">
            <%= if @grant do %>
              Asks for {@grant.name} for {@request.minutes} min
            <% else %>
              Asks for something you haven't set up
            <% end %>
          </h3>
          <p :if={@request.need} class="mt-1 text-xs text-ink">{@request.need}</p>
          <blockquote class="mt-2 border-l-2 border-violet/40 pl-3 text-xs leading-5">
            <span class="italic text-muted">“{@request.reason}”</span>
            <span class="ml-1 text-[10px] text-faint">the agent's words</span>
          </blockquote>
        </div>
      </div>
      <footer class="flex flex-wrap items-center gap-2 border-t border-line-soft bg-deep/40 px-4 py-2.5">
        <button
          :if={@grant}
          type="button"
          id={"grant-request-#{@request.id}"}
          phx-click="answer_request"
          phx-value-id={@request.id}
          phx-value-answer="grant"
          class="inline-flex cursor-pointer items-center gap-1.5 rounded-md bg-violet px-3 py-1.5 text-xs font-semibold text-deep transition-all hover:brightness-110 active:brightness-95"
        >
          <.icon name="hero-bolt-micro" class="size-3.5" /> Turn on for {@request.minutes} min
        </button>
        <button
          :if={is_nil(@grant)}
          type="button"
          id={"setup-request-#{@request.id}"}
          phx-click="open_add_grant"
          phx-value-request={@request.id}
          class="inline-flex cursor-pointer items-center gap-1.5 rounded-md bg-violet px-3 py-1.5 text-xs font-semibold text-deep transition-all hover:brightness-110 active:brightness-95"
        >
          <.icon name="hero-plus-micro" class="size-3.5" /> Set it up…
        </button>
        <span :if={@grant && @grant.state == :on} class="text-[11px] text-ok-strong">
          Already on
        </span>
        <div class="flex-1"></div>
        <button
          type="button"
          id={"decline-request-#{@request.id}"}
          phx-click="answer_request"
          phx-value-id={@request.id}
          phx-value-answer="decline"
          class="inline-flex cursor-pointer items-center rounded-md border border-line bg-panel px-3 py-1.5 text-xs font-medium text-ink transition-colors hover:bg-hover"
        >
          Decline
        </button>
      </footer>
    </article>
    """
  end

  defp recipe(nil), do: Recipes.fetch!(:token)
  defp recipe(grant), do: Recipes.fetch!(grant.recipe)

  defp grant_name(grants, id) do
    case grants[id] do
      nil -> "Removed grant"
      grant -> grant.name
    end
  end

  defp decision_words(%Approval{status: :timed_out}), do: "gave up waiting"
  defp decision_words(%Approval{decision: :allow_once}), do: "allowed once"

  defp decision_words(%Approval{decision: {:allow_for, :grant}}),
    do: "allowed similar while the grant is on"

  defp decision_words(%Approval{decision: {:allow_for, 60}}), do: "allowed similar for 1 h"

  defp decision_words(%Approval{decision: {:allow_for, minutes}}),
    do: "allowed similar for #{minutes} min"

  defp decision_words(%Approval{decision: :deny}), do: "denied"
  defp decision_words(%Approval{decision: :deny_and_turn_off}), do: "denied, grant turned off"
  defp decision_words(%Approval{decision: :grant_off}), do: "refused: the grant turned off"
  defp decision_words(%Approval{}), do: "decided"
end
