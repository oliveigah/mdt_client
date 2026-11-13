defmodule MDTClientWeb.SandboxLive.Pulls do
  @moduledoc """
  The pull requests page: what agents in the VM offer back, the way a code
  host lists pull requests.

  An agent opens one with `mdt pr` in any git repository in the VM; there
  is nothing to set up here. The list shows each with its repository and
  branches. Opening one shows the conversation (the agent's description,
  what happened since, and the merge box), its commits, and the files it
  changes. From the merge box you bring it in, choosing where (a worktree,
  a new worktree, a new branch) and how (only the changes, uncommitted, or
  the agent's commits), send it back with a note and your base branch, or
  close it.
  """
  use MDTClientWeb, :html

  import MDTClientWeb.SandboxLive.Components

  alias MDTClient.Git.FileDiff
  alias MDTClient.Sandbox.{PullRequest, PullRequests}

  attr :pulls, :list, required: true
  attr :filter, :string, required: true
  attr :view, :any, required: true, doc: "the pull request open, with what was worked out, or nil"
  attr :tab, :string, required: true
  attr :note_form, :any, required: true
  attr :vm, :any, required: true
  attr :now, DateTime, required: true

  def page(assigns) do
    ~H"""
    <%= if @view do %>
      <.detail view={@view} tab={@tab} note_form={@note_form} vm={@vm} now={@now} />
    <% else %>
      <.pull_list pulls={@pulls} filter={@filter} now={@now} />
    <% end %>
    """
  end

  ## The list

  attr :pulls, :list, required: true
  attr :filter, :string, required: true
  attr :now, DateTime, required: true

  defp pull_list(assigns) do
    {open, done} = Enum.split_with(assigns.pulls, &(&1.status in [:open, :changes_requested]))

    assigns =
      assign(assigns,
        open: open,
        done: done,
        shown: if(assigns.filter == "closed", do: done, else: open)
      )

    ~H"""
    <.page_header id="pulls-header" title="Pull requests">
      <:help>
        Agents in the VM offer their work back as pull requests: in any git repository there, on a branch with everything committed, they run mdt pr. MDT works out which repository on your machine it is for, from the path the agent gives or the repository's remotes, and keeps the commits in a store of its own. Nothing is written into your repository until you bring one in, choosing where and how.
      </:help>
    </.page_header>

    <section id="pulls" class="overflow-hidden rounded-xl border border-line bg-panel">
      <header class="flex items-center gap-4 border-b border-line-soft bg-deep/40 px-4 py-2.5">
        <.link
          patch={~p"/tools/sandbox/pulls"}
          id="pulls-filter-open"
          class={[
            "flex items-center gap-1.5 text-[13px] transition-colors",
            if(@filter != "closed",
              do: "font-semibold text-ink",
              else: "text-muted hover:text-ink"
            )
          ]}
        >
          <.icon name="hero-arrow-path-rounded-square" class="size-4" /> {length(@open)} Open
        </.link>
        <.link
          patch={~p"/tools/sandbox/pulls?filter=closed"}
          id="pulls-filter-closed"
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
      <ul id="pull-list" class="divide-y divide-line-soft">
        <li :if={@shown == []}>
          <.empty id="pulls-empty" icon="hero-arrow-path-rounded-square">
            <%= if @filter == "closed" do %>
              Nothing brought in or closed yet.
            <% else %>
              No open pull requests. An agent opens one with mdt pr, from a branch of any git repository in the VM.
            <% end %>
          </.empty>
        </li>
        <li :for={pull <- @shown} id={"pull-row-#{pull.id}"}>
          <.link
            patch={~p"/tools/sandbox/pulls?pr=#{pull.id}"}
            class="group flex items-start gap-3 px-4 py-3 transition-colors hover:bg-hover/40"
          >
            <.state_icon status={pull.status} class="mt-0.5 size-4" />
            <div class="min-w-0 flex-1">
              <p class="flex flex-wrap items-center gap-x-2 gap-y-1">
                <span class="truncate text-[13px] font-semibold text-ink group-hover:text-accent">
                  {pull.title}
                </span>
                <span
                  :if={pull.status == :changes_requested}
                  class="rounded-full border border-warn/40 px-1.5 py-px text-[10px] font-medium text-warn-strong"
                >
                  Sent back
                </span>
              </p>
              <p class="mt-1 truncate text-[11px] text-faint">
                #{pull.id} · {who(pull)} · {Path.basename(pull.repo)}
                <span class="font-mono">{pull.source.branch} → {pull.base}</span>
                · {verb(pull)} {ago(pull.updated_at || pull.opened_at, @now)}
              </p>
            </div>
            <div class="flex shrink-0 items-center gap-3 text-[11px]">
              <span
                :if={(pull.stats[:conflicts] || 0) > 0 and pull.status in [:open, :changes_requested]}
                class="flex items-center gap-1 text-bad"
                title="Conflicts with the base branch, when it was last looked at"
              >
                <.icon name="hero-exclamation-triangle-micro" class="size-3.5" /> conflicts
              </span>
              <span class="font-mono text-ok-strong">+{pull.stats[:added] || 0}</span>
              <span class="font-mono text-bad">−{pull.stats[:removed] || 0}</span>
              <span class="flex items-center gap-1 text-faint" title="Files changed">
                <.icon name="hero-document-micro" class="size-3.5" />{pull.stats[:files] || 0}
              </span>
            </div>
          </.link>
        </li>
      </ul>
    </section>
    """
  end

  ## One pull request

  attr :view, :map, required: true
  attr :tab, :string, required: true
  attr :note_form, :any, required: true
  attr :vm, :any, required: true
  attr :now, DateTime, required: true

  defp detail(assigns) do
    assigns = assign(assigns, pull: assigns.view.pull, facts: assigns.view.facts)

    ~H"""
    <div id={"pull-#{@pull.id}"} class="space-y-5">
      <div>
        <.link
          patch={~p"/tools/sandbox/pulls"}
          id="pull-back"
          class="inline-flex items-center gap-1 text-[12px] text-muted transition-colors hover:text-ink"
        >
          <.icon name="hero-arrow-left-micro" class="size-3.5" /> Pull requests
        </.link>
        <h1 id="pull-title" class="mt-2 text-xl font-semibold tracking-tight text-ink">
          {@pull.title} <span class="font-normal text-faint">#{@pull.id}</span>
        </h1>
        <div class="mt-2 flex flex-wrap items-center gap-2 text-[13px] text-muted">
          <.state_pill status={@pull.status} />
          <span>
            <span class="font-medium text-ink">{who(@pull)}</span>
            <%= if @pull.status in [:open, :changes_requested] do %>
              wants to bring {count(@pull.stats[:commits] || 0, "commit")} into
            <% else %>
              offered {count(@pull.stats[:commits] || 0, "commit")} for
            <% end %>
            <code class="rounded bg-accent-soft/50 px-1.5 py-0.5 font-mono text-[12px] text-accent-strong">
              {@pull.base}
            </code>
            from
            <code class="rounded bg-deep px-1.5 py-0.5 font-mono text-[12px] text-ink">
              {@pull.source.branch}
            </code>
          </span>
        </div>
      </div>

      <nav id="pull-tabs" class="flex gap-1 border-b border-line-soft">
        <.tab_link pull={@pull} tab="conversation" current={@tab} icon="hero-chat-bubble-left-right">
          Conversation
        </.tab_link>
        <.tab_link pull={@pull} tab="commits" current={@tab} icon="hero-circle-stack">
          Commits <.counter :if={@facts} n={length(@facts.commits)} />
        </.tab_link>
        <.tab_link pull={@pull} tab="files" current={@tab} icon="hero-document-text">
          Files changed <.counter :if={@facts} n={length(@facts.files)} />
        </.tab_link>
        <span :if={@facts} class="ml-auto self-center pb-1 font-mono text-[12px]">
          <span class="text-ok-strong">+{@facts.added}</span>
          <span class="text-bad">−{@facts.removed}</span>
        </span>
      </nav>

      <p
        :if={@view.error}
        id="pull-error"
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
              <.description pull={@pull} now={@now} />
              <.timeline pull={@pull} now={@now} />
              <.merge_box view={@view} note_form={@note_form} vm={@vm} now={@now} />
            </div>
            <.side pull={@pull} facts={@facts} />
          </div>
      <% end %>
    </div>
    """
  end

  attr :pull, :map, required: true
  attr :tab, :string, required: true
  attr :current, :string, required: true
  attr :icon, :string, required: true
  slot :inner_block, required: true

  defp tab_link(assigns) do
    ~H"""
    <.link
      patch={~p"/tools/sandbox/pulls?pr=#{@pull.id}&tab=#{@tab}"}
      id={"pull-tab-#{@tab}"}
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

  attr :pull, :map, required: true
  attr :now, DateTime, required: true

  defp description(assigns) do
    ~H"""
    <section id="pull-description" class="overflow-hidden rounded-xl border border-line bg-panel">
      <header class="flex items-center gap-2 border-b border-line-soft bg-deep/40 px-4 py-2 text-[12px]">
        <span class="font-semibold text-ink">{who(@pull)}</span>
        <span class="text-faint">opened it {ago(@pull.opened_at, @now)}</span>
        <span class="ml-auto rounded border border-line px-1.5 py-px text-[10px] text-faint">
          the agent's words
        </span>
      </header>
      <%!-- White space is kept, so the text sits tight against its tags. --%>
      <div
        :if={@pull.body != ""}
        class="whitespace-pre-wrap break-words px-4 py-3 text-[13px] leading-6 text-ink"
        phx-no-format
      >{@pull.body}</div>
      <p :if={@pull.body == ""} class="px-4 py-3 text-[13px] italic text-faint">
        No description given.
      </p>
    </section>
    """
  end

  attr :pull, :map, required: true
  attr :now, DateTime, required: true

  defp timeline(assigns) do
    ~H"""
    <ol id="pull-timeline" class="relative ml-4 space-y-3 border-l border-line-soft pl-5">
      <li :for={{event, i} <- Enum.with_index(@pull.timeline)} id={"pull-event-#{i}"} class="relative">
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

  defp event_icon(:opened), do: "hero-arrow-path-rounded-square-micro"
  defp event_icon(:updated), do: "hero-arrow-up-circle-micro"
  defp event_icon(:sent_back), do: "hero-arrow-uturn-left-micro"
  defp event_icon(:merged), do: "hero-check-micro"
  defp event_icon(:closed), do: "hero-x-mark-micro"
  defp event_icon(_reopened), do: "hero-arrow-path-micro"

  defp event_tone(:merged), do: "text-violet-strong"
  defp event_tone(:closed), do: "text-bad"
  defp event_tone(:sent_back), do: "text-warn-strong"
  defp event_tone(_), do: "text-faint"

  attr :pull, :map, required: true
  attr :facts, :any, required: true

  defp side(assigns) do
    ~H"""
    <aside id="pull-side" class="space-y-4 text-[12px]">
      <div>
        <p class="mb-1 text-[10px] font-semibold uppercase tracking-wide text-faint">Repository</p>
        <p class="break-all font-mono text-ink" title={@pull.repo}>{@pull.repo}</p>
      </div>
      <div>
        <p class="mb-1 text-[10px] font-semibold uppercase tracking-wide text-faint">From the VM</p>
        <p class="break-all font-mono text-muted" title={@pull.source.top}>{@pull.source.top}</p>
        <p class="mt-0.5 font-mono text-muted">
          {@pull.source.branch} at {String.slice(@pull.head, 0, 10)}
        </p>
      </div>
      <div>
        <p class="mb-1 text-[10px] font-semibold uppercase tracking-wide text-faint">Revision</p>
        <p class="text-muted">{@pull.revision}</p>
      </div>
      <div :if={@facts && @facts.hints != []} id="pull-hints">
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

  ## The merge box

  attr :view, :map, required: true
  attr :note_form, :any, required: true
  attr :vm, :any, required: true
  attr :now, DateTime, required: true

  defp merge_box(assigns) do
    assigns = assign(assigns, pull: assigns.view.pull, facts: assigns.view.facts)

    ~H"""
    <section
      id="pull-merge"
      class={[
        "overflow-hidden rounded-xl border bg-panel",
        case @pull.status do
          :merged -> "border-violet/40"
          :closed -> "border-bad/40"
          _ -> if(@facts && @facts.conflicts != [], do: "border-bad/40", else: "border-ok/40")
        end
      ]}
    >
      <%= case @pull.status do %>
        <% :merged -> %>
          <div class="flex flex-wrap items-center gap-3 px-4 py-3">
            <span class="flex size-8 items-center justify-center rounded-full bg-violet/15 text-violet-strong">
              <.icon name="hero-check" class="size-4" />
            </span>
            <div class="min-w-0 flex-1">
              <p class="text-[13px] font-semibold text-ink">Brought in</p>
              <p id="pull-landed" class="text-[12px] text-muted">
                {PullRequests.landing_words(@pull.landed)}, {ago(@pull.landed.at, @now)}.
              </p>
            </div>
            <.button
              :if={@pull.landed.undo}
              id="pull-undo"
              phx-click="undo_pull"
              phx-value-id={@pull.id}
              data-confirm="Take it back out? Changes you made since to what it brought are lost."
            >
              <.icon name="hero-arrow-uturn-left-micro" class="size-3.5" /> Undo
            </.button>
          </div>
        <% :closed -> %>
          <div class="flex items-center gap-3 px-4 py-3">
            <p class="flex-1 text-[13px] text-muted">Closed without bringing it in.</p>
            <.button id="pull-reopen" phx-click="reopen_pull" phx-value-id={@pull.id}>
              Reopen
            </.button>
          </div>
        <% _open -> %>
          <.mergeability pull={@pull} facts={@facts} />
          <.bring view={@view} />
          <.send_back pull={@pull} facts={@facts} note_form={@note_form} vm={@vm} />
      <% end %>
    </section>
    """
  end

  attr :pull, :map, required: true
  attr :facts, :any, required: true

  defp mergeability(assigns) do
    ~H"""
    <div class="flex items-start gap-3 border-b border-line-soft px-4 py-3">
      <%= cond do %>
        <% is_nil(@facts) -> %>
          <span class="flex size-8 shrink-0 items-center justify-center rounded-full bg-hover text-faint">
            <.icon name="hero-question-mark-circle" class="size-4" />
          </span>
          <p class="text-[13px] text-muted">MDT couldn't compare it with your {@pull.base}.</p>
        <% @facts.conflicts == [] -> %>
          <span class="flex size-8 shrink-0 items-center justify-center rounded-full bg-ok-soft text-ok-strong">
            <.icon name="hero-check" class="size-4" />
          </span>
          <div id="pull-merges">
            <p class="text-[13px] font-semibold text-ink">
              No conflicts with your {@pull.base}
            </p>
            <p class="text-[12px] text-muted">
              <%= if @facts.behind == 0 do %>
                Built on {@pull.base} as it is now.
              <% else %>
                Your {@pull.base} has {count(@facts.behind, "commit")} it doesn't have; they merge cleanly.
              <% end %>
            </p>
          </div>
        <% true -> %>
          <span class="flex size-8 shrink-0 items-center justify-center rounded-full bg-bad-soft text-bad">
            <.icon name="hero-exclamation-triangle" class="size-4" />
          </span>
          <div id="pull-conflicts" class="min-w-0">
            <p class="text-[13px] font-semibold text-ink">
              Conflicts with your {@pull.base}
            </p>
            <p class="text-[12px] text-muted">
              Your {@pull.base} has {count(@facts.behind, "commit")} it doesn't have, and they change the same lines in:
            </p>
            <ul class="mt-1.5 space-y-0.5">
              <li :for={file <- @facts.conflicts} class="truncate font-mono text-[11px] text-bad">
                {file}
              </li>
            </ul>
            <p class="mt-1.5 text-[12px] text-muted">
              Send it back with your {@pull.base} for the agent to merge, or bring the changes in with conflict markers.
            </p>
          </div>
      <% end %>
    </div>
    """
  end

  attr :view, :map, required: true

  defp bring(assigns) do
    assigns =
      assign(assigns,
        pull: assigns.view.pull,
        land: assigns.view.land,
        dest: assigns.view.destinations
      )

    ~H"""
    <.form
      for={@land.form}
      id="pull-bring"
      phx-change="land_change"
      phx-submit="land_pull"
      class="space-y-4 border-b border-line-soft px-4 py-4"
    >
      <div>
        <p class="mb-2 text-[11px] font-semibold uppercase tracking-wide text-faint">How</p>
        <div class="grid gap-2 sm:grid-cols-2">
          <.choice
            id="pull-how-changes"
            name={@land.form[:how].name}
            value="changes"
            checked={@land.how == :changes}
            title="Only the changes"
            text="Uncommitted edits in a working tree, merged with what is there. Nothing is committed or staged."
          />
          <.choice
            id="pull-how-commits"
            name={@land.form[:how].name}
            value="commits"
            checked={@land.how == :commits}
            title="The agent's commits"
            text="Merged into a branch, or as a new branch. They keep the agent's messages and authorship."
          />
        </div>
      </div>

      <div>
        <p class="mb-2 text-[11px] font-semibold uppercase tracking-wide text-faint">Where</p>
        <div class="divide-y divide-line-soft overflow-hidden rounded-lg border border-line">
          <label
            :for={{wt, i} <- Enum.with_index(@dest.worktrees)}
            id={"pull-where-wt-#{i}"}
            class={[
              "flex cursor-pointer items-center gap-3 px-3 py-2 transition-colors hover:bg-hover/40",
              @land.where == "wt:#{i}" && "bg-accent-soft/20"
            ]}
          >
            <input
              type="radio"
              name={@land.form[:where].name}
              value={"wt:#{i}"}
              checked={@land.where == "wt:#{i}"}
              class="size-3.5 border-line bg-deep text-accent"
            />
            <.icon name="hero-folder-micro" class="size-4 shrink-0 text-faint" />
            <span class="min-w-0 flex-1">
              <span class="block truncate font-mono text-[12px] text-ink" title={wt.path}>
                {wt.path}
              </span>
              <span class="text-[11px] text-faint">
                <%= if wt.branch do %>
                  on <span class="font-mono text-muted">{wt.branch}</span>
                <% else %>
                  on no branch
                <% end %>
                · {if wt.changes == 0, do: "clean", else: count(wt.changes, "file") <> " changed"}
              </span>
            </span>
            <span
              :if={wt.main?}
              class="rounded border border-line px-1.5 py-px text-[10px] text-faint"
            >
              main
            </span>
          </label>

          <label class={[
            "block cursor-pointer px-3 py-2 transition-colors hover:bg-hover/40",
            @land.where == "new_worktree" && "bg-accent-soft/20"
          ]}>
            <span class="flex items-center gap-3">
              <input
                type="radio"
                id="pull-where-new-worktree"
                name={@land.form[:where].name}
                value="new_worktree"
                checked={@land.where == "new_worktree"}
                class="size-3.5 border-line bg-deep text-accent"
              />
              <.icon name="hero-folder-plus-micro" class="size-4 shrink-0 text-faint" />
              <span class="text-[12px] text-ink">A new worktree, on a new branch</span>
            </span>
          </label>

          <label
            :if={@land.how == :commits}
            class={[
              "block cursor-pointer px-3 py-2 transition-colors hover:bg-hover/40",
              @land.where == "new_branch" && "bg-accent-soft/20"
            ]}
          >
            <span class="flex items-center gap-3">
              <input
                type="radio"
                id="pull-where-new-branch"
                name={@land.form[:where].name}
                value="new_branch"
                checked={@land.where == "new_branch"}
                class="size-3.5 border-line bg-deep text-accent"
              />
              <.icon name="hero-plus-micro" class="size-4 shrink-0 text-faint" />
              <span class="text-[12px] text-ink">A new branch, checked out nowhere</span>
            </span>
          </label>
        </div>

        <div
          :if={@land.where in ["new_worktree", "new_branch"]}
          id="pull-new"
          class="mt-2 grid gap-2 sm:grid-cols-[12rem_minmax(0,1fr)]"
        >
          <label class="block">
            <span class="mb-1 block text-[11px] text-faint">Branch</span>
            <input
              type="text"
              id="pull-new-branch"
              name={@land.form[:branch].name}
              value={@land.form[:branch].value}
              phx-debounce="300"
              autocomplete="off"
              spellcheck="false"
              class={[input_classes(), "font-mono text-xs"]}
            />
          </label>
          <label :if={@land.where == "new_worktree"} class="block">
            <span class="mb-1 block text-[11px] text-faint">
              Folder, {if @land.how == :changes,
                do: "from your #{@pull.base}",
                else: "at the agent's commit"}
            </span>
            <input
              type="text"
              id="pull-new-path"
              name={@land.form[:path].name}
              value={@land.form[:path].value}
              phx-debounce="300"
              autocomplete="off"
              spellcheck="false"
              class={[input_classes(), "font-mono text-xs"]}
            />
          </label>
        </div>
      </div>

      <div class="flex flex-wrap items-center gap-3">
        <.preview land={@land} />
        <div class="ml-auto flex items-center gap-2">
          <.button
            :if={@land.how == :changes and conflicts?(@land.preview)}
            type="submit"
            id="pull-bring-anyway"
            name="anyway"
            value="true"
            data-confirm="Bring it in with conflict markers in the files that don't merge?"
          >
            With conflict markers
          </.button>
          <.button
            type="submit"
            id="pull-bring-button"
            variant="primary"
            disabled={not ready?(@land.preview)}
            phx-disable-with="Bringing it in…"
          >
            <.icon name="hero-arrow-down-tray-micro" class="size-3.5" /> Bring it in
          </.button>
        </div>
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

  attr :land, :map, required: true

  defp preview(assigns) do
    ~H"""
    <p id="pull-preview" class="flex min-w-0 flex-1 items-start gap-1.5 text-[12px] leading-5">
      <%= case @land.preview do %>
        <% nil -> %>
          <span class="text-faint">Choose where it goes.</span>
        <% {:error, words} -> %>
          <.icon name="hero-exclamation-circle-micro" class="mt-1 size-3.5 shrink-0 text-bad" />
          <span class="text-bad">{words}</span>
        <% {:ok, %{conflicts: [_ | _] = files}} -> %>
          <.icon name="hero-exclamation-triangle-micro" class="mt-1 size-3.5 shrink-0 text-bad" />
          <span class="text-bad">
            Conflicts there in <span class="font-mono">{Enum.join(files, ", ")}</span>. {if @land.how ==
                                                                                              :commits,
                                                                                            do:
                                                                                              "Commits can't land with conflicts: send it back, or take only the changes.",
                                                                                            else: ""}
          </span>
        <% {:ok, %{up_to_date?: true}} -> %>
          <.icon name="hero-check-circle-micro" class="mt-1 size-3.5 shrink-0 text-ok-strong" />
          <span class="text-ok-strong">That branch has all of it already.</span>
        <% {:ok, %{fast_forward?: true}} -> %>
          <.icon name="hero-check-circle-micro" class="mt-1 size-3.5 shrink-0 text-ok-strong" />
          <span class="text-ok-strong">A fast-forward: the branch moves to the agent's last commit.</span>
        <% {:ok, _clean} -> %>
          <.icon name="hero-check-circle-micro" class="mt-1 size-3.5 shrink-0 text-ok-strong" />
          <span class="text-ok-strong">
            {if @land.how == :commits and @land.where |> String.starts_with?("wt:"),
              do: "Merges cleanly, with a merge commit.",
              else: "Lands cleanly."}
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

  attr :pull, :map, required: true
  attr :facts, :any, required: true
  attr :note_form, :any, required: true
  attr :vm, :any, required: true

  defp send_back(assigns) do
    ~H"""
    <.form
      for={@note_form}
      id="pull-send-back"
      phx-submit="send_back_pull"
      class="space-y-2 bg-deep/30 px-4 py-3"
    >
      <input type="hidden" name="pull" value={@pull.id} />
      <textarea
        name={@note_form[:note].name}
        id="pull-note"
        rows="2"
        placeholder="A note for the agent: what to change before it updates this pull request"
        class={[input_classes(), "min-h-[3.25rem] text-xs"]}
      >{@note_form[:note].value}</textarea>
      <div class="flex flex-wrap items-center gap-3">
        <label class="flex cursor-pointer items-center gap-1.5 text-[11px] text-muted">
          <input type="hidden" name={@note_form[:base].name} value="false" />
          <input
            type="checkbox"
            id="pull-send-base"
            name={@note_form[:base].name}
            value="true"
            checked={@facts != nil and @facts.conflicts != []}
            class="size-3.5 rounded border-line bg-deep text-accent"
          /> Send my {@pull.base} along, as host/{@pull.base}, for the agent to merge
        </label>
        <div class="ml-auto flex items-center gap-2">
          <.button
            id="pull-close"
            type="button"
            variant="ghost"
            phx-click="close_pull"
            phx-value-id={@pull.id}
            data-confirm="Close it without bringing it in? The agent is told."
          >
            Close
          </.button>
          <.button type="submit" id="pull-send-back-button">
            <.icon name="hero-arrow-uturn-left-micro" class="size-3.5" /> Send back
          </.button>
        </div>
      </div>
      <p :if={@vm.status != :running} class="text-[11px] text-faint">
        The VM isn't running: a note can go back now, your {@pull.base} only once it runs.
      </p>
    </.form>
    """
  end

  ## Commits and files

  attr :facts, :any, required: true

  defp commits(assigns) do
    ~H"""
    <section id="pull-commits" class="overflow-hidden rounded-xl border border-line bg-panel">
      <p :if={is_nil(@facts)} class="px-4 py-3 text-[13px] text-faint">No commits to show.</p>
      <ol :if={@facts} class="divide-y divide-line-soft">
        <li
          :for={commit <- @facts.commits}
          id={"pull-commit-#{String.slice(commit.sha, 0, 10)}"}
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
    <div id="pull-files" class="space-y-3">
      <p :if={is_nil(@diff)} class="text-[13px] text-faint">The change couldn't be read.</p>
      <%= if @diff do %>
        <section
          :for={{file, i} <- Enum.with_index(@diff.files)}
          id={"pull-file-#{i}"}
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
        <p :if={@diff.cut?} id="pull-diff-cut" class="text-[12px] text-faint">
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
          :merged -> "hero-check-circle"
          :closed -> "hero-x-circle"
          :changes_requested -> "hero-arrow-uturn-left"
          _open -> "hero-arrow-path-rounded-square"
        end
      }
      class={[
        @class,
        "shrink-0",
        case @status do
          :merged -> "text-violet-strong"
          :closed -> "text-bad"
          :changes_requested -> "text-warn-strong"
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
        :changes_requested -> {"Sent back", "bg-warn-soft text-warn-strong"}
        :merged -> {"Brought in", "bg-violet/15 text-violet-strong"}
        :closed -> {"Closed", "bg-bad-soft text-bad"}
      end

    assigns = assign(assigns, label: label, classes: classes)

    ~H"""
    <span
      id="pull-state"
      class={[
        "inline-flex items-center gap-1 rounded-full px-2.5 py-1 text-[12px] font-medium",
        @classes
      ]}
    >
      <.state_icon status={@status} class="size-3.5 !text-current" /> {@label}
    </span>
    """
  end

  defp who(%PullRequest{agent: agent}) when agent in [nil, ""], do: "An agent"
  defp who(%PullRequest{agent: agent}), do: agent

  defp verb(%PullRequest{status: :merged}), do: "brought in"
  defp verb(%PullRequest{status: :closed}), do: "closed"
  defp verb(%PullRequest{revision: 1}), do: "opened"
  defp verb(_pull), do: "updated"

  defp count(1, word), do: "1 #{word}"
  defp count(n, word), do: "#{n} #{word}s"
end
