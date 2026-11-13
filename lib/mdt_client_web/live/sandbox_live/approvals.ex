defmodule MDTClientWeb.SandboxLive.Approvals do
  @moduledoc """
  The approvals page, and the cards it shares with the overview. Three types
  of approval wait in one queue:

    * **activations** - an agent in the VM asks for a grant to be turned on,
      or for access no grant gives yet;
    * **uses** - a request carrying a grant's placeholder, or a connection
      through a network grant, held by the proxy;
    * **commands** - an agent asks to run a command on this machine, as you.
      Drawn in red: no allowance ever covers one. The full card is the only
      place to run it, so the script is always read in full first. A command
      whose output you chose to see first comes back with it, to send or
      keep; while it runs it sits above the queue with a Stop button.

  A card keeps what MDT saw apart from what the agent wrote. Facts sit in a
  plain list; the agent's words sit in a dashed box marked as unverified, so
  a commit message cannot pass for a description of the request. A held
  request shows in full, headers and body, with buttons to copy it as curl,
  as HTTP or just its body.
  """
  use MDTClientWeb, :html

  import MDTClientWeb.SandboxLive.Components

  alias MDTClient.Sandbox.{Approval, Grant, HostCommand, Presets, RequestView}
  alias MDTClient.Sandbox.Instructions

  attr :waiting, :list, required: true
  attr :running, :list, default: []
  attr :history, :list, required: true
  attr :grants, :map, required: true, doc: "grants by id"
  attr :marks, :list, required: true, doc: "`RequestView.marks/1` of every grant"
  attr :hold_seconds, :integer, required: true
  attr :now, DateTime, required: true
  attr :focus, :string, default: nil, doc: "the approval a desktop notification opened"

  def page(assigns) do
    ~H"""
    <.page_header id="approvals-header" title="Approvals">
      <:help>
        Agents asking for a grant or to run a command on this machine, and every use of a grant: requests carrying its placeholder, connections through a network grant. Each waits here until you decide, or gives up on its own.
      </:help>
    </.page_header>

    <div class="space-y-6">
      <.running :if={@running != []} running={@running} now={@now} />

      <section id="waiting-approvals" aria-label="Waiting for a decision" class="space-y-3">
        <h2 class="flex items-center gap-2 text-[11px] font-semibold uppercase tracking-wide text-muted">
          Waiting
          <span class="rounded bg-deep px-1.5 py-0.5 font-mono text-[10px] text-faint">
            {length(@waiting)}
          </span>
        </h2>
        <div :if={@waiting == []} class="rounded-xl border border-dashed border-line">
          <.empty icon="hero-hand-raised" id="no-waiting-approvals">
            Nothing is waiting. Asks from <code class="font-mono">mdt request</code>
            and <code class="font-mono">mdt run</code>, and uses of a grant that is on, show up here.
          </.empty>
        </div>
        <.approval
          :for={approval <- @waiting}
          approval={approval}
          grant={approval.grant_id && @grants[approval.grant_id]}
          marks={@marks}
          hold_seconds={@hold_seconds}
          now={@now}
          focused={approval.id == @focus}
        />
      </section>

      <.card id="approval-history" title="Decided" body_class="">
        <:help>The latest 100 decisions, newest first.</:help>
        <div :if={@history == []}>
          <.empty icon="hero-clock">Decisions you make will be listed here.</.empty>
        </div>
        <ul class="divide-y divide-line-soft">
          <%= for approval <- @history do %>
            <%= if approval.kind == :command do %>
              <.decided_command approval={approval} now={@now} />
            <% else %>
              <li id={"decided-#{approval.id}"} class="flex items-center gap-3 px-4 py-2.5">
                <.decided_badge approval={approval} />
                <div class="min-w-0 flex-1">
                  <p class="truncate text-xs text-ink">{history_title(approval, @grants)}</p>
                  <p class="truncate text-[11px] text-faint">
                    {grant_name(@grants, approval)} · {decision_words(approval)}
                    <span :if={approval.kind == :activation and approval.thread}>· {who(approval)}</span>
                  </p>
                </div>
                <span class="shrink-0 text-[11px] text-faint">
                  <.clock id={"decided-at-#{approval.id}"} since={approval.decided_at} now={@now} />
                </span>
              </li>
            <% end %>
          <% end %>
        </ul>
      </.card>
    </div>
    """
  end

  @doc "One waiting approval, of either type."
  attr :approval, Approval, required: true
  attr :grant, :any, required: true
  attr :marks, :list, default: []
  attr :hold_seconds, :integer, required: true
  attr :now, DateTime, required: true
  attr :compact, :boolean, default: false

  attr :focused, :boolean,
    default: false,
    doc: "ringed and scrolled into view: the one a desktop notification opened"

  def approval(%{approval: %Approval{kind: :activation}} = assigns), do: activation_card(assigns)

  def approval(%{approval: %Approval{kind: :command, stage: :output}} = assigns),
    do: output_card(assigns)

  def approval(%{approval: %Approval{kind: :command}} = assigns), do: command_card(assigns)
  def approval(assigns), do: use_card(assigns)

  ## Uses

  defp use_card(assigns) do
    left = max(DateTime.diff(assigns.approval.deadline, assigns.now, :second), 0)

    assigns =
      assign(assigns,
        left: left,
        fraction: Float.round(min(left / max(assigns.hold_seconds, 1), 1.0), 3)
      )

    ~H"""
    <article
      id={"approval-#{@approval.id}"}
      class={[
        "group/card rounded-xl border border-warn/35 bg-panel shadow-sm shadow-black/5 transition-shadow hover:shadow-md dark:shadow-black/30",
        @focused && "ring-2 ring-accent/70 ring-offset-2 ring-offset-app"
      ]}
      phx-mounted={@focused && JS.dispatch("mdt:reveal")}
    >
      <.drain id={"approval-drain-#{@approval.id}-#{@left}"} left={@left} fraction={@fraction} />

      <header class="flex items-start gap-3 px-4 pb-3 pt-3.5">
        <.grant_tile icon={Presets.icon(@grant)} on={true} />
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
        <.gives_up approval={@approval} now={@now} tone="text-warn-strong" />
      </header>

      <div
        :if={not @compact}
        class={[
          "grid gap-3 px-4 pb-4",
          @approval.claims != [] && "lg:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]"
        ]}
      >
        <.facts id={"approval-facts-#{@approval.id}"} facts={@approval.facts} />
        <.claims id={"approval-claims-#{@approval.id}"} claims={@approval.claims} />
      </div>

      <.request_detail
        :if={not @compact and @approval.request}
        id={@approval.id}
        request={@approval.request}
        marks={@marks}
      />

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

        <.allow_menu
          :if={@approval.pattern}
          id={"allow-similar-#{@approval.id}"}
          approval={@approval}
          scope="similar"
          label="Allow similar"
          grant={@grant}
        >
          Lets uses like this one through without asking:
          <span class="mt-1 block break-all font-mono text-[10px] text-ink">{@approval.pattern}</span>
        </.allow_menu>

        <.allow_menu
          :if={@grant}
          id={"allow-all-#{@approval.id}"}
          approval={@approval}
          scope="all"
          label="Allow every use"
          grant={@grant}
        >
          Lets every use of <span class="font-medium text-ink">{@grant.name}</span>
          through without asking: any {if @approval.kind == :connection,
            do: "connection",
            else: "request"} it covers.
        </.allow_menu>

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

  attr :id, :string, required: true
  attr :approval, Approval, required: true
  attr :scope, :string, required: true
  attr :label, :string, required: true
  attr :grant, :any, required: true
  slot :inner_block, required: true

  defp allow_menu(assigns) do
    ~H"""
    <details id={@id} class="group relative">
      <summary class="inline-flex cursor-pointer list-none items-center gap-1 rounded-md border border-line bg-panel px-2.5 py-1.5 text-xs font-medium text-ink transition-colors hover:bg-hover [&::-webkit-details-marker]:hidden">
        {@label}
        <.icon
          name="hero-chevron-down-micro"
          class="size-3.5 text-muted transition-transform group-open:rotate-180"
        />
      </summary>
      <div class="absolute left-0 top-full z-30 mt-1.5 w-80 rounded-lg border border-line bg-panel p-1.5 shadow-xl shadow-black/20">
        <p class="px-2 pb-1.5 pt-1 text-[11px] leading-4 text-muted">
          {render_slot(@inner_block)}
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
          id={"#{@id}-#{value}"}
          phx-click="decide"
          phx-value-id={@approval.id}
          phx-value-decision={"allow_#{@scope}"}
          phx-value-minutes={value}
          class="flex w-full cursor-pointer items-center gap-2 rounded-md px-2 py-1.5 text-left text-xs text-ink transition-colors hover:bg-hover"
        >
          <.icon name="hero-clock-micro" class="size-3.5 text-faint" />
          {label}
        </button>
      </div>
    </details>
    """
  end

  @doc """
  A held request in full: the request line, every header, and the body MDT
  holds, with buttons that copy it as curl, as HTTP, or just the body.
  Placeholders show as the name of their grant.
  """
  attr :id, :string, required: true
  attr :request, :map, required: true
  attr :marks, :list, required: true

  def request_detail(assigns) do
    request = assigns.request

    assigns =
      assign(assigns,
        url: RequestView.url(request),
        headers: RequestView.headers(request, assigns.marks),
        body: RequestView.body(request),
        curl: RequestView.curl(request, assigns.marks),
        raw: RequestView.raw(request, assigns.marks)
      )

    ~H"""
    <section
      id={"approval-request-#{@id}"}
      aria-label="The full request"
      class="mx-4 mb-4 overflow-hidden rounded-lg border border-line-soft bg-deep/50"
    >
      <div class="flex flex-wrap items-center gap-2 border-b border-line-soft px-3 py-2">
        <.icon name="hero-document-magnifying-glass-micro" class="size-3.5 text-muted" />
        <p class="min-w-0 flex-1 truncate font-mono text-[11px] text-ink" title={@url}>
          <span class="font-semibold">{@request.method}</span> {@url}
        </p>
        <div class="flex items-center gap-1">
          <.copy_button id={"copy-curl-#{@id}"} target={"copy-curl-text-#{@id}"} label="curl" />
          <.copy_button id={"copy-raw-#{@id}"} target={"copy-raw-text-#{@id}"} label="HTTP" />
          <.copy_button
            :if={@body.format not in [:none, :binary]}
            id={"copy-body-#{@id}"}
            target={"copy-body-text-#{@id}"}
            label="Body"
          />
        </div>
      </div>

      <details id={"approval-headers-#{@id}"} class="group/headers border-b border-line-soft">
        <summary class="flex cursor-pointer list-none items-center gap-1.5 px-3 py-1.5 text-[10px] font-semibold uppercase tracking-wide text-muted transition-colors hover:text-ink [&::-webkit-details-marker]:hidden">
          <.icon
            name="hero-chevron-right-micro"
            class="size-3 transition-transform group-open/headers:rotate-90"
          /> Headers
          <span class="rounded bg-panel px-1 font-mono text-[9px] normal-case text-faint">
            {length(@headers)}
          </span>
        </summary>
        <dl class="grid grid-cols-[minmax(0,auto)_minmax(0,1fr)] gap-x-4 gap-y-0.5 px-3 pb-2.5 font-mono text-[11px] leading-5">
          <%= for {{name, segments}, index} <- Enum.with_index(@headers) do %>
            <dt id={"approval-header-#{@id}-#{index}"} class="truncate text-muted">{name}</dt>
            <dd class="break-all text-ink">
              <%= for segment <- segments do %>
                <%= case segment do %>
                  <% {:text, text} -> %>
                    {text}
                  <% {:mark, label} -> %>
                    <span
                      class="inline-flex items-center gap-0.5 rounded border border-accent/30 bg-accent-soft/40 px-1 font-sans text-[10px] font-medium text-accent-strong"
                      title={"The placeholder of #{label}. MDT swaps in the real value only when you allow this."}
                    >
                      <.icon name="hero-key-micro" class="size-2.5" />{label}
                    </span>
                <% end %>
              <% end %>
            </dd>
          <% end %>
        </dl>
      </details>

      <div :if={@body.format != :none} id={"approval-body-#{@id}"}>
        <p class="flex items-center gap-2 px-3 pt-2 text-[10px] font-semibold uppercase tracking-wide text-muted">
          Body
          <span class="rounded bg-panel px-1.5 py-px font-sans text-[9px] font-medium normal-case tracking-normal text-faint">
            {format_word(@body.format)} · {body_size(@body)}
          </span>
        </p>
        <pre class={[
          "max-h-80 overflow-auto whitespace-pre-wrap break-all px-3 pb-3 pt-1.5 font-mono text-[11px] leading-5",
          if(@body.format == :binary, do: "text-muted", else: "text-ink")
        ]}>{@body.text}</pre>
      </div>
      <p :if={@body.format == :none} class="px-3 py-2 text-[11px] text-faint">No body.</p>

      <pre id={"copy-curl-text-#{@id}"} hidden>{@curl}</pre>
      <pre id={"copy-raw-text-#{@id}"} hidden>{@raw}</pre>
      <pre :if={@body.format not in [:none, :binary]} id={"copy-body-text-#{@id}"} hidden>{@body.text}</pre>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :target, :string, required: true
  attr :label, :string, required: true

  defp copy_button(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      phx-hook="CopyText"
      phx-update="ignore"
      data-copy-target={@target}
      title={"Copy as #{@label}"}
      class="inline-flex cursor-pointer items-center gap-1 rounded-md border border-line bg-panel px-2 py-1 text-[11px] font-medium text-ink transition-colors hover:border-accent/50 hover:text-accent active:scale-[0.97]"
    >
      <.icon name="hero-clipboard-document-micro" class="size-3.5 text-muted" />
      <span data-copy-label>{@label}</span>
    </button>
    """
  end

  ## Commands

  defp command_card(assigns) do
    approval = assigns.approval
    total = max(DateTime.diff(approval.deadline, approval.requested_at, :second), 1)
    left = max(DateTime.diff(approval.deadline, assigns.now, :second), 0)

    assigns =
      assign(assigns,
        left: left,
        fraction: Float.round(min(left / total, 1.0), 3),
        form: to_form(%{"id" => approval.id, "output" => "send"}, as: :run)
      )

    ~H"""
    <article
      id={"approval-#{@approval.id}"}
      class={[
        "rounded-xl border border-bad/45 bg-panel shadow-sm shadow-black/5 transition-shadow hover:shadow-md dark:shadow-black/30",
        @focused && "ring-2 ring-accent/70 ring-offset-2 ring-offset-app"
      ]}
      phx-mounted={@focused && JS.dispatch("mdt:reveal")}
    >
      <.drain
        id={"approval-drain-#{@approval.id}-#{@left}"}
        left={@left}
        fraction={@fraction}
        tone="bad"
      />

      <header class="flex items-start gap-3 px-4 pb-3 pt-3.5">
        <span class="flex size-8 shrink-0 items-center justify-center rounded-lg border border-bad/35 bg-bad-soft/40 text-bad">
          <.icon name="hero-command-line" class="size-4" />
        </span>
        <div class="min-w-0 flex-1">
          <div class="flex flex-wrap items-center gap-x-2 gap-y-1 text-[11px] text-muted">
            <span class="font-medium text-ink/80">{@approval.agent}</span>
            <span>in the VM</span>
            <span class="text-faint">·</span>
            <span class="font-medium text-bad">Asks to run a command on this machine</span>
            <span
              :if={@approval.retries > 0}
              id={"approval-retries-#{@approval.id}"}
              title="The agent asked again while this waited."
              class="rounded bg-deep px-1.5 py-0.5 font-mono text-[10px] text-faint"
            >
              asked {@approval.retries + 1} times
            </span>
          </div>
          <.thread id={"approval-thread-#{@approval.id}"} thread={@approval.thread} />
          <h3 class="mt-0.5 break-all font-mono text-[13px] font-semibold leading-5 text-ink">
            {@approval.title}
          </h3>
          <p class="mt-0.5 break-all font-mono text-[11px] text-muted">
            in {@approval.dir} · at most {HostCommand.seconds_words(@approval.timeout)}
          </p>
        </div>
        <.gives_up approval={@approval} now={@now} tone="text-bad" />
      </header>

      <div :if={not @compact} class="space-y-3 px-4 pb-4">
        <.script id={@approval.id} script={@approval.script} />

        <div class={[
          "grid gap-3",
          (@approval.hints != [] or @approval.claims != []) &&
            "lg:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]"
        ]}>
          <.facts id={"approval-facts-#{@approval.id}"} facts={@approval.facts} />
          <div class="space-y-3">
            <.hints id={"approval-hints-#{@approval.id}"} hints={@approval.hints} />
            <.claims id={"approval-claims-#{@approval.id}"} claims={@approval.claims} />
          </div>
        </div>
      </div>

      <footer class="rounded-b-xl border-t border-line-soft bg-deep/40 px-4 py-2.5">
        <%= if @compact do %>
          <div class="flex flex-wrap items-center gap-2">
            <.link
              id={"review-command-#{@approval.id}"}
              patch={~p"/tools/sandbox/approvals"}
              class="inline-flex items-center gap-1.5 rounded-md border border-bad/40 bg-panel px-3 py-1.5 text-xs font-semibold text-bad transition-colors hover:bg-bad-soft/30"
            >
              <.icon name="hero-document-magnifying-glass-micro" class="size-3.5" />
              Read it in full to decide
            </.link>
            <div class="flex-1"></div>
            <.decline_button approval={@approval} />
          </div>
        <% else %>
          <.form
            for={@form}
            id={"command-form-#{@approval.id}"}
            phx-submit="run_command"
            class="flex flex-wrap items-center gap-x-3 gap-y-2"
          >
            <input type="hidden" name={@form[:id].name} value={@approval.id} />
            <.pills
              id={"command-output-#{@approval.id}"}
              name={@form[:output].name}
              options={[{"send", "Output to the agent"}, {"review", "Show me the output first"}]}
              checked="send"
              tone="bad"
            />
            <button
              type="submit"
              id={"run-command-#{@approval.id}"}
              class="inline-flex cursor-pointer items-center gap-1.5 rounded-md bg-bad px-3 py-1.5 text-xs font-semibold text-white transition-all hover:brightness-110 active:brightness-95 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-bad"
            >
              <.icon name="hero-play-micro" class="size-3.5" /> Run once, as you
            </button>
            <div class="flex-1"></div>
            <.decline_button approval={@approval} />
          </.form>
          <p class="mt-2 flex items-center gap-1.5 text-[10px] leading-4 text-faint">
            It runs outside the VM, with your files, keys and network.
            <.help id={"command-help-#{@approval.id}"} label="About host commands">
              No allowance ever covers a command: each one asks, and the full card is the only place to run it.
            </.help>
          </p>
        <% end %>
      </footer>
    </article>
    """
  end

  defp output_card(assigns) do
    approval = assigns.approval
    total = max(DateTime.diff(approval.deadline, approval.run.finished_at, :second), 1)
    left = max(DateTime.diff(approval.deadline, assigns.now, :second), 0)

    assigns =
      assign(assigns,
        left: left,
        fraction: Float.round(min(left / total, 1.0), 3),
        run: approval.run
      )

    ~H"""
    <article
      id={"approval-#{@approval.id}"}
      class={[
        "rounded-xl border border-bad/45 bg-panel shadow-sm shadow-black/5 transition-shadow hover:shadow-md dark:shadow-black/30",
        @focused && "ring-2 ring-accent/70 ring-offset-2 ring-offset-app"
      ]}
      phx-mounted={@focused && JS.dispatch("mdt:reveal")}
    >
      <.drain
        id={"approval-drain-#{@approval.id}-#{@left}"}
        left={@left}
        fraction={@fraction}
        tone="bad"
      />

      <header class="flex items-start gap-3 px-4 pb-3 pt-3.5">
        <span class="flex size-8 shrink-0 items-center justify-center rounded-lg border border-bad/35 bg-bad-soft/40 text-bad">
          <.icon name="hero-document-text" class="size-4" />
        </span>
        <div class="min-w-0 flex-1">
          <div class="flex flex-wrap items-center gap-x-2 gap-y-1 text-[11px] text-muted">
            <span class="font-medium text-ink/80">{@approval.agent}</span>
            <span class="text-faint">·</span>
            <span>Ran on this machine; its output waits for you</span>
          </div>
          <.thread id={"approval-thread-#{@approval.id}"} thread={@approval.thread} />
          <h3 class="mt-0.5 break-all font-mono text-[13px] font-semibold leading-5 text-ink">
            {@approval.title}
          </h3>
          <p class="mt-0.5 text-[11px] text-muted">
            <.exit_status id={"output-exit-#{@approval.id}"} run={@run} /> · {run_words(@run)}
          </p>
        </div>
        <.gives_up approval={@approval} now={@now} tone="text-bad" />
      </header>

      <div :if={not @compact} class="space-y-3 px-4 pb-4">
        <.output id={@approval.id} run={@run} />
        <details id={"output-script-#{@approval.id}"} class="group/script">
          <summary class="flex cursor-pointer list-none items-center gap-1.5 text-[10px] font-semibold uppercase tracking-wide text-muted transition-colors hover:text-ink [&::-webkit-details-marker]:hidden">
            <.icon
              name="hero-chevron-right-micro"
              class="size-3 transition-transform group-open/script:rotate-90"
            /> The command
          </summary>
          <div class="mt-2"><.script id={"#{@approval.id}-ran"} script={@approval.script} /></div>
        </details>
      </div>

      <footer class="flex flex-wrap items-center gap-2 rounded-b-xl border-t border-line-soft bg-deep/40 px-4 py-2.5">
        <%= if @compact do %>
          <.link
            id={"review-output-#{@approval.id}"}
            patch={~p"/tools/sandbox/approvals"}
            class="inline-flex items-center gap-1.5 rounded-md border border-bad/40 bg-panel px-3 py-1.5 text-xs font-semibold text-bad transition-colors hover:bg-bad-soft/30"
          >
            <.icon name="hero-document-magnifying-glass-micro" class="size-3.5" />
            Read the output to decide
          </.link>
        <% else %>
          <button
            type="button"
            id={"send-output-#{@approval.id}"}
            phx-click="decide"
            phx-value-id={@approval.id}
            phx-value-decision="send_output"
            class="inline-flex cursor-pointer items-center gap-1.5 rounded-md bg-ok px-3 py-1.5 text-xs font-semibold text-deep transition-all hover:brightness-110 active:brightness-95"
          >
            <.icon name="hero-paper-airplane-micro" class="size-3.5" /> Send it to the agent
          </button>
        <% end %>
        <div class="flex-1"></div>
        <button
          type="button"
          id={"keep-output-#{@approval.id}"}
          phx-click="decide"
          phx-value-id={@approval.id}
          phx-value-decision="keep_output"
          class="inline-flex cursor-pointer items-center rounded-md border border-line bg-panel px-3 py-1.5 text-xs font-medium text-ink transition-colors hover:border-bad/50 hover:bg-bad-soft/40 hover:text-bad"
        >
          Keep it
        </button>
      </footer>
    </article>
    """
  end

  @doc "Commands running on this machine, each with a Stop button."
  attr :running, :list, required: true
  attr :now, DateTime, required: true

  def running(assigns) do
    ~H"""
    <section id="running-commands" aria-label="Running on this machine" class="space-y-2">
      <h2 class="flex items-center gap-2 text-[11px] font-semibold uppercase tracking-wide text-muted">
        <span class="relative flex size-2">
          <span class="absolute inline-flex size-full animate-ping rounded-full bg-bad/60"></span>
          <span class="relative inline-flex size-2 rounded-full bg-bad"></span>
        </span>
        Running on this machine
      </h2>
      <div
        :for={approval <- @running}
        id={"running-#{approval.id}"}
        class="flex items-center gap-3 rounded-xl border border-bad/30 bg-panel px-4 py-2.5"
      >
        <.icon name="hero-command-line" class="size-4 shrink-0 text-bad" />
        <div class="min-w-0 flex-1">
          <p class="truncate font-mono text-xs text-ink" title={approval.script}>
            {approval.title}
          </p>
          <p class="truncate text-[11px] text-faint">
            {who(approval)} · in {approval.dir} · output {if approval.run.output_to == :send,
              do: "to the agent",
              else: "to you first"}
            <span :if={approval.run.stopped} class="text-bad">· stopping…</span>
          </p>
        </div>
        <span class="shrink-0 text-[11px] text-muted">
          started
          <.clock id={"running-for-#{approval.id}"} since={approval.run.started_at} now={@now} />
          · limit {HostCommand.seconds_words(approval.timeout)}
        </span>
        <button
          type="button"
          id={"stop-command-#{approval.id}"}
          phx-click="stop_command"
          phx-value-id={approval.id}
          disabled={approval.run.stopped}
          class="inline-flex cursor-pointer items-center gap-1 rounded-md border border-bad/40 px-2.5 py-1 text-xs font-medium text-bad transition-colors hover:bg-bad-soft/40 disabled:cursor-default disabled:opacity-50"
        >
          <.icon name="hero-stop-micro" class="size-3.5" /> Stop
        </button>
      </div>
    </section>
    """
  end

  attr :approval, Approval, required: true
  attr :now, DateTime, required: true

  defp decided_command(assigns) do
    ~H"""
    <li id={"decided-#{@approval.id}"}>
      <details class="group/decided">
        <summary class="flex cursor-pointer list-none items-center gap-3 px-4 py-2.5 transition-colors hover:bg-hover/40 [&::-webkit-details-marker]:hidden">
          <.decided_badge approval={@approval} />
          <div class="min-w-0 flex-1">
            <p class="truncate font-mono text-xs text-ink">{@approval.title}</p>
            <p class="truncate text-[11px] text-faint">
              {who(@approval)} · on this machine · {decision_words(@approval)}
            </p>
          </div>
          <span class="shrink-0 text-[11px] text-faint">
            <.clock id={"decided-at-#{@approval.id}"} since={@approval.decided_at} now={@now} />
          </span>
          <.icon
            name="hero-chevron-down-micro"
            class="size-3.5 shrink-0 text-faint transition-transform group-open/decided:rotate-180"
          />
        </summary>
        <div class="space-y-3 px-4 pb-4">
          <.script id={"decided-#{@approval.id}"} script={@approval.script} />
          <p class="text-[11px] text-muted">
            In <span class="font-mono">{@approval.dir}</span>
            <span :if={@approval.reason}>
              · the agent said: <span class="italic">“{@approval.reason}”</span>
            </span>
          </p>
          <.output
            :if={@approval.run && @approval.run.state == :done}
            id={"decided-#{@approval.id}"}
            run={@approval.run}
          />
        </div>
      </details>
    </li>
    """
  end

  attr :id, :string, required: true
  attr :script, :string, required: true

  defp script(assigns) do
    ~H"""
    <section
      id={"command-script-#{@id}"}
      aria-label="The command"
      class="overflow-hidden rounded-lg border border-bad/25 bg-deep/60"
    >
      <div class="flex items-center gap-2 border-b border-line-soft px-3 py-1.5">
        <.icon name="hero-command-line-micro" class="size-3.5 text-muted" />
        <p class="flex-1 text-[10px] font-semibold uppercase tracking-wide text-muted">
          Exactly what runs, with bash -lc
        </p>
        <.copy_button id={"copy-script-#{@id}"} target={"copy-script-text-#{@id}"} label="Script" />
      </div>
      <pre
        id={"command-script-text-#{@id}"}
        class="max-h-96 overflow-auto whitespace-pre-wrap break-all px-3 py-2.5 font-mono text-[12px] leading-5 text-ink"
      >{@script}</pre>
      <pre id={"copy-script-text-#{@id}"} hidden>{@script}</pre>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :run, :map, required: true

  defp output(assigns) do
    ~H"""
    <section
      id={"command-output-#{@id}"}
      aria-label="Its output"
      class="overflow-hidden rounded-lg border border-line-soft bg-deep/60"
    >
      <div class="flex items-center gap-2 border-b border-line-soft px-3 py-1.5">
        <.icon name="hero-document-text-micro" class="size-3.5 text-muted" />
        <p class="flex-1 text-[10px] font-semibold uppercase tracking-wide text-muted">
          Output
          <span class="ml-1 rounded bg-panel px-1.5 py-px font-sans text-[9px] font-medium normal-case tracking-normal text-faint">
            <.exit_status id={"exit-#{@id}"} run={@run} />
            · {bytes(@run.bytes)}{if @run.cut > 0,
              do: ", #{bytes(@run.cut)} cut from the middle"}
          </span>
        </p>
        <.copy_button
          :if={@run.output != ""}
          id={"copy-output-#{@id}"}
          target={"copy-output-text-#{@id}"}
          label="Output"
        />
      </div>
      <p :if={@run.error} class="px-3 py-2.5 text-xs text-bad">{@run.error}</p>
      <p :if={!@run.error and @run.output == ""} class="px-3 py-2.5 text-[11px] text-faint">
        It printed nothing.
      </p>
      <pre
        :if={@run.output != ""}
        id={"command-output-text-#{@id}"}
        class="max-h-96 overflow-auto whitespace-pre-wrap break-all px-3 py-2.5 font-mono text-[11px] leading-5 text-ink"
      >{@run.output}</pre>
      <pre :if={@run.output != ""} id={"copy-output-text-#{@id}"} hidden>{@run.output}</pre>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :run, :map, required: true

  defp exit_status(assigns) do
    ~H"""
    <span
      id={@id}
      class={[
        "font-mono font-semibold",
        if(@run.exit == 0, do: "text-ok-strong", else: "text-bad")
      ]}
    >
      {cond do
        @run.error -> "didn't start"
        @run.stopped -> "stopped (exit #{@run.exit})"
        @run.timed_out -> "hit its limit (exit #{@run.exit})"
        true -> "exit #{@run.exit}"
      end}
    </span>
    """
  end

  attr :id, :string, required: true
  attr :hints, :list, required: true

  defp hints(assigns) do
    ~H"""
    <div
      :if={@hints != []}
      id={@id}
      class="rounded-lg border border-warn/35 bg-warn-soft/25 p-3"
    >
      <p class="mb-1.5 flex items-center gap-1.5 text-[10px] font-semibold uppercase tracking-wide text-warn-strong">
        <.icon name="hero-exclamation-triangle-micro" class="size-3" /> Worth a second look
      </p>
      <ul class="space-y-1">
        <li :for={hint <- @hints} class="flex gap-1.5 text-xs leading-5 text-ink">
          <span class="text-warn-strong">•</span><span>{hint}</span>
        </li>
      </ul>
      <p class="mt-1.5 text-[10px] leading-4 text-faint">
        MDT's guesses from the text alone, not a review: a command can do anything its text allows.
      </p>
    </div>
    """
  end

  defp run_words(run) do
    seconds = DateTime.diff(run.finished_at, run.started_at)
    "took #{HostCommand.seconds_words(seconds)} · #{bytes(run.bytes)} of output"
  end

  ## Activations

  defp activation_card(assigns) do
    approval = assigns.approval
    total = max(DateTime.diff(approval.deadline, approval.requested_at, :second), 1)
    left = max(DateTime.diff(approval.deadline, assigns.now, :second), 0)

    durations =
      Enum.uniq_by(
        [{approval.minutes, "#{minutes_words(approval.minutes)} (asked)"}] ++
          [{15, "15 min"}, {60, "1 h"}, {240, "4 h"}, {"until_off", "Until off"}],
        &elem(&1, 0)
      )

    assigns =
      assign(assigns,
        left: left,
        fraction: Float.round(min(left / total, 1.0), 3),
        durations: durations,
        form: to_form(%{"id" => approval.id}, as: :ask)
      )

    ~H"""
    <article
      id={"approval-#{@approval.id}"}
      class={[
        "rounded-xl border border-violet/35 bg-panel shadow-sm shadow-black/5 transition-shadow hover:shadow-md dark:shadow-black/30",
        @focused && "ring-2 ring-accent/70 ring-offset-2 ring-offset-app"
      ]}
      phx-mounted={@focused && JS.dispatch("mdt:reveal")}
    >
      <.drain
        id={"approval-drain-#{@approval.id}-#{@left}"}
        left={@left}
        fraction={@fraction}
        tone="violet"
      />

      <header class="flex items-start gap-3 px-4 pb-3 pt-3.5">
        <span class="flex size-8 shrink-0 items-center justify-center rounded-lg border border-violet/30 bg-violet/10 text-violet-strong">
          <.icon name={if @grant, do: Presets.icon(@grant), else: "hero-sparkles"} class="size-4" />
        </span>
        <div class="min-w-0 flex-1">
          <div class="flex flex-wrap items-center gap-x-2 gap-y-1 text-[11px] text-muted">
            <span class="font-medium text-ink/80">{@approval.agent}</span>
            <span>in the VM</span>
            <span class="text-faint">·</span>
            <span>Asks for access</span>
            <span
              :if={@approval.retries > 0}
              id={"approval-retries-#{@approval.id}"}
              title="The agent asked again while this waited."
              class="rounded bg-deep px-1.5 py-0.5 font-mono text-[10px] text-faint"
            >
              asked {@approval.retries + 1} times
            </span>
          </div>
          <.thread id={"approval-thread-#{@approval.id}"} thread={@approval.thread} />
          <h3 class="mt-0.5 text-sm font-semibold leading-5 text-ink">
            <%= if @grant do %>
              Turn on {@grant.name} for {minutes_words(@approval.minutes)}
            <% else %>
              Access you haven't set up
            <% end %>
          </h3>
          <p :if={@grant} class="mt-0.5 text-xs text-muted">{@grant.purpose}</p>
        </div>
        <.gives_up approval={@approval} now={@now} tone="text-violet-strong" />
      </header>

      <div
        :if={not @compact}
        class="grid gap-3 px-4 pb-4 lg:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]"
      >
        <div :if={@grant} id={"approval-facts-#{@approval.id}"}>
          <p class="mb-1.5 flex items-center gap-1.5 text-[10px] font-semibold uppercase tracking-wide text-muted">
            <.icon name="hero-key-micro" class="size-3" /> The grant
          </p>
          <dl class="grid grid-cols-[auto_minmax(0,1fr)] gap-x-4 gap-y-1 text-xs">
            <dt class="text-muted">Type</dt>
            <dd class="text-ink">{Presets.kind_name(@grant.kind)}</dd>
            <dt class="text-muted">The VM gets</dt>
            <dd class="break-words text-xs leading-5 text-ink">
              {Instructions.usage(@grant) |> String.replace_prefix("use: ", "")}
            </dd>
            <dt :if={Grant.exposes_value?(@grant)} class="text-muted">Careful</dt>
            <dd :if={Grant.exposes_value?(@grant)} class="text-xs text-warn-strong">
              The VM holds the real value while on; copies survive turning it off.
            </dd>
          </dl>
        </div>
        <div :if={is_nil(@grant)} id={"approval-need-#{@approval.id}"}>
          <p class="mb-1.5 flex items-center gap-1.5 text-[10px] font-semibold uppercase tracking-wide text-muted">
            <.icon name="hero-puzzle-piece-micro" class="size-3" /> What it needs
          </p>
          <p class="max-h-48 overflow-y-auto overscroll-contain break-words rounded-lg border border-line-soft bg-deep/50 px-3 py-2 text-xs leading-5 text-ink">
            {@approval.need}
          </p>
          <p class="mt-1.5 text-[11px] leading-4 text-faint">
            No grant meets this yet. Set one up and it turns on for {minutes_words(@approval.minutes)}.
          </p>
        </div>
        <.claims id={"approval-claims-#{@approval.id}"} claims={@approval.claims} />
      </div>

      <footer class="rounded-b-xl border-t border-line-soft bg-deep/40 px-4 py-2.5">
        <%= if @grant do %>
          <.form
            for={@form}
            id={"activation-form-#{@approval.id}"}
            phx-submit="turn_on_ask"
            class="flex flex-wrap items-center gap-x-3 gap-y-2"
          >
            <input type="hidden" name={@form[:id].name} value={@approval.id} />
            <.pills
              id={"activation-minutes-#{@approval.id}"}
              name={@form[:minutes].name}
              options={@durations}
              checked={@approval.minutes}
            />
            <.pills
              id={"activation-uses-#{@approval.id}"}
              name={@form[:uses].name}
              options={[{"ask", "Ask each use"}, {"all", "Allow every use"}]}
              checked="ask"
            />
            <button
              type="submit"
              id={"turn-on-ask-#{@approval.id}"}
              class="inline-flex cursor-pointer items-center gap-1.5 rounded-md bg-violet px-3 py-1.5 text-xs font-semibold text-deep transition-all hover:brightness-110 active:brightness-95"
            >
              <.icon name="hero-bolt-micro" class="size-3.5" /> Turn on
            </button>
            <div class="flex-1"></div>
            <.decline_button approval={@approval} />
          </.form>
        <% else %>
          <div class="flex flex-wrap items-center gap-2">
            <button
              type="button"
              id={"setup-ask-#{@approval.id}"}
              phx-click="open_add_grant"
              phx-value-approval={@approval.id}
              class="inline-flex cursor-pointer items-center gap-1.5 rounded-md bg-violet px-3 py-1.5 text-xs font-semibold text-deep transition-all hover:brightness-110 active:brightness-95"
            >
              <.icon name="hero-plus-micro" class="size-3.5" /> Set it up…
            </button>
            <div class="flex-1"></div>
            <.decline_button approval={@approval} />
          </div>
        <% end %>
      </footer>
    </article>
    """
  end

  attr :approval, Approval, required: true

  defp decline_button(assigns) do
    ~H"""
    <button
      type="button"
      id={"decline-ask-#{@approval.id}"}
      phx-click="decide"
      phx-value-id={@approval.id}
      phx-value-decision="decline"
      class="inline-flex cursor-pointer items-center rounded-md border border-line bg-panel px-3 py-1.5 text-xs font-medium text-ink transition-colors hover:border-bad/50 hover:bg-bad-soft/40 hover:text-bad"
    >
      Decline
    </button>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :options, :list, required: true
  attr :checked, :any, required: true
  attr :tone, :string, default: "violet"

  # Radio buttons drawn as a segmented control: plain form inputs, so the
  # card needs no state on the server.
  defp pills(assigns) do
    ~H"""
    <div
      id={@id}
      role="radiogroup"
      class="inline-flex items-center gap-0.5 rounded-md border border-line bg-panel p-0.5"
    >
      <label :for={{value, label} <- @options} class="relative">
        <input
          type="radio"
          name={@name}
          id={"#{@id}-#{value}"}
          value={value}
          checked={to_string(value) == to_string(@checked)}
          class="peer sr-only"
        />
        <span class={[
          "block cursor-pointer rounded px-2 py-1 text-[11px] font-medium text-muted transition-colors hover:bg-hover hover:text-ink peer-focus-visible:outline-2",
          if(@tone == "bad",
            do: "peer-checked:bg-bad-soft/50 peer-checked:text-bad peer-focus-visible:outline-bad",
            else:
              "peer-checked:bg-violet/15 peer-checked:text-violet-strong peer-focus-visible:outline-violet"
          )
        ]}>
          {label}
        </span>
      </label>
    </div>
    """
  end

  ## Parts

  attr :id, :string, required: true
  attr :left, :integer, required: true
  attr :fraction, :float, required: true
  attr :tone, :string, default: "warn"

  defp drain(assigns) do
    ~H"""
    <div class={[
      "h-0.5 overflow-hidden rounded-t-xl",
      case @tone do
        "violet" -> "bg-violet/15"
        "bad" -> "bg-bad/15"
        _ -> "bg-warn/15"
      end
    ]}>
      <div
        id={@id}
        class={[
          "sandbox-drain h-full origin-left",
          case @tone do
            "violet" -> "bg-violet"
            "bad" -> "bg-bad"
            _ -> "bg-warn"
          end
        ]}
        style={"--drain-from: #{@fraction}; animation-duration: #{@left}s"}
      >
      </div>
    </div>
    """
  end

  attr :approval, Approval, required: true
  attr :now, DateTime, required: true
  attr :tone, :string, required: true

  defp gives_up(assigns) do
    ~H"""
    <div class="shrink-0 text-right">
      <p class="text-[10px] font-medium uppercase tracking-wide text-faint">Gives up in</p>
      <.clock
        id={"approval-left-#{@approval.id}"}
        deadline={@approval.deadline}
        done="0:00"
        now={@now}
        class={["font-mono text-sm font-semibold", @tone]}
      />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :facts, :list, required: true

  defp facts(assigns) do
    ~H"""
    <div id={@id}>
      <p class="mb-1.5 flex items-center gap-1.5 text-[10px] font-semibold uppercase tracking-wide text-muted">
        <.icon name="hero-eye-micro" class="size-3" /> What MDT saw
      </p>
      <dl class="grid grid-cols-[auto_minmax(0,1fr)] gap-x-4 gap-y-1 text-xs">
        <%= for {label, value} <- @facts do %>
          <dt class="text-muted">{label}</dt>
          <dd class="break-words font-mono text-[11px] leading-5 text-ink">{value}</dd>
        <% end %>
      </dl>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :claims, :list, required: true

  defp claims(assigns) do
    ~H"""
    <div
      :if={@claims != []}
      id={@id}
      class="rounded-lg border border-dashed border-line bg-deep/60 p-3"
    >
      <p class="mb-1.5 flex items-center gap-1.5 text-[10px] font-semibold uppercase tracking-wide text-muted">
        <.icon name="hero-chat-bubble-left-ellipsis-micro" class="size-3" /> The agent says
        <span class="rounded border border-line px-1 py-px text-[9px] font-medium normal-case tracking-normal text-faint">
          not verified
        </span>
      </p>
      <ul
        id={"#{@id}-list"}
        tabindex="0"
        aria-label="What the agent says"
        class="-mr-1.5 max-h-56 space-y-1.5 overflow-y-auto overscroll-contain pr-1.5 focus-visible:outline-2 focus-visible:outline-accent"
      >
        <li :for={{label, text} <- @claims} class="text-xs leading-5">
          <span class="mr-1.5 text-[10px] uppercase tracking-wide text-faint">{label}</span>
          <span class="whitespace-pre-wrap break-words italic text-muted">“{text}”</span>
        </li>
      </ul>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :thread, :map, default: nil

  # The thread an ask came from, as the agent's process tells it, so asks
  # from several threads can be told apart. A claim, like the agent's name.
  defp thread(assigns) do
    ~H"""
    <p
      :if={@thread}
      id={@id}
      title={"The thread that asked, as its process says (not verified)" <> if(@thread.id, do: "\nThread id: " <> @thread.id, else: "") <> if(@thread.folder, do: "\nFolder: " <> @thread.folder, else: "")}
      class="mt-0.5 flex min-w-0 flex-wrap items-center gap-x-3 gap-y-0.5 text-[11px] text-muted"
    >
      <span
        :if={@thread.title || @thread.id}
        id={"#{@id}-title"}
        class="inline-flex min-w-0 max-w-full items-center gap-1"
      >
        <.icon name="hero-chat-bubble-left-right-micro" class="size-3 shrink-0 text-faint" />
        <span class="truncate">{@thread.title || "thread " <> String.slice(@thread.id, 0, 8)}</span>
      </span>
      <span
        :if={@thread.folder}
        id={"#{@id}-folder"}
        class="inline-flex min-w-0 max-w-full items-center gap-1"
      >
        <.icon name="hero-folder-micro" class="size-3 shrink-0 text-faint" />
        <span class="truncate font-mono">{Approval.short_folder(@thread.folder)}</span>
      </span>
    </p>
    """
  end

  # The agent and the thread it asked from, for one-line rows.
  defp who(%Approval{} = approval) do
    case Approval.asked_from(approval) do
      nil -> approval.agent
      from -> "#{approval.agent} #{from}"
    end
  end

  attr :approval, Approval, required: true

  defp decided_badge(%{approval: %Approval{kind: :activation}} = assigns) do
    ~H"""
    <span class={[
      "inline-flex w-[4.5rem] shrink-0 items-center justify-center rounded px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide",
      case @approval.status do
        :allowed -> "bg-violet/15 text-violet-strong"
        :timed_out -> "bg-warn-soft/60 text-warn-strong"
        _ -> "bg-hover text-muted"
      end
    ]}>
      {case @approval.status do
        :allowed -> "Turned on"
        :timed_out -> "Gave up"
        _ -> "Declined"
      end}
    </span>
    """
  end

  defp decided_badge(%{approval: %Approval{kind: :command}} = assigns) do
    ~H"""
    <span class={[
      "inline-flex w-[4.5rem] shrink-0 items-center justify-center rounded px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide",
      cond do
        @approval.run && @approval.run.state == :done -> "bg-bad-soft/50 text-bad"
        @approval.status == :timed_out -> "bg-warn-soft/60 text-warn-strong"
        true -> "bg-hover text-muted"
      end
    ]}>
      {cond do
        @approval.run && @approval.run.state == :done -> "Ran"
        @approval.status == :timed_out -> "Gave up"
        true -> "Declined"
      end}
    </span>
    """
  end

  defp decided_badge(assigns) do
    ~H"""
    <.outcome_badge outcome={@approval.status} />
    """
  end

  ## Words

  defp history_title(%Approval{kind: :activation} = approval, grants) do
    case approval.grant_id && grants[approval.grant_id] do
      %Grant{name: name} -> "#{approval.agent} asked for #{name}"
      nil -> "#{approval.agent} asked for: #{approval.need || "a grant since removed"}"
    end
  end

  defp history_title(approval, _grants), do: approval.title

  defp grant_name(_grants, %Approval{kind: :activation, grant_id: nil}), do: "No grant yet"

  defp grant_name(grants, %Approval{grant_id: id}) do
    case grants[id] do
      nil -> "Removed grant"
      grant -> grant.name
    end
  end

  @doc "What a decision did, in a few words."
  def decision_words(%Approval{kind: :command, status: :timed_out, stage: :output, run: run}),
    do: "#{exit_words(run)}, output kept: not released in time"

  def decision_words(%Approval{kind: :command, decision: {:run, to}, run: run}),
    do: "#{exit_words(run)}, output #{if to == :send, do: "sent to the agent", else: "to you"}"

  def decision_words(%Approval{kind: :command, decision: :send_output, run: run}),
    do: "#{exit_words(run)}, you sent the output"

  def decision_words(%Approval{kind: :command, decision: :keep_output, run: run}),
    do: "#{exit_words(run)}, you kept the output"

  def decision_words(%Approval{status: :timed_out}), do: "gave up waiting"
  def decision_words(%Approval{decision: :allow_once}), do: "allowed once"

  def decision_words(%Approval{decision: {:allow, :similar, duration}}),
    do: "allowed similar #{duration_words(duration)}"

  def decision_words(%Approval{decision: {:allow, :all, duration}}),
    do: "allowed every use #{duration_words(duration)}"

  def decision_words(%Approval{decision: :deny}), do: "denied"
  def decision_words(%Approval{decision: :deny_and_turn_off}), do: "denied, grant turned off"
  def decision_words(%Approval{decision: :grant_off}), do: "refused: the grant turned off"
  def decision_words(%Approval{decision: :decline}), do: "declined"

  def decision_words(%Approval{decision: {:turn_on, minutes, uses}}) do
    "turned on #{duration_words(minutes)}" <>
      if(uses == :all, do: ", every use allowed", else: ", each use asks")
  end

  def decision_words(%Approval{decision: {:set_up, _id}, minutes: minutes}),
    do: "set up and turned on for #{minutes_words(minutes)}"

  def decision_words(%Approval{}), do: "decided"

  defp exit_words(%{error: error}) when is_binary(error), do: "didn't start"
  defp exit_words(%{state: :running}), do: "running"
  defp exit_words(%{stopped: true, exit: exit}), do: "stopped (exit #{exit})"
  defp exit_words(%{timed_out: true, exit: exit}), do: "hit its limit (exit #{exit})"
  defp exit_words(%{exit: exit}), do: "exit #{exit}"

  defp duration_words(:grant), do: "while the grant is on"
  defp duration_words(:until_off), do: "until turned off"
  defp duration_words(minutes), do: "for " <> minutes_words(minutes)

  defp minutes_words(60), do: "1 h"
  defp minutes_words(minutes) when rem(minutes, 60) == 0, do: "#{div(minutes, 60)} h"
  defp minutes_words(minutes), do: "#{minutes} min"

  defp format_word(:json), do: "JSON"
  defp format_word(:graphql), do: "GraphQL"
  defp format_word(:form), do: "Form"
  defp format_word(:git), do: "git"
  defp format_word(:text), do: "Text"
  defp format_word(:binary), do: "Binary"

  defp body_size(%{complete?: true, kept: kept}), do: bytes(kept)

  defp body_size(%{size: size, kept: kept}) when is_integer(size),
    do: "first #{bytes(kept)} of #{bytes(size)}"

  defp body_size(%{kept: kept}), do: "first #{bytes(kept)}"
end
