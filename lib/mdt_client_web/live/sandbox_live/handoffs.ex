defmodule MDTClientWeb.SandboxLive.Handoffs do
  @moduledoc """
  The handoffs page: finished work agents offer back from their worktrees,
  listed the way a code host lists pull requests.

  Opening one shows the conversation (the agent's description, its thread,
  what happened since, and the accept box), its commits, and the files it
  changes. A handoff is accepted onto its target branch, as the agent's
  commits or as uncommitted changes, only into a worktree with no pending
  work; it can also be saved as a branch to look at, sent back to its
  thread with a note, or closed.
  """
  use MDTClientWeb, :html

  import MDTClientWeb.SandboxLive.Components

  alias MDTClient.Git.FileDiff
  alias MDTClient.Sandbox.{Handoff, Handoffs}

  attr :handoffs, :list, required: true
  attr :filter, :string, required: true
  attr :view, :any, required: true, doc: "the handoff open, with what was worked out, or nil"
  attr :tab, :string, required: true
  attr :note_form, :any, required: true
  attr :now, DateTime, required: true

  def page(assigns) do
    ~H"""
    <%= if @view do %>
      <.detail view={@view} tab={@tab} note_form={@note_form} now={@now} />
    <% else %>
      <.handoff_list handoffs={@handoffs} filter={@filter} now={@now} />
    <% end %>
    """
  end

  ## The list

  attr :handoffs, :list, required: true
  attr :filter, :string, required: true
  attr :now, DateTime, required: true

  defp handoff_list(assigns) do
    {open, done} = Enum.split_with(assigns.handoffs, &(&1.status in [:open, :sent_back]))

    assigns =
      assign(assigns,
        open: open,
        done: done,
        shown: if(assigns.filter == "closed", do: done, else: open)
      )

    ~H"""
    <.page_header id="handoffs-header" title="Handoffs">
      <:help>
        Agents work in worktrees of a project, in the VM, and hand finished work off with mdt handoff: one branch, offered to one of the project's target branches, after catching up with it. Its commits wait in a store of MDT's own; nothing is written into your repository until you accept it, onto a target branch with no pending work.
      </:help>
    </.page_header>

    <section id="handoffs" class="overflow-hidden rounded-xl border border-line bg-panel">
      <header class="flex items-center gap-4 border-b border-line-soft bg-deep/40 px-4 py-2.5">
        <.link
          patch={~p"/tools/sandbox/handoffs"}
          id="handoffs-filter-open"
          class={[
            "flex items-center gap-1.5 text-[13px] transition-colors",
            if(@filter != "closed",
              do: "font-semibold text-ink",
              else: "text-muted hover:text-ink"
            )
          ]}
        >
          <.icon name="hero-inbox-arrow-down" class="size-4" /> {length(@open)} Open
        </.link>
        <.link
          patch={~p"/tools/sandbox/handoffs?filter=closed"}
          id="handoffs-filter-closed"
          class={[
            "flex items-center gap-1.5 text-[13px] transition-colors",
            if(@filter == "closed",
              do: "font-semibold text-ink",
              else: "text-muted hover:text-ink"
            )
          ]}
        >
          <.icon name="hero-check" class="size-4" /> {length(@done)} Closed
        </.link>
      </header>
      <ul id="handoff-list" class="divide-y divide-line-soft">
        <li :if={@shown == []}>
          <.empty id="handoffs-empty" icon="hero-inbox-arrow-down">
            <%= if @filter == "closed" do %>
              Nothing accepted or closed yet.
            <% else %>
              No open handoffs. An agent hands work off with mdt handoff, from a worktree of a project.
            <% end %>
          </.empty>
        </li>
        <li :for={handoff <- @shown} id={"handoff-row-#{handoff.id}"}>
          <.link
            patch={~p"/tools/sandbox/handoffs?id=#{handoff.id}"}
            class="group flex items-start gap-3 px-4 py-3 transition-colors hover:bg-hover/40"
          >
            <.state_icon status={handoff.status} class="mt-0.5 size-4" />
            <div class="min-w-0 flex-1">
              <p class="flex flex-wrap items-center gap-x-2 gap-y-1">
                <span class="truncate text-[13px] font-semibold text-ink group-hover:text-accent">
                  {handoff.title}
                </span>
                <span
                  :if={handoff.status == :sent_back}
                  class="rounded-full border border-warn/40 px-1.5 py-px text-[10px] font-medium text-warn-strong"
                >
                  Sent back
                </span>
              </p>
              <p class="mt-1 truncate text-[11px] text-faint">
                #{handoff.id} · {Handoffs.who(handoff)}{if handoff.thread,
                  do: " · " <> handoff.thread} · {handoff.project}
                <span class="font-mono">{handoff.source.branch} → {handoff.onto}</span>
                · {verb(handoff)} {ago(handoff.updated_at || handoff.opened_at, @now)}
              </p>
            </div>
            <div class="flex shrink-0 items-center gap-3 text-[11px]">
              <span
                :if={(handoff.stats[:conflicts] || 0) > 0 and handoff.status in [:open, :sent_back]}
                class="flex items-center gap-1 text-bad"
                title="Conflicts with its target branch as it is now"
              >
                <.icon name="hero-exclamation-triangle-micro" class="size-3.5" /> conflicts
              </span>
              <span class="font-mono text-ok-strong">+{handoff.stats[:added] || 0}</span>
              <span class="font-mono text-bad">−{handoff.stats[:removed] || 0}</span>
              <span class="flex items-center gap-1 text-faint" title="Files changed">
                <.icon name="hero-document-micro" class="size-3.5" />{handoff.stats[:files] || 0}
              </span>
            </div>
          </.link>
        </li>
      </ul>
    </section>
    """
  end

  ## One handoff

  attr :view, :map, required: true
  attr :tab, :string, required: true
  attr :note_form, :any, required: true
  attr :now, DateTime, required: true

  defp detail(assigns) do
    assigns = assign(assigns, handoff: assigns.view.handoff, facts: assigns.view.facts)

    ~H"""
    <div id={"handoff-#{@handoff.id}"} class="space-y-5">
      <div>
        <.link
          patch={~p"/tools/sandbox/handoffs"}
          id="handoff-back"
          class="inline-flex items-center gap-1 text-[12px] text-muted transition-colors hover:text-ink"
        >
          <.icon name="hero-arrow-left-micro" class="size-3.5" /> Handoffs
        </.link>
        <h1 id="handoff-title" class="mt-2 text-xl font-semibold tracking-tight text-ink">
          {@handoff.title} <span class="font-normal text-faint">#{@handoff.id}</span>
        </h1>
        <div class="mt-2 flex flex-wrap items-center gap-2 text-[13px] text-muted">
          <.state_pill status={@handoff.status} />
          <span>
            <span class="font-medium text-ink">{Handoffs.who(@handoff)}</span>
            <%= if @handoff.status in [:open, :sent_back] do %>
              wants to hand {count(@handoff.stats[:commits] || 0, "commit")} onto
            <% else %>
              handed {count(@handoff.stats[:commits] || 0, "commit")} for
            <% end %>
            <code class="rounded bg-accent-soft/50 px-1.5 py-0.5 font-mono text-[12px] text-accent-strong">
              {@handoff.onto}
            </code>
            from
            <code class="rounded bg-deep px-1.5 py-0.5 font-mono text-[12px] text-ink">
              {@handoff.source.branch}
            </code>
          </span>
        </div>
      </div>

      <nav id="handoff-tabs" class="flex gap-1 border-b border-line-soft">
        <.tab_link
          handoff={@handoff}
          tab="conversation"
          current={@tab}
          icon="hero-chat-bubble-left-right"
        >
          Conversation
        </.tab_link>
        <.tab_link handoff={@handoff} tab="commits" current={@tab} icon="hero-circle-stack">
          Commits <.counter :if={@facts} n={length(@facts.commits)} />
        </.tab_link>
        <.tab_link handoff={@handoff} tab="files" current={@tab} icon="hero-document-text">
          Files changed <.counter :if={@facts} n={length(@facts.files)} />
        </.tab_link>
        <span :if={@facts} class="ml-auto self-center pb-1 font-mono text-[12px]">
          <span class="text-ok-strong">+{@facts.added}</span>
          <span class="text-bad">−{@facts.removed}</span>
        </span>
      </nav>

      <p
        :if={@view.error}
        id="handoff-error"
        class="flex items-start gap-2 rounded-lg border border-bad/40 bg-bad-soft/30 px-3 py-2 text-xs text-bad"
      >
        <.icon name="hero-exclamation-circle-micro" class="mt-px size-3.5 shrink-0" />
        {@view.error}
      </p>

      <%= case @tab do %>
        <% "commits" -> %>
          <.commits facts={@facts} />
        <% "files" -> %>
          <.files diff={@view.diff} />
        <% _conversation -> %>
          <div class="grid items-start gap-6 lg:grid-cols-[minmax(0,1fr)_16rem]">
            <div class="space-y-4">
              <.description handoff={@handoff} now={@now} />
              <.timeline handoff={@handoff} now={@now} />
              <.accept_box view={@view} note_form={@note_form} now={@now} />
            </div>
            <.side handoff={@handoff} facts={@facts} />
          </div>
      <% end %>
    </div>
    """
  end

  attr :handoff, :map, required: true
  attr :tab, :string, required: true
  attr :current, :string, required: true
  attr :icon, :string, required: true
  slot :inner_block, required: true

  defp tab_link(assigns) do
    ~H"""
    <.link
      patch={~p"/tools/sandbox/handoffs?id=#{@handoff.id}&tab=#{@tab}"}
      id={"handoff-tab-#{@tab}"}
      class={[
        "-mb-px flex items-center gap-1.5 border-b-2 px-3 py-2 text-[13px] transition-colors",
        if(@tab == @current,
          do: "border-accent font-medium text-ink",
          else: "border-transparent text-muted hover:border-line hover:text-ink"
        )
      ]}
    >
      <.icon name={@icon} class="size-4 text-faint" />
      {render_slot(@inner_block)}
    </.link>
    """
  end

  attr :n, :integer, required: true

  defp counter(assigns) do
    ~H"""
    <span class="rounded-full bg-hover px-1.5 py-px text-[10px] font-semibold tabular-nums text-muted">
      {@n}
    </span>
    """
  end

  attr :handoff, :map, required: true
  attr :now, DateTime, required: true

  defp description(assigns) do
    ~H"""
    <section
      id="handoff-description"
      class="overflow-hidden rounded-xl border border-line bg-panel"
    >
      <header class="flex items-center gap-2 border-b border-line-soft bg-deep/40 px-4 py-2 text-[12px]">
        <span class="font-semibold text-ink">{Handoffs.who(@handoff)}</span>
        <span class="text-faint">handed it off {ago(@handoff.opened_at, @now)}</span>
        <span class="ml-auto rounded border border-line px-1.5 py-px text-[10px] text-faint">
          the agent's words
        </span>
      </header>
      <%!-- White space is kept, so the text sits tight against its tags. --%>
      <div
        :if={@handoff.body != ""}
        class="whitespace-pre-wrap break-words px-4 py-3 text-[13px] leading-6 text-ink"
        phx-no-format
      >{@handoff.body}</div>
      <p :if={@handoff.body == ""} class="px-4 py-3 text-[13px] italic text-faint">
        No description given.
      </p>
    </section>
    """
  end

  attr :handoff, :map, required: true
  attr :now, DateTime, required: true

  defp timeline(assigns) do
    ~H"""
    <ol id="handoff-timeline" class="relative ml-4 space-y-3 border-l border-line-soft pl-5">
      <li
        :for={{event, i} <- Enum.with_index(@handoff.timeline)}
        id={"handoff-event-#{i}"}
        class="relative"
      >
        <span class={[
          "absolute -left-[1.95rem] flex size-6 items-center justify-center rounded-full border border-line bg-panel",
          event_tone(event.kind)
        ]}>
          <.icon name={event_icon(event.kind)} class="size-3.5" />
        </span>
        <p class="text-[12px] leading-6 text-muted">
          {event.text}
          <span class="text-faint">· {ago(event.at, @now)}</span>
        </p>
        <p
          :if={event[:note] not in [nil, ""]}
          class="mt-1 whitespace-pre-wrap rounded-lg border border-line-soft bg-deep/40 px-3 py-2 text-[12px] leading-5 text-ink"
          phx-no-format
        >{event.note}</p>
      </li>
    </ol>
    """
  end

  defp event_icon(:opened), do: "hero-inbox-arrow-down-micro"
  defp event_icon(:updated), do: "hero-arrow-up-circle-micro"
  defp event_icon(:sent_back), do: "hero-arrow-uturn-left-micro"
  defp event_icon(:accepted), do: "hero-check-micro"
  defp event_icon(:saved), do: "hero-bookmark-micro"
  defp event_icon(:closed), do: "hero-x-mark-micro"
  defp event_icon(_reopened), do: "hero-arrow-path-micro"

  defp event_tone(:accepted), do: "text-violet-strong"
  defp event_tone(:closed), do: "text-bad"
  defp event_tone(:sent_back), do: "text-warn-strong"
  defp event_tone(_), do: "text-faint"

  attr :handoff, :map, required: true
  attr :facts, :any, required: true

  defp side(assigns) do
    ~H"""
    <aside id="handoff-side" class="space-y-4 text-[12px]">
      <div>
        <p class="mb-1 text-[10px] font-semibold uppercase tracking-wide text-faint">Project</p>
        <p class="text-ink">{@handoff.project}</p>
        <p class="break-all font-mono text-[11px] text-muted" title={@handoff.repo}>
          {@handoff.repo}
        </p>
      </div>
      <div :if={@handoff.thread}>
        <p class="mb-1 text-[10px] font-semibold uppercase tracking-wide text-faint">Thread</p>
        <p id="handoff-thread" class="text-ink">{@handoff.thread}</p>
        <p class="text-[11px] text-faint">{Handoffs.who(@handoff)}</p>
      </div>
      <div>
        <p class="mb-1 text-[10px] font-semibold uppercase tracking-wide text-faint">
          From the worktree
        </p>
        <p class="break-all font-mono text-muted" title={@handoff.source.top}>
          {@handoff.source.top}
        </p>
        <p class="mt-0.5 font-mono text-muted">
          {@handoff.source.branch} at {String.slice(@handoff.head, 0, 10)}
        </p>
      </div>
      <div>
        <p class="mb-1 text-[10px] font-semibold uppercase tracking-wide text-faint">Revision</p>
        <p class="text-muted">{@handoff.revision}</p>
      </div>
      <div :if={@facts && @facts.hints != []} id="handoff-hints">
        <p class="mb-1 text-[10px] font-semibold uppercase tracking-wide text-faint">Look closer</p>
        <ul class="space-y-1">
          <li
            :for={hint <- @facts.hints}
            class="flex items-start gap-1.5 leading-4 text-warn-strong"
          >
            <.icon name="hero-light-bulb-micro" class="mt-px size-3.5 shrink-0" /> {hint}
          </li>
        </ul>
      </div>
    </aside>
    """
  end

  ## The accept box

  attr :view, :map, required: true
  attr :note_form, :any, required: true
  attr :now, DateTime, required: true

  defp accept_box(assigns) do
    assigns = assign(assigns, handoff: assigns.view.handoff, facts: assigns.view.facts)

    ~H"""
    <section
      id="handoff-accept-box"
      class={[
        "overflow-hidden rounded-xl border bg-panel",
        case @handoff.status do
          :accepted -> "border-violet/40"
          :closed -> "border-bad/40"
          _ -> if(@facts && @facts.conflicts != [], do: "border-bad/40", else: "border-ok/40")
        end
      ]}
    >
      <%= case @handoff.status do %>
        <% :accepted -> %>
          <div class="flex flex-wrap items-center gap-3 px-4 py-3">
            <span class="flex size-8 items-center justify-center rounded-full bg-violet/15 text-violet-strong">
              <.icon name="hero-check" class="size-4" />
            </span>
            <div class="min-w-0 flex-1">
              <p class="text-[13px] font-semibold text-ink">Accepted</p>
              <p id="handoff-accepted" class="text-[12px] text-muted">
                {Handoffs.accepted_words(@handoff.accepted)}, at {@handoff.accepted.worktree}, {ago(
                  @handoff.accepted.at,
                  @now
                )}.
              </p>
            </div>
            <.button
              id="handoff-undo"
              phx-click="undo_handoff"
              phx-value-id={@handoff.id}
              data-confirm="Take it back out? Changes you made since to what it brought are lost."
            >
              <.icon name="hero-arrow-uturn-left-micro" class="size-3.5" /> Undo
            </.button>
          </div>
        <% :closed -> %>
          <div class="flex items-center gap-3 px-4 py-3">
            <p class="flex-1 text-[13px] text-muted">Closed without accepting it.</p>
            <.button id="handoff-reopen" phx-click="reopen_handoff" phx-value-id={@handoff.id}>
              Reopen
            </.button>
          </div>
        <% _open -> %>
          <.mergeability handoff={@handoff} facts={@facts} />
          <.accept view={@view} />
          <.send_back handoff={@handoff} note_form={@note_form} />
      <% end %>
    </section>
    """
  end

  attr :handoff, :map, required: true
  attr :facts, :any, required: true

  defp mergeability(assigns) do
    ~H"""
    <div class="flex items-start gap-3 border-b border-line-soft px-4 py-3">
      <%= cond do %>
        <% is_nil(@facts) -> %>
          <span class="flex size-8 shrink-0 items-center justify-center rounded-full bg-hover text-faint">
            <.icon name="hero-question-mark-circle" class="size-4" />
          </span>
          <p class="text-[13px] text-muted">MDT couldn't compare it with your {@handoff.onto}.</p>
        <% @facts.conflicts == [] -> %>
          <span class="flex size-8 shrink-0 items-center justify-center rounded-full bg-ok-soft text-ok-strong">
            <.icon name="hero-check" class="size-4" />
          </span>
          <div id="handoff-merges">
            <p class="text-[13px] font-semibold text-ink">
              No conflicts with your {@handoff.onto}
            </p>
            <p class="text-[12px] text-muted">
              <%= if @facts.behind == 0 do %>
                Built on {@handoff.onto} as it is now.
              <% else %>
                Your {@handoff.onto} has {count(@facts.behind, "commit")} it doesn't have; they merge cleanly.
              <% end %>
            </p>
          </div>
        <% true -> %>
          <span class="flex size-8 shrink-0 items-center justify-center rounded-full bg-bad-soft text-bad">
            <.icon name="hero-exclamation-triangle" class="size-4" />
          </span>
          <div id="handoff-conflicts" class="min-w-0">
            <p class="text-[13px] font-semibold text-ink">
              Conflicts with your {@handoff.onto}
            </p>
            <p class="text-[12px] text-muted">
              Your {@handoff.onto} moved since the agent caught up: {count(
                @facts.behind,
                "commit"
              )} it doesn't have change the same lines in:
            </p>
            <ul class="mt-1.5 space-y-0.5">
              <li :for={file <- @facts.conflicts} class="truncate font-mono text-[11px] text-bad">
                {file}
              </li>
            </ul>
            <p class="mt-1.5 text-[12px] text-muted">
              Send it back so its thread catches up again (git merge host), or take the changes with conflict markers.
            </p>
          </div>
      <% end %>
    </div>
    """
  end

  attr :view, :map, required: true

  defp accept(assigns) do
    assigns = assign(assigns, handoff: assigns.view.handoff, accept: assigns.view.accept)

    ~H"""
    <.form
      for={@accept.form}
      id="handoff-accept"
      phx-change="accept_change"
      phx-submit="accept_handoff"
      class="space-y-3 border-b border-line-soft px-4 py-4"
    >
      <div class="grid gap-2 sm:grid-cols-2">
        <.choice
          id="handoff-how-commits"
          name={@accept.form[:how].name}
          value="commits"
          checked={@accept.how == :commits}
          title="The agent's commits"
          text="Merged into your branch: a fast-forward when it can be. They keep the agent's messages and authorship."
        />
        <.choice
          id="handoff-how-changes"
          name={@accept.form[:how].name}
          value="changes"
          checked={@accept.how == :changes}
          title="Only the changes"
          text="Uncommitted edits on your branch, for you to commit. Nothing is committed or staged."
        />
      </div>

      <div class="flex flex-wrap items-center gap-3">
        <.preview accept={@accept} onto={@handoff.onto} />
        <div class="ml-auto flex items-center gap-2">
          <.button
            :if={@accept.how == :changes and conflicts?(@accept.preview)}
            type="submit"
            id="handoff-accept-anyway"
            name="anyway"
            value="true"
            data-confirm="Take the changes with conflict markers in the files that don't merge?"
          >
            With conflict markers
          </.button>
          <.button
            type="submit"
            id="handoff-accept-button"
            variant="primary"
            disabled={not ready?(@accept.preview)}
            phx-disable-with="Accepting…"
          >
            <.icon name="hero-check-micro" class="size-3.5" /> Accept onto {@handoff.onto}
          </.button>
        </div>
      </div>
    </.form>
    <.form
      for={@accept.branch_form}
      id="handoff-save-branch"
      phx-submit="save_handoff_branch"
      class="flex flex-wrap items-center gap-2 border-b border-line-soft px-4 py-2.5"
    >
      <span class="text-[12px] text-muted">Look at it first: save its commits as a branch</span>
      <div class="ml-auto flex items-center gap-2">
        <div class="w-60">
          <input
            type="text"
            id="handoff-branch"
            name={@accept.branch_form[:name].name}
            value={@accept.branch_form[:name].value}
            autocomplete="off"
            spellcheck="false"
            class={[input_classes(), "font-mono text-xs"]}
          />
        </div>
        <.button
          type="submit"
          id="handoff-save-branch-button"
          class="shrink-0 whitespace-nowrap"
        >
          <.icon name="hero-bookmark-micro" class="size-3.5" /> Save branch
        </.button>
      </div>
    </.form>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :value, :string, required: true
  attr :checked, :boolean, required: true
  attr :title, :string, required: true
  attr :text, :string, required: true

  defp choice(assigns) do
    ~H"""
    <label
      id={@id}
      class={[
        "flex cursor-pointer items-start gap-2.5 rounded-lg border px-3 py-2.5 transition-all",
        if(@checked,
          do: "border-accent/60 bg-accent-soft/20 shadow-sm",
          else: "border-line hover:border-line hover:bg-hover/40"
        )
      ]}
    >
      <input
        type="radio"
        name={@name}
        value={@value}
        checked={@checked}
        class="mt-0.5 size-3.5 border-line bg-deep text-accent"
      />
      <span>
        <span class="block text-[13px] font-medium text-ink">{@title}</span>
        <span class="mt-0.5 block text-[11px] leading-4 text-muted">{@text}</span>
      </span>
    </label>
    """
  end

  attr :accept, :map, required: true
  attr :onto, :string, required: true

  defp preview(assigns) do
    ~H"""
    <p id="handoff-preview" class="flex min-w-0 flex-1 items-start gap-1.5 text-[12px] leading-5">
      <%= case @accept.preview do %>
        <% nil -> %>
          <span class="text-faint">Working out what it would do…</span>
        <% {:error, words} -> %>
          <.icon name="hero-exclamation-circle-micro" class="mt-1 size-3.5 shrink-0 text-warn-strong" />
          <span class="text-warn-strong">{words}</span>
        <% {:ok, %{conflicts: [_ | _] = files}} -> %>
          <.icon name="hero-exclamation-triangle-micro" class="mt-1 size-3.5 shrink-0 text-bad" />
          <span class="text-bad">
            Conflicts in <span class="font-mono">{Enum.join(files, ", ")}</span>. {if @accept.how ==
                                                                                        :commits,
                                                                                      do:
                                                                                        "Commits can't land with conflicts: send it back, or take only the changes.",
                                                                                      else: ""}
          </span>
        <% {:ok, %{up_to_date?: true}} -> %>
          <.icon name="hero-check-circle-micro" class="mt-1 size-3.5 shrink-0 text-ok-strong" />
          <span class="text-ok-strong">Your {@onto} has all of it already.</span>
        <% {:ok, preview} -> %>
          <.icon name="hero-check-circle-micro" class="mt-1 size-3.5 shrink-0 text-ok-strong" />
          <span class="text-ok-strong">
            <%= cond do %>
              <% preview.fast_forward? -> %>
                A fast-forward of {@onto}, at {preview.worktree}.
              <% @accept.how == :commits -> %>
                A merge commit on {@onto}, at {preview.worktree}.
              <% true -> %>
                Uncommitted changes on {@onto}, at {preview.worktree}.
            <% end %>
          </span>
      <% end %>
    </p>
    """
  end

  defp conflicts?({:ok, %{conflicts: [_ | _]}}), do: true
  defp conflicts?(_), do: false

  defp ready?({:ok, %{up_to_date?: true}}), do: false
  defp ready?({:ok, %{conflicts: []}}), do: true
  defp ready?(_), do: false

  attr :handoff, :map, required: true
  attr :note_form, :any, required: true

  defp send_back(assigns) do
    ~H"""
    <.form
      for={@note_form}
      id="handoff-send-back"
      phx-submit="send_back_handoff"
      class="space-y-2 bg-deep/30 px-4 py-3"
    >
      <input type="hidden" name="handoff" value={@handoff.id} />
      <textarea
        name={@note_form[:note].name}
        id="handoff-note"
        rows="2"
        placeholder={"A note for #{if @handoff.thread, do: "the thread \"#{@handoff.thread}\"", else: "the agent"}: what to change, or to catch up again"}
        class={[input_classes(), "min-h-[3.25rem] text-xs"]}
      >{@note_form[:note].value}</textarea>
      <div class="flex items-center justify-end gap-2">
        <.button
          id="handoff-close"
          type="button"
          variant="ghost"
          phx-click="close_handoff"
          phx-value-id={@handoff.id}
          data-confirm="Close it without accepting it? The agent is told."
        >
          Close
        </.button>
        <.button type="submit" id="handoff-send-back-button">
          <.icon name="hero-arrow-uturn-left-micro" class="size-3.5" /> Send back
        </.button>
      </div>
    </.form>
    """
  end

  ## Commits and files

  attr :facts, :any, required: true

  defp commits(assigns) do
    ~H"""
    <section id="handoff-commits" class="overflow-hidden rounded-xl border border-line bg-panel">
      <p :if={is_nil(@facts)} class="px-4 py-3 text-[13px] text-faint">No commits to show.</p>
      <ol :if={@facts} class="divide-y divide-line-soft">
        <li
          :for={commit <- @facts.commits}
          id={"handoff-commit-#{String.slice(commit.sha, 0, 10)}"}
          class="flex items-center gap-3 px-4 py-2.5"
        >
          <.icon name="hero-circle-stack-micro" class="size-3.5 shrink-0 text-faint" />
          <div class="min-w-0 flex-1">
            <p class="truncate text-[13px] text-ink">{commit.subject}</p>
            <p class="text-[11px] text-faint">
              {commit.author}{if commit.at,
                do: " · " <> Calendar.strftime(commit.at, "%Y-%m-%d %H:%M")}
            </p>
          </div>
          <code class="shrink-0 rounded bg-deep px-1.5 py-0.5 font-mono text-[11px] text-muted">
            {String.slice(commit.sha, 0, 10)}
          </code>
        </li>
      </ol>
    </section>
    """
  end

  attr :diff, :any, required: true

  defp files(assigns) do
    ~H"""
    <div id="handoff-files" class="space-y-3">
      <p :if={is_nil(@diff)} class="text-[13px] text-faint">The change couldn't be read.</p>
      <%= if @diff do %>
        <section
          :for={{file, i} <- Enum.with_index(@diff.files)}
          id={"handoff-file-#{i}"}
          class="overflow-hidden rounded-xl border border-line bg-panel"
        >
          <header class="flex items-center gap-3 border-b border-line-soft bg-deep/40 px-4 py-2">
            <span class="min-w-0 flex-1 truncate font-mono text-[12px] text-ink" title={file.path}>
              {file.path}
            </span>
            <span class="font-mono text-[11px] text-ok-strong">+{FileDiff.counts(file).added}</span>
            <span class="font-mono text-[11px] text-bad">−{FileDiff.counts(file).removed}</span>
          </header>
          <p :if={file.binary?} class="px-4 py-2 text-[12px] text-faint">A binary file.</p>
          <p :if={file.hunks == [] and not file.binary?} class="px-4 py-2 text-[12px] text-faint">
            Renamed, or its mode changed; no lines differ.
          </p>
          <div :if={file.hunks != []} class="overflow-x-auto font-mono text-[11px] leading-[1.5]">
            <table class="w-full border-collapse">
              <tbody :for={hunk <- file.hunks}>
                <tr class="bg-accent-soft/20 text-accent">
                  <td colspan="3" class="px-3 py-0.5">{hunk.header}</td>
                </tr>
                <tr :for={line <- hunk.lines} class={line_class(line.kind)}>
                  <td class="w-10 select-none border-r border-line-soft px-2 text-right text-faint">
                    {line.old_line}
                  </td>
                  <td class="w-10 select-none border-r border-line-soft px-2 text-right text-faint">
                    {line.new_line}
                  </td>
                  <td class="whitespace-pre px-3" phx-no-format>{sign(line.kind)}{line.text}</td>
                </tr>
              </tbody>
            </table>
          </div>
          <p
            :if={file.truncated?}
            class="border-t border-line-soft px-4 py-1.5 text-[11px] text-faint"
          >
            Cut short here.
          </p>
        </section>
        <p :if={@diff.cut?} id="handoff-diff-cut" class="text-[12px] text-faint">
          The change goes on past what is shown here.
        </p>
      <% end %>
    </div>
    """
  end

  defp line_class(:added), do: "bg-ok-soft/30 text-ink"
  defp line_class(:removed), do: "bg-bad-soft/30 text-ink"
  defp line_class(_), do: "text-ink/80"

  defp sign(:added), do: "+"
  defp sign(:removed), do: "−"
  defp sign(_), do: " "

  ## Small parts

  attr :status, :atom, required: true
  attr :class, :any, default: "size-4"

  defp state_icon(assigns) do
    ~H"""
    <.icon
      name={
        case @status do
          :accepted -> "hero-check-circle"
          :closed -> "hero-x-circle"
          :sent_back -> "hero-arrow-uturn-left"
          _open -> "hero-inbox-arrow-down"
        end
      }
      class={[
        @class,
        "shrink-0",
        case @status do
          :accepted -> "text-violet-strong"
          :closed -> "text-bad"
          :sent_back -> "text-warn-strong"
          _open -> "text-ok-strong"
        end
      ]}
    />
    """
  end

  attr :status, :atom, required: true

  defp state_pill(assigns) do
    {label, classes} =
      case assigns.status do
        :open -> {"Open", "bg-ok-soft text-ok-strong"}
        :sent_back -> {"Sent back", "bg-warn-soft text-warn-strong"}
        :accepted -> {"Accepted", "bg-violet/15 text-violet-strong"}
        :closed -> {"Closed", "bg-bad-soft text-bad"}
      end

    assigns = assign(assigns, label: label, classes: classes)

    ~H"""
    <span
      id="handoff-state"
      class={[
        "inline-flex items-center gap-1 rounded-full px-2.5 py-1 text-[12px] font-medium",
        @classes
      ]}
    >
      <.state_icon status={@status} class="size-3.5 !text-current" /> {@label}
    </span>
    """
  end

  defp verb(%Handoff{status: :accepted}), do: "accepted"
  defp verb(%Handoff{status: :closed}), do: "closed"
  defp verb(%Handoff{revision: 1}), do: "handed off"
  defp verb(_handoff), do: "updated"

  defp count(1, word), do: "1 #{word}"
  defp count(n, word), do: "#{n} #{word}s"
end
