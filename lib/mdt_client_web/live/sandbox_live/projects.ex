defmodule MDTClientWeb.SandboxLive.Projects do
  @moduledoc """
  The projects page: every git repository in your shared folders, each
  opened in Zed from here, with its worktree slots: which are free, and
  which task branch and handoff each of the others holds.

  Shared folders decide what the VM sees, so the page lists them, each
  with the repositories found in it (`MDTClient.Sandbox.Discovery`). The
  first time you open one, MDT makes its mirror at `/work/<name>`; from
  then on it shows the mirror, its target branches, its settings, its
  worktree slots and any other worktrees it has. A repository in a read-write share is listed but can't
  be opened, and the page says why.
  """
  use MDTClientWeb, :html

  import MDTClientWeb.SandboxLive.Components

  alias MDTClient.Sandbox.{Slots, Zed}

  attr :overview, :map, required: true, doc: "from `MDTClient.Sandbox.Projects.overview/1`"
  attr :mirror, :map, required: true
  attr :handoffs, :list, required: true
  attr :open, :any, required: true, doc: "the path of the repository shown in full, or nil"
  attr :settings, :any, required: true, doc: "the open project's settings form, or nil"

  attr :worktrees, :map,
    required: true,
    doc: "project name => its slots and other worktrees, as last read (`Projects.slots/2`)"

  attr :vm, :any, required: true
  attr :now, DateTime, required: true

  def page(assigns) do
    ~H"""
    <.page_header id="projects-header" title="Projects">
      <:help>
        Every git repository in a folder you share is a project. Open one in Zed: the first time, MDT makes its mirror at /work/NAME, your target branch as committed, kept current while the VM runs and view only. Agents work beside it in a few fixed worktree slots, one task branch at a time (mdt worktree new TASK), catch up with your branch (git merge host) and hand their work off (mdt handoff). Only committed work travels; nothing of your working tree.
      </:help>
      <:actions>
        <.button id="projects-rescan" variant="ghost" phx-click="rescan_projects">
          <.icon name="hero-arrow-path-micro" class="size-3.5" /> Look again
        </.button>
      </:actions>
    </.page_header>

    <div class="space-y-5">
      <p
        :if={@vm.status != :running and @overview.shared != []}
        id="projects-vm-off"
        class="flex items-center gap-2 rounded-lg border border-line bg-panel px-3 py-2 text-[12px] text-muted"
      >
        <.icon name="hero-information-circle-micro" class="size-4 text-faint" />
        Start the VM to open a project: its mirror and worktrees live in the VM.
      </p>

      <div :if={@overview.shared == []} class="rounded-xl border border-dashed border-line">
        <.empty id="projects-no-shares" icon="hero-folder-open">
          No shared folder yet. Every git repository in a folder you share is a project: <.link
            navigate={~p"/tools/sandbox/settings"}
            class="text-accent hover:underline"
          >
            share one, read-only
          </.link>.
        </.empty>
      </div>

      <section
        :for={%{share: share, repos: repos} <- @overview.shared}
        id={"share-#{key(share.path)}"}
        class="overflow-hidden rounded-xl border border-line bg-panel"
      >
        <header class="flex flex-wrap items-center gap-2 border-b border-line-soft bg-deep/40 px-4 py-2.5">
          <.icon name="hero-folder-open-micro" class="size-4 text-faint" />
          <span class="min-w-0 truncate font-mono text-[12px] text-ink" title={share.path}>
            {share.path}
          </span>
          <span class={[
            "rounded px-1.5 py-px text-[10px] font-semibold uppercase tracking-wide",
            if(share.mode == :ro,
              do: "bg-ok-soft/60 text-ok-strong",
              else: "bg-warn-soft/60 text-warn-strong"
            )
          ]}>
            {if share.mode == :ro, do: "read-only", else: "read-write"}
          </span>
          <span class="ml-auto text-[11px] text-faint">{count(length(repos), "repository")}</span>
        </header>
        <p
          :if={share.mode == :rw}
          id={"share-writable-#{key(share.path)}"}
          class="flex items-start gap-2 border-b border-line-soft bg-warn-soft/20 px-4 py-2 text-[12px] leading-5 text-warn-strong"
        >
          <.icon name="hero-exclamation-triangle-micro" class="mt-0.5 size-4 shrink-0" />
          <span>
            The VM can write this folder, so MDT won't run git in these repositories: a hook planted in their .git would run here, as you. Make the folder read-only in
            <.link navigate={~p"/tools/sandbox/settings"} class="underline">
              Settings
            </.link>
            (the VM is recreated). Agents don't need to write it: they work in worktrees in the VM and hand off.
          </span>
        </p>
        <p :if={repos == []} class="px-4 py-3 text-[12px] text-faint">
          No git repository in this folder.
        </p>
        <ul class="divide-y divide-line-soft">
          <.repo
            :for={repo <- repos}
            repo={repo}
            share={share}
            mirror={repo.project && @mirror[repo.project.name]}
            handoffs={
              (repo.project && Enum.filter(@handoffs, &(&1.project == repo.project.name))) || []
            }
            open?={@open == repo.path}
            settings={@settings}
            worktrees={repo.project && @worktrees[repo.project.name]}
            vm={@vm}
            now={@now}
          />
        </ul>
      </section>

      <section
        :if={@overview.unshared != []}
        id="projects-unshared"
        class="overflow-hidden rounded-xl border border-line bg-panel"
      >
        <header class="border-b border-line-soft bg-deep/40 px-4 py-2.5">
          <p class="text-[12px] font-medium text-ink">No longer in a shared folder</p>
          <p class="text-[11px] text-faint">
            MDT stopped keeping their mirrors current. Their mirrors and worktrees stay in the VM.
          </p>
        </header>
        <ul class="divide-y divide-line-soft">
          <li
            :for={project <- @overview.unshared}
            id={"project-unshared-#{project.name}"}
            class="flex items-center gap-3 px-4 py-2.5"
          >
            <.icon name="hero-code-bracket-square-micro" class="size-4 text-faint" />
            <div class="min-w-0 flex-1">
              <p class="text-[13px] text-muted">{project.name}</p>
              <p class="truncate font-mono text-[11px] text-faint">{project.path}</p>
            </div>
            <.button
              id={"project-forget-#{project.name}"}
              variant="ghost"
              phx-click="forget_project"
              phx-value-name={project.name}
              data-confirm={"Forget #{project.name}'s settings? Its mirror and worktrees stay in the VM."}
            >
              Forget
            </.button>
          </li>
        </ul>
      </section>
    </div>
    """
  end

  attr :repo, :map, required: true
  attr :share, :map, required: true
  attr :mirror, :any, required: true
  attr :handoffs, :list, required: true
  attr :open?, :boolean, required: true
  attr :settings, :any, required: true
  attr :worktrees, :any, required: true
  attr :vm, :any, required: true
  attr :now, DateTime, required: true

  defp repo(assigns) do
    assigns =
      assign(assigns,
        id: key(assigns.repo.path),
        project: assigns.repo.project,
        relative: Path.relative_to(assigns.repo.path, assigns.share.path),
        open_count: Enum.count(assigns.handoffs, &(&1.status in [:open, :sent_back]))
      )

    ~H"""
    <li id={"repo-#{@id}"}>
      <div class="flex flex-wrap items-center gap-3 px-4 py-2.5">
        <span class={[
          "flex size-7 shrink-0 items-center justify-center rounded-md",
          if(@project, do: "bg-accent-soft/50 text-accent", else: "bg-deep text-faint")
        ]}>
          <.icon name="hero-code-bracket-square-micro" class="size-4" />
        </span>
        <div class="min-w-0 flex-1">
          <p class="truncate text-[13px] font-medium text-ink">
            {if @project, do: @project.name, else: @repo.name}
            <span
              :if={@relative != @repo.name}
              class="font-mono text-[11px] font-normal text-faint"
            >
              {@relative}
            </span>
          </p>
          <p id={"repo-state-#{@id}"} class="truncate text-[11px] text-faint">
            <%= cond do %>
              <% @project -> %>
                <.mirror_line project={@project} mirror={@mirror} vm={@vm} now={@now} />
              <% @repo.branch -> %>
                on <span class="font-mono">{@repo.branch}</span> · not opened yet
              <% true -> %>
                on no branch · not opened yet
            <% end %>
          </p>
        </div>
        <.link
          :if={@open_count > 0}
          patch={~p"/tools/sandbox/handoffs"}
          class="rounded-full bg-accent-soft px-1.5 py-px text-[10px] font-semibold text-accent-strong"
          title="Open handoffs"
        >
          {@open_count} open
        </.link>
        <.button
          :if={@project}
          id={"repo-toggle-#{@id}"}
          variant="ghost"
          phx-click="toggle_project"
          phx-value-path={@repo.path}
          title="Settings and worktree slots"
        >
          <.icon name="hero-cog-6-tooth-micro" class="size-3.5" />
          <.icon
            name={if @open?, do: "hero-chevron-up-micro", else: "hero-chevron-down-micro"}
            class="size-3"
          />
        </.button>
        <.button
          id={"repo-zed-#{@id}"}
          variant={if @project, do: "primary", else: "secondary"}
          class="whitespace-nowrap"
          phx-click="open_project"
          phx-value-path={@repo.path}
          disabled={@vm.status != :running or @share.mode == :rw}
          phx-disable-with="Opening…"
        >
          <.icon name="hero-code-bracket-square-micro" class="size-3.5" /> Open in Zed
        </.button>
      </div>

      <div
        :if={@open? and @project}
        id={"project-#{@project.name}"}
        class="border-t border-line-soft"
      >
        <.settings_form project={@project} settings={@settings} />
        <.worktree_list project={@project} worktrees={@worktrees} handoffs={@handoffs} vm={@vm} />
      </div>
    </li>
    """
  end

  attr :project, :map, required: true
  attr :mirror, :any, required: true
  attr :vm, :any, required: true
  attr :now, DateTime, required: true

  defp mirror_line(assigns) do
    ~H"""
    <%= cond do %>
      <% @mirror && @mirror.error -> %>
        <span class="text-bad">The mirror failed: {@mirror.error}</span>
      <% @mirror -> %>
        <span class="inline-flex items-center gap-1.5">
          <span class="size-1.5 rounded-full bg-ok"></span>
          mirror /work/{@project.name} on <span class="font-mono">{@mirror.default}</span>
          at <span class="font-mono">{String.slice(@mirror.tips[@mirror.default] || "", 0, 7)}</span>
          · {ago(@mirror.at, @now)}
          <span :if={@mirror.rescued} class="text-warn-strong">
            · edits found in it kept as {@mirror.rescued}
          </span>
        </span>
      <% @vm.status != :running -> %>
        mirror /work/{@project.name} · brought up to date when the VM runs
      <% true -> %>
        mirror /work/{@project.name} · being brought up to date…
    <% end %>
    """
  end

  attr :project, :map, required: true
  attr :settings, :any, required: true

  defp settings_form(assigns) do
    ~H"""
    <.form
      :if={@settings}
      for={@settings.form}
      id={"project-settings-form-#{@project.name}"}
      phx-submit="save_project"
      class="space-y-3 bg-deep/30 px-4 py-3"
    >
      <input type="hidden" name="name" value={@project.name} />
      <div>
        <p class="mb-1 text-[11px] font-medium text-ink">Target branches</p>
        <p class="mb-2 text-[11px] text-faint">
          Where handoffs may go, each kept current in the VM as host/BRANCH. The default is the mirror's, and where agents hand off unless they name another.
        </p>
        <div class="flex flex-wrap gap-x-4 gap-y-1.5">
          <label
            :for={branch <- @settings.branches}
            class="flex cursor-pointer items-center gap-1.5 font-mono text-[12px] text-muted"
          >
            <input
              type="checkbox"
              name="project[targets][]"
              value={branch}
              checked={branch in @project.targets}
              class="size-3.5 rounded border-line bg-deep text-accent"
            />
            {branch}
          </label>
        </div>
      </div>
      <div class="flex flex-wrap items-end gap-4">
        <label class="block">
          <span class="mb-1 block text-[11px] font-medium text-ink">Default</span>
          <select
            name="project[default_target]"
            class={[input_classes(), "w-48 font-mono text-xs"]}
          >
            <option
              :for={branch <- @settings.branches}
              value={branch}
              selected={branch == @project.default_target}
            >
              {branch}
            </option>
          </select>
        </label>
        <label class="block">
          <span class="mb-1 block text-[11px] font-medium text-ink">Worktree slots</span>
          <input
            type="number"
            id={"project-slots-input-#{@project.name}"}
            name="project[slots]"
            value={@project.slots}
            min="1"
            max="9"
            class={[input_classes(), "w-20 font-mono text-xs"]}
          />
        </label>
        <label class="block">
          <span class="mb-1 block text-[11px] font-medium text-ink">Accept as</span>
          <select name="project[accept]" class={[input_classes(), "w-48 text-xs"]}>
            <option value="commits" selected={@project.accept == :commits}>
              The agent's commits
            </option>
            <option value="changes" selected={@project.accept == :changes}>
              Only the changes
            </option>
          </select>
        </label>
        <.button type="submit" id={"project-save-#{@project.name}"} variant="primary">
          Save
        </.button>
      </div>
      <p
        :if={@settings.error}
        id={"project-settings-error-#{@project.name}"}
        class="text-[11px] text-bad"
      >
        {@settings.error}
      </p>
    </.form>
    """
  end

  attr :project, :map, required: true
  attr :worktrees, :any, required: true, doc: "`Projects.slots/2`'s answer, or nil"
  attr :handoffs, :list, required: true
  attr :vm, :any, required: true

  defp worktree_list(assigns) do
    assigns =
      assign(assigns,
        look: match?({:ok, _}, assigns.worktrees) && elem(assigns.worktrees, 1)
      )

    ~H"""
    <div class="border-t border-line-soft">
      <div class="flex items-baseline gap-2 px-4 pt-3">
        <p class="text-[10px] font-semibold uppercase tracking-wide text-faint">
          Worktree slots
        </p>
        <p :if={@look} id={"project-slots-free-#{@project.name}"} class="text-[11px] text-faint">
          {Enum.count(@look.slots, & &1.free?)} of {length(@look.slots)} free
        </p>
      </div>
      <%= cond do %>
        <% @vm.status != :running -> %>
          <p class="px-4 pt-1 pb-3 text-[12px] text-faint">Shown while the VM runs.</p>
        <% !@look -> %>
          <p id={"project-slots-error-#{@project.name}"} class="px-4 pt-1 pb-3 text-[12px] text-bad">
            {slots_error(@worktrees)}
          </p>
        <% true -> %>
          <p class="px-4 pt-0.5 text-[11px] leading-5 text-faint">
            Fixed folders, made with the mirror, that agents take one task at a time (mdt worktree new TASK), each task on a branch of its own. What git ignores stays between tasks, so builds stay warm. A slot is free again once its handoff is accepted or closed.
          </p>
          <ul id={"project-slots-#{@project.name}"} class="mt-1 divide-y divide-line-soft">
            <li
              :for={slot <- @look.slots}
              id={"slot-#{@project.name}-#{slot.name}"}
              class="group flex items-center gap-3 px-4 py-2 transition-colors hover:bg-deep/30"
            >
              <span class={["size-2 shrink-0 rounded-full", slot_dot(slot)]}></span>
              <div class="min-w-0 flex-1">
                <p class="flex items-center gap-2 text-[12px]" title={slot.path}>
                  <span class="font-mono text-ink">{slot.name}</span>
                  <span
                    id={"slot-state-#{@project.name}-#{slot.name}"}
                    class={[
                      "rounded px-1.5 py-px text-[10px] font-semibold uppercase tracking-wide",
                      slot_badge_class(slot)
                    ]}
                  >
                    {slot_badge(slot)}
                  </span>
                </p>
                <p class="truncate text-[11px] text-faint">
                  <%= cond do %>
                    <% slot.state == :absent -> %>
                      not made yet: the first task to take it makes it
                    <% slot.state == :missing -> %>
                      its folder is gone; made again when taken
                      <span :if={slot.branch}>
                        · the branch <span class="font-mono">{slot.branch}</span> stays
                      </span>
                    <% slot.state == :foreign -> %>
                      <span class="text-bad">
                        a folder that isn't a worktree of the project is in the way
                      </span>
                    <% is_nil(slot.branch) -> %>
                      on no branch · ready for the next task
                    <% true -> %>
                      <span class="font-mono text-muted">{slot.branch}</span>
                      ·
                      <%= case slot.handoff do %>
                        <% nil -> %>
                          no handoff yet
                        <% handoff -> %>
                          <.link
                            patch={~p"/tools/sandbox/handoffs?id=#{handoff.id}"}
                            class="text-accent hover:underline"
                          >
                            {handoff_label(handoff)}
                          </.link>
                      <% end %>
                      <span :if={slot.state == :dirty} class="text-warn-strong">
                        · uncommitted work
                      </span>
                  <% end %>
                </p>
              </div>
              <.button
                id={"slot-zed-#{@project.name}-#{slot.name}"}
                variant="ghost"
                phx-click="open_project"
                phx-value-path={@project.name}
                phx-value-folder={slot.path}
                disabled={slot.state in [:absent, :missing, :foreign]}
                title={Zed.command(slot.path)}
              >
                <.icon name="hero-arrow-top-right-on-square-micro" class="size-3.5" /> Zed
              </.button>
            </li>
          </ul>
          <div :if={@look.others != []}>
            <p class="px-4 pt-3 text-[10px] font-semibold uppercase tracking-wide text-faint">
              Other worktrees
            </p>
            <ul id={"project-worktrees-#{@project.name}"} class="mt-1 divide-y divide-line-soft">
              <li :for={wt <- @look.others} class="flex items-center gap-3 px-4 py-2">
                <.icon name="hero-folder-micro" class="size-4 shrink-0 text-faint" />
                <div class="min-w-0 flex-1">
                  <p class="truncate font-mono text-[12px] text-ink" title={wt.path}>
                    {Path.basename(wt.path)}
                  </p>
                  <p class="truncate text-[11px] text-faint">
                    {wt.branch || "no branch"}
                    <span :if={wt.missing?} class="text-warn-strong">· its folder is gone</span>
                    <%= case wt.branch && handoff_of(@handoffs, wt.branch) do %>
                      <% nil -> %>
                      <% handoff -> %>
                        ·
                        <.link
                          patch={~p"/tools/sandbox/handoffs?id=#{handoff.id}"}
                          class="text-accent hover:underline"
                        >
                          {handoff_label(handoff)}
                        </.link>
                    <% end %>
                  </p>
                </div>
                <.button
                  variant="ghost"
                  phx-click="open_project"
                  phx-value-path={@project.name}
                  phx-value-folder={wt.path}
                  disabled={wt.missing?}
                  title={Zed.command(wt.path)}
                >
                  <.icon name="hero-arrow-top-right-on-square-micro" class="size-3.5" /> Zed
                </.button>
              </li>
            </ul>
          </div>
          <div class="h-2"></div>
      <% end %>
    </div>
    """
  end

  defp slots_error({:error, reason}), do: MDTClient.Sandbox.Projects.explain(reason)
  defp slots_error(_), do: "The worktree slots couldn't be read."

  defp slot_badge(%{state: :dirty}), do: "uncommitted"
  defp slot_badge(%{state: :foreign}), do: "in the way"
  defp slot_badge(%{free?: true}), do: "free"
  defp slot_badge(_slot), do: "busy"

  defp slot_badge_class(%{state: :dirty}), do: "bg-warn-soft/60 text-warn-strong"
  defp slot_badge_class(%{state: :foreign}), do: "bg-bad-soft/40 text-bad"
  defp slot_badge_class(%{free?: true}), do: "bg-ok-soft/60 text-ok-strong"
  defp slot_badge_class(_slot), do: "bg-accent-soft/50 text-accent-strong"

  defp slot_dot(%{state: :dirty}), do: "bg-warn"
  defp slot_dot(%{state: :foreign}), do: "bg-bad"
  defp slot_dot(%{free?: true}), do: "bg-ok"
  defp slot_dot(_slot), do: "bg-accent"

  @doc "A short id for a path, for DOM ids."
  @spec key(Path.t()) :: String.t()
  def key(path),
    do: :crypto.hash(:sha256, path) |> Base.encode16(case: :lower) |> binary_part(0, 12)

  # The open handoff of a branch, or its latest.
  defp handoff_of(handoffs, branch) do
    handoffs
    |> Enum.filter(&(&1.source.branch == branch))
    |> Enum.sort_by(&{&1.status in [:open, :sent_back], &1.id}, :desc)
    |> List.first()
  end

  defp handoff_label(handoff) do
    conflicts? = (handoff.stats[:conflicts] || 0) > 0 and handoff.status in [:open, :sent_back]

    "handoff ##{handoff.id}, #{Slots.status_word(handoff.status)}" <>
      if(conflicts?, do: ", conflicts", else: "")
  end

  defp count(1, word), do: "1 #{word}"
  defp count(n, "repository"), do: "#{n} repositories"
  defp count(n, word), do: "#{n} #{word}s"
end
