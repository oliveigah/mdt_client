defmodule MDTClientWeb.SandboxLive.Projects do
  @moduledoc """
  The projects page: your repositories that have a copy in the VM, and the
  handoffs agents send back.

  A project goes one way by sync (your branches into the VM) and comes back
  only as handoffs: finished pieces of work, each reviewed whole. A handoff
  shows the agent's words apart from what MDT worked out, then the whole
  diff, and is brought into your working tree uncommitted, sent back with a
  note, or declined.
  """
  use MDTClientWeb, :html

  import MDTClientWeb.SandboxLive.Components

  alias MDTClient.Sandbox.Handoff

  @diff_lines 4_000

  attr :projects, :list, required: true
  attr :handoffs, :list, required: true

  attr :view, :any,
    required: true,
    doc: "the handoff being looked at, with its facts and diff, or nil"

  attr :vm, :any, required: true
  attr :project_form, :any, required: true
  attr :project_error, :string, default: nil
  attr :note_form, :any, required: true
  attr :now, DateTime, required: true

  def page(assigns) do
    ~H"""
    <.page_header id="projects-header" title="Projects">
      <:help>
        A project is a git repository of yours with a copy in the VM, at /work/NAME on its Work disk. No folder is shared. A sync takes your committed branches in, where they arrive as host/BRANCH. Work comes back only as handoffs: an agent wraps up a piece of work in a worktree of its own and runs mdt handoff. You review it whole and bring it into your working tree, uncommitted. Your branches are yours: nothing here commits, stages, or moves one.
      </:help>
    </.page_header>

    <div class="grid items-start gap-5 xl:grid-cols-[minmax(0,24rem)_minmax(0,1fr)]">
      <div class="space-y-5">
        <.card id="projects" title="Your repositories" body_class="">
          <:actions>
            <span class="text-[11px] text-faint">{length(@projects)}</span>
          </:actions>
          <ul id="project-list" class="divide-y divide-line-soft">
            <li :if={@projects == []}>
              <.empty icon="hero-code-bracket-square">
                No project yet. Add a repository by its top folder; the first sync copies it into the VM.
              </.empty>
            </li>
            <li :for={project <- @projects} id={"project-#{project.name}"} class="px-4 py-3">
              <div class="flex items-start gap-3">
                <.icon name="hero-code-bracket-square" class="mt-0.5 size-4 shrink-0 text-accent" />
                <div class="min-w-0 flex-1">
                  <p class="truncate text-xs font-medium text-ink">{project.name}</p>
                  <p class="truncate font-mono text-[10px] text-faint" title={project.path}>
                    {project.path}
                  </p>
                  <p class="mt-0.5 text-[10px] text-faint">
                    In the VM at /work/{project.name} ·
                    <%= if project.synced_at do %>
                      synced {ago(project.synced_at, @now)}
                    <% else %>
                      not synced yet
                    <% end %>
                  </p>
                </div>
                <button
                  type="button"
                  id={"project-remove-#{project.name}"}
                  phx-click="remove_project"
                  phx-value-name={project.name}
                  data-confirm={"Stop #{project.name} being a project? Its handoffs go. Its copy in the VM stays."}
                  title="Remove the project"
                  class="flex size-7 shrink-0 cursor-pointer items-center justify-center rounded text-faint transition-colors hover:bg-bad-soft/40 hover:text-bad"
                >
                  <.icon name="hero-x-mark" class="size-3.5" />
                </button>
              </div>
              <form
                id={"project-sync-#{project.name}"}
                phx-submit="sync_project"
                class="mt-2 flex flex-wrap items-center gap-x-3 gap-y-1.5 pl-7"
              >
                <input type="hidden" name="name" value={project.name} />
                <.button
                  type="submit"
                  id={"project-sync-button-#{project.name}"}
                  variant="primary"
                  disabled={@vm.status != :running}
                  phx-disable-with="Syncing…"
                >
                  <.icon name="hero-arrow-up-tray-micro" class="size-3.5" /> Sync
                </.button>
                <label class="flex cursor-pointer items-center gap-1.5 text-[11px] text-muted">
                  <input
                    type="checkbox"
                    name="uncommitted"
                    value="true"
                    class="size-3.5 rounded border-line bg-deep text-accent"
                  /> with what I haven't committed
                </label>
              </form>
            </li>
          </ul>
          <p
            :if={@projects != [] and @vm.status != :running}
            id="projects-vm-off"
            class="border-t border-line-soft px-4 py-2 text-[11px] text-warn-strong"
          >
            The VM isn't running, so nothing can be synced or handed off.
          </p>
          <.form
            for={@project_form}
            id="project-form"
            phx-submit="add_project"
            class="border-t border-line-soft bg-deep/30 px-4 py-3"
          >
            <div class="flex items-center gap-2">
              <input
                type="text"
                name={@project_form[:path].name}
                id="project-path"
                value={@project_form[:path].value}
                placeholder="a repository's top folder: ~/projects/app"
                autocomplete="off"
                spellcheck="false"
                class={[input_classes(), "font-mono text-xs", @project_error && "border-bad/70"]}
              />
              <.button type="submit" id="project-add">
                <.icon name="hero-plus-micro" class="size-3.5" /> Add
              </.button>
            </div>
            <p
              :if={@project_error}
              id="project-error"
              class="mt-2 flex items-start gap-1.5 text-[11px] leading-4 text-bad"
            >
              <.icon name="hero-exclamation-circle-micro" class="mt-px size-3.5 shrink-0" />
              {@project_error}
            </p>
          </.form>
        </.card>

        <.card id="handoffs" title="Handoffs" body_class="">
          <:actions>
            <span class="text-[11px] text-faint">
              {Enum.count(@handoffs, &(&1.status == :waiting))} waiting
            </span>
          </:actions>
          <ul id="handoff-list" class="divide-y divide-line-soft">
            <li :if={@handoffs == []}>
              <.empty icon="hero-inbox-arrow-down">
                Nothing handed off yet. Agents run mdt handoff in a worktree of their own when a piece of work is ready.
              </.empty>
            </li>
            <li :for={handoff <- sorted(@handoffs)} id={"handoff-row-#{handoff.id}"}>
              <.link
                patch={~p"/tools/sandbox/projects?handoff=#{handoff.id}"}
                class={[
                  "flex items-start gap-3 px-4 py-2.5 transition-colors hover:bg-hover/40",
                  @view && @view.handoff.id == handoff.id && "bg-hover/60"
                ]}
              >
                <div class="min-w-0 flex-1">
                  <p class={[
                    "truncate text-xs font-medium",
                    if(handoff.status == :waiting, do: "text-ink", else: "text-muted")
                  ]}>
                    {handoff.title}
                  </p>
                  <p class="truncate text-[10px] text-faint">
                    {who(handoff)} · {handoff.project} · {handoff.branch} · {ago(handoff.at, @now)}
                  </p>
                </div>
                <.status status={handoff.status} />
              </.link>
            </li>
          </ul>
        </.card>
      </div>

      <div id="handoff-panel">
        <%= if @view do %>
          <.detail view={@view} note_form={@note_form} now={@now} />
        <% else %>
          <div class="rounded-xl border border-dashed border-line">
            <.empty id="handoff-none" icon="hero-document-magnifying-glass">
              Choose a handoff to see what the agent says, what MDT worked out, and the whole change.
            </.empty>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr :view, :map, required: true
  attr :note_form, :any, required: true
  attr :now, DateTime, required: true

  defp detail(assigns) do
    ~H"""
    <.card
      id="handoff"
      title={@view.handoff.title}
      subtitle={"#{who(@view.handoff)} · #{@view.handoff.project} · #{@view.handoff.branch} at #{String.slice(@view.handoff.commit, 0, 10)} · #{ago(@view.handoff.at, @now)}"}
      body_class=""
    >
      <:actions>
        <.status status={@view.handoff.status} />
      </:actions>

      <div class="space-y-4 p-4">
        <section id="handoff-claims" class="rounded-lg border border-line-soft bg-deep/40 p-3">
          <p class="mb-1.5 text-[10px] font-semibold uppercase tracking-wide text-faint">
            The agent says
          </p>
          <%!-- White space is kept, so the text sits tight against its tags. --%>
          <p
            :if={@view.handoff.body != ""}
            class="whitespace-pre-wrap break-words text-xs leading-5 text-ink"
            phx-no-format
          >{@view.handoff.body}</p>
          <p :if={@view.handoff.body == ""} class="text-xs text-faint">It gave no description.</p>
          <ul :if={@view.facts && @view.facts.messages != []} class="mt-2 space-y-0.5">
            <li
              :for={message <- @view.facts.messages}
              class="truncate font-mono text-[11px] text-muted"
            >
              {message}
            </li>
          </ul>
        </section>

        <section :if={@view.facts} id="handoff-facts" class="space-y-2">
          <p class="text-[10px] font-semibold uppercase tracking-wide text-faint">
            What MDT worked out
          </p>
          <p class="text-xs text-ink">
            {count(@view.facts.commits, "commit")} · {count(length(@view.facts.files), "file")}
            <span class="font-mono text-ok-strong">+{@view.facts.added}</span>
            <span class="font-mono text-bad">−{@view.facts.removed}</span>
            ·
            <%= if @view.facts.behind == 0 do %>
              built on your branch as it is now
            <% else %>
              your branch has {count(@view.facts.behind, "commit")} it doesn't have
            <% end %>
          </p>
          <%= if @view.handoff.status == :waiting do %>
            <p
              :if={@view.facts.conflicts == []}
              id="handoff-merges"
              class="flex items-center gap-1.5 text-xs text-ok-strong"
            >
              <.icon name="hero-check-circle-micro" class="size-3.5" />
              It merges with your working tree as it is now.
            </p>
            <p
              :if={@view.facts.conflicts != []}
              id="handoff-conflicts"
              class="flex items-start gap-1.5 text-xs leading-5 text-bad"
            >
              <.icon name="hero-exclamation-triangle-micro" class="mt-0.5 size-3.5 shrink-0" />
              <span>
                It doesn't merge with what you have in <span class="font-mono">{Enum.join(@view.facts.conflicts, ", ")}</span>. Send it back for the agent to bring up to date, or bring it anyway with conflict markers.
              </span>
            </p>
          <% end %>
          <ul :if={@view.facts.hints != []} id="handoff-hints" class="space-y-0.5">
            <li
              :for={hint <- @view.facts.hints}
              class="flex items-start gap-1.5 text-[11px] leading-4 text-warn-strong"
            >
              <.icon name="hero-light-bulb-micro" class="mt-px size-3.5 shrink-0" /> {hint}
            </li>
          </ul>
          <ul id="handoff-files" class="divide-y divide-line-soft rounded-lg border border-line-soft">
            <li
              :for={file <- @view.facts.files}
              class="flex items-center gap-3 px-3 py-1.5 font-mono text-[11px]"
            >
              <span class="min-w-0 flex-1 truncate text-ink" title={file.path}>{file.path}</span>
              <span :if={file.added} class="text-ok-strong">+{file.added}</span>
              <span :if={file.removed} class="text-bad">−{file.removed}</span>
              <span :if={is_nil(file.added)} class="text-faint">binary</span>
            </li>
          </ul>
        </section>

        <section id="handoff-actions" class="border-t border-line-soft pt-4">
          <%= case @view.handoff.status do %>
            <% :waiting -> %>
              <div class="flex flex-wrap items-center gap-2">
                <.button
                  id="handoff-bring"
                  variant="primary"
                  phx-click="bring_handoff"
                  phx-value-id={@view.handoff.id}
                  disabled={@view.facts == nil or @view.facts.conflicts != []}
                  phx-disable-with="Bringing…"
                >
                  <.icon name="hero-arrow-down-tray-micro" class="size-3.5" />
                  Bring it into my working tree
                </.button>
                <.button
                  :if={@view.facts && @view.facts.conflicts != []}
                  id="handoff-bring-anyway"
                  phx-click="bring_handoff"
                  phx-value-id={@view.handoff.id}
                  phx-value-anyway="true"
                  data-confirm="Bring it in with conflict markers in the files that don't merge?"
                >
                  Bring it anyway
                </.button>
                <.button
                  id="handoff-decline"
                  variant="ghost"
                  phx-click="decline_handoff"
                  phx-value-id={@view.handoff.id}
                  data-confirm="Decline this handoff? The agent is told."
                >
                  Decline
                </.button>
              </div>
              <p class="mt-2 text-[11px] leading-4 text-faint">
                It comes whole, as uncommitted changes merged with what you have. Nothing is committed or staged, and no branch of yours moves. Undo puts your working tree back.
              </p>
              <.form
                for={@note_form}
                id="handoff-send-back"
                phx-submit="send_back_handoff"
                class="mt-3 flex items-start gap-2"
              >
                <input type="hidden" name="handoff" value={@view.handoff.id} />
                <textarea
                  name={@note_form[:note].name}
                  id="handoff-note"
                  rows="2"
                  placeholder="A note for the agent: what to change before handing it off again"
                  class={[input_classes(), "min-h-[3.25rem] flex-1 text-xs"]}
                >{@note_form[:note].value}</textarea>
                <.button type="submit" id="handoff-send-back-button">
                  <.icon name="hero-arrow-uturn-left-micro" class="size-3.5" /> Send back
                </.button>
              </.form>
            <% :brought -> %>
              <div class="flex flex-wrap items-center gap-3">
                <p class="flex min-w-0 flex-1 items-center gap-1.5 text-xs text-ok-strong">
                  <.icon name="hero-check-circle-micro" class="size-3.5 shrink-0" />
                  In your working tree, uncommitted: {count(length(@view.handoff.undo.paths), "file")}. Commit it when you are ready.
                </p>
                <.button
                  id="handoff-undo"
                  phx-click="undo_handoff"
                  phx-value-id={@view.handoff.id}
                  data-confirm="Put your working tree back as it was before bringing this in? Changes you made to those files since are lost."
                >
                  <.icon name="hero-arrow-uturn-left-micro" class="size-3.5" /> Undo
                </.button>
              </div>
            <% :sent_back -> %>
              <p class="text-xs text-muted">
                Sent back {ago(@view.handoff.decided_at, @now)}
                <span :if={@view.handoff.note not in [nil, ""]}>
                  with: <span class="text-ink">{@view.handoff.note}</span>
                </span>
              </p>
            <% :declined -> %>
              <p class="text-xs text-muted">Declined {ago(@view.handoff.decided_at, @now)}.</p>
            <% :replaced -> %>
              <p class="text-xs text-muted">
                Replaced by a later handoff of the same branch.
              </p>
          <% end %>
        </section>
      </div>

      <section :if={@view.diff} id="handoff-diff" class="border-t border-line-soft">
        <p class="px-4 pt-3 text-[10px] font-semibold uppercase tracking-wide text-faint">
          The whole change
        </p>
        <div
          id="handoff-diff-text"
          class="max-h-[60vh] overflow-auto px-4 py-3 font-mono text-[11px] leading-[1.45]"
        >
          <div
            :for={{line, tone} <- diff_lines(@view.diff)}
            class={["min-h-[1.45em] whitespace-pre", tone]}
            phx-no-format
          >{line}</div>
        </div>
      </section>
    </.card>
    """
  end

  attr :status, :atom, required: true

  defp status(assigns) do
    {label, classes} =
      case assigns.status do
        :waiting -> {"Waiting", "bg-accent-soft/60 text-accent-strong"}
        :brought -> {"In your tree", "bg-ok-soft/60 text-ok-strong"}
        :sent_back -> {"Sent back", "bg-warn-soft/60 text-warn-strong"}
        :declined -> {"Declined", "bg-bad-soft/60 text-bad"}
        :replaced -> {"Replaced", "bg-deep text-faint"}
      end

    assigns = assign(assigns, label: label, classes: classes)

    ~H"""
    <span class={[
      "shrink-0 rounded px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide",
      @classes
    ]}>
      {@label}
    </span>
    """
  end

  @doc "Waiting handoffs first, then the rest, each newest first."
  @spec sorted([Handoff.t()]) :: [Handoff.t()]
  def sorted(handoffs) do
    {waiting, rest} = Enum.split_with(handoffs, &(&1.status == :waiting))
    newest = &Enum.sort_by(&1, fn handoff -> handoff.at end, {:desc, DateTime})
    newest.(waiting) ++ newest.(rest)
  end

  defp who(%Handoff{agent: agent}) when agent in [nil, ""], do: "An agent"
  defp who(%Handoff{agent: agent}), do: agent

  defp count(1, word), do: "1 #{word}"
  defp count(n, word), do: "#{n} #{word}s"

  # Each line of a diff with the colour that says what it is.
  defp diff_lines(diff) do
    lines = String.split(diff, "\n")
    {shown, rest} = Enum.split(lines, @diff_lines)

    Enum.map(shown, &{&1, tone(&1)}) ++
      if(rest == [],
        do: [],
        else: [{"… #{length(rest)} more lines; see the rest with git diff", "text-faint"}]
      )
  end

  defp tone("+++" <> _), do: "text-faint"
  defp tone("---" <> _), do: "text-faint"
  defp tone("diff --git" <> _), do: "font-semibold text-ink"
  defp tone("@@" <> _), do: "text-accent"
  defp tone("+" <> _), do: "text-ok-strong"
  defp tone("-" <> _), do: "text-bad"
  defp tone(_context), do: "text-muted"
end
