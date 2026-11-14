defmodule MDTClientWeb.SandboxLive.Projects do
  @moduledoc """
  The projects page: your repositories that MDT mirrors into the VM, each
  opened in Zed from here.

  Opening a repository makes it a project: its mirror at `/work/<name>`,
  your target branch kept current there, view only. Each project shows its
  mirror, its target branches and how handoffs are accepted by default,
  and its agent worktrees, each one thread's place to work, with the
  handoff it sent.
  """
  use MDTClientWeb, :html

  import MDTClientWeb.SandboxLive.Components

  alias MDTClient.Sandbox.Zed

  attr :projects, :list, required: true
  attr :mirror, :map, required: true
  attr :handoffs, :list, required: true
  attr :worktrees, :map, required: true, doc: "project name => its agent worktrees, as last read"
  attr :settings, :any, required: true, doc: "the project whose settings are open, with its form"
  attr :suggestions, :list, required: true, doc: "repositories open in the Git tool, not projects"
  attr :form, :any, required: true
  attr :error, :string, default: nil
  attr :vm, :any, required: true
  attr :now, DateTime, required: true

  def page(assigns) do
    ~H"""
    <.page_header id="projects-header" title="Projects">
      <:help>
        A project is a git repository of yours that MDT mirrors into the VM. Open one here: its mirror, at /work/NAME, is your target branch as committed, kept current while the VM runs, and view only. Agents work in worktrees of their own beside it (mdt worktree new TASK), catch up with your branch (git merge host), and hand their work off with mdt handoff. Only committed work travels; nothing of your working tree.
      </:help>
    </.page_header>

    <div class="space-y-5">
      <section id="project-open" class="rounded-xl border border-line bg-panel p-4">
        <.form for={@form} id="project-form" phx-submit="open_repository">
          <label for="project-path" class="mb-1.5 block text-[12px] font-medium text-ink">
            Open a repository in the VM
          </label>
          <div class="flex items-center gap-2">
            <input
              type="text"
              name={@form[:path].name}
              id="project-path"
              value={@form[:path].value}
              placeholder="~/projects/app"
              autocomplete="off"
              spellcheck="false"
              class={[input_classes(), "font-mono text-xs", @error && "border-bad/70"]}
            />
            <.button
              type="submit"
              id="project-open-button"
              variant="primary"
              class="shrink-0 whitespace-nowrap"
              disabled={@vm.status != :running}
              phx-disable-with="Opening…"
            >
              <.icon name="hero-code-bracket-square-micro" class="size-3.5" /> Open in Zed
            </.button>
          </div>
        </.form>
        <p
          :if={@error}
          id="project-error"
          class="mt-2 flex items-start gap-1.5 text-[11px] leading-4 text-bad"
        >
          <.icon name="hero-exclamation-circle-micro" class="mt-px size-3.5 shrink-0" /> {@error}
        </p>
        <p :if={@vm.status != :running} class="mt-2 text-[11px] text-faint">
          Start the VM to open a repository: its mirror is made in the VM.
        </p>
        <div
          :if={@suggestions != []}
          id="project-suggestions"
          class="mt-3 flex flex-wrap items-center gap-1.5"
        >
          <span class="text-[11px] text-faint">Open in the Git tool:</span>
          <button
            :for={path <- @suggestions}
            type="button"
            phx-click="open_repository"
            phx-value-path={path}
            disabled={@vm.status != :running}
            class="cursor-pointer rounded-full border border-line bg-deep px-2.5 py-0.5 font-mono text-[11px] text-muted transition-colors hover:border-accent/50 hover:text-ink disabled:cursor-not-allowed disabled:opacity-50"
            title={path}
          >
            {Path.basename(path)}
          </button>
        </div>
      </section>

      <div :if={@projects == []} class="rounded-xl border border-dashed border-line">
        <.empty id="projects-empty" icon="hero-code-bracket-square">
          No project yet. Open a repository: it becomes a project, mirrored at /work/NAME in the VM.
        </.empty>
      </div>

      <.project
        :for={project <- @projects}
        project={project}
        mirror={@mirror[project.name]}
        handoffs={Enum.filter(@handoffs, &(&1.project == project.name))}
        worktrees={@worktrees[project.name]}
        settings={@settings && @settings.name == project.name && @settings}
        vm={@vm}
        now={@now}
      />
    </div>
    """
  end

  attr :project, :map, required: true
  attr :mirror, :any, required: true
  attr :handoffs, :list, required: true
  attr :worktrees, :any, required: true
  attr :settings, :any, required: true
  attr :vm, :any, required: true
  attr :now, DateTime, required: true

  defp project(assigns) do
    ~H"""
    <section
      id={"project-#{@project.name}"}
      class="overflow-hidden rounded-xl border border-line bg-panel"
    >
      <header class="flex flex-wrap items-start gap-3 px-4 py-3">
        <span class="mt-0.5 flex size-8 shrink-0 items-center justify-center rounded-lg bg-accent-soft/50 text-accent">
          <.icon name="hero-code-bracket-square" class="size-4" />
        </span>
        <div class="min-w-0 flex-1">
          <p class="text-[14px] font-semibold text-ink">{@project.name}</p>
          <p class="truncate font-mono text-[11px] text-faint" title={@project.path}>
            {@project.path}
          </p>
        </div>
        <div class="flex items-center gap-1.5">
          <.button
            id={"project-zed-#{@project.name}"}
            variant="primary"
            class="whitespace-nowrap"
            phx-click="open_project"
            phx-value-name={@project.name}
            disabled={@vm.status != :running}
          >
            <.icon name="hero-code-bracket-square-micro" class="size-3.5" /> Open in Zed
          </.button>
          <.button
            id={"project-settings-#{@project.name}"}
            variant="ghost"
            phx-click="toggle_project_settings"
            phx-value-name={@project.name}
            title="Settings"
          >
            <.icon name="hero-cog-6-tooth-micro" class="size-3.5" />
          </.button>
          <.button
            id={"project-remove-#{@project.name}"}
            variant="ghost"
            phx-click="remove_project"
            phx-value-name={@project.name}
            data-confirm={"Stop #{@project.name} being a project? Its mirror and worktrees stay in the VM; MDT stops keeping the mirror current."}
            title="Remove the project"
          >
            <.icon name="hero-x-mark-micro" class="size-3.5" />
          </.button>
        </div>
      </header>

      <div class="grid gap-3 border-t border-line-soft px-4 py-3 text-[12px] sm:grid-cols-2">
        <div id={"project-mirror-#{@project.name}"}>
          <p class="mb-1 text-[10px] font-semibold uppercase tracking-wide text-faint">Mirror</p>
          <.mirror_line project={@project} mirror={@mirror} vm={@vm} now={@now} />
        </div>
        <div>
          <p class="mb-1 text-[10px] font-semibold uppercase tracking-wide text-faint">
            Target branches
          </p>
          <div id={"project-targets-#{@project.name}"} class="flex flex-wrap items-center gap-1.5">
            <span
              :for={branch <- @project.targets}
              class={[
                "rounded px-1.5 py-0.5 font-mono text-[11px]",
                if(branch == @project.default_target,
                  do: "bg-accent-soft/60 text-accent-strong",
                  else: "bg-deep text-muted"
                )
              ]}
              title={if branch == @project.default_target, do: "The default"}
            >
              {branch}
            </span>
            <span class="text-[11px] text-faint">
              · accepted as {if @project.accept == :commits, do: "commits", else: "changes"}
            </span>
          </div>
        </div>
      </div>

      <.settings_form :if={@settings} project={@project} settings={@settings} />

      <div class="border-t border-line-soft">
        <p class="px-4 pt-3 text-[10px] font-semibold uppercase tracking-wide text-faint">
          Agent worktrees
        </p>
        <%= cond do %>
          <% @vm.status != :running -> %>
            <p class="px-4 pt-1 pb-3 text-[12px] text-faint">Shown while the VM runs.</p>
          <% @worktrees in [nil, []] -> %>
            <p
              id={"project-worktrees-#{@project.name}"}
              class="px-4 pt-1 pb-3 text-[12px] text-faint"
            >
              None yet. An agent makes one with mdt worktree new TASK; each thread works in its own.
            </p>
          <% true -> %>
            <ul
              id={"project-worktrees-#{@project.name}"}
              class="mt-1 divide-y divide-line-soft"
            >
              <li
                :for={wt <- @worktrees}
                class="flex items-center gap-3 px-4 py-2"
              >
                <.icon name="hero-folder-micro" class="size-4 shrink-0 text-faint" />
                <div class="min-w-0 flex-1">
                  <p class="truncate font-mono text-[12px] text-ink" title={wt.path}>
                    {Path.basename(wt.path)}
                  </p>
                  <p class="truncate text-[11px] text-faint">
                    {wt.branch || "no branch"}
                    <%= case handoff_of(@handoffs, wt.path) do %>
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
                  phx-value-name={@project.name}
                  phx-value-folder={wt.path}
                  title={Zed.command(wt.path)}
                >
                  <.icon name="hero-arrow-top-right-on-square-micro" class="size-3.5" /> Zed
                </.button>
              </li>
            </ul>
        <% end %>
      </div>
    </section>
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
        <p class="flex items-start gap-1.5 text-bad">
          <.icon name="hero-exclamation-triangle-micro" class="mt-0.5 size-3.5 shrink-0" />
          {@mirror.error}
        </p>
      <% @vm.status != :running -> %>
        <p class="text-faint">The VM is stopped: it is brought up to date when it runs.</p>
      <% @mirror -> %>
        <p class="flex items-center gap-1.5 text-muted">
          <span class="size-1.5 rounded-full bg-ok"></span>
          <span class="font-mono text-ink">/work/{@project.name}</span>
          on {@mirror.default} at
          <span class="font-mono">{String.slice(@mirror.tips[@mirror.default] || "", 0, 7)}</span>
          · {ago(@mirror.at, @now)}
        </p>
        <p :if={@mirror.rescued} class="mt-1 text-[11px] text-warn-strong">
          Edits found in the mirror were kept as {@mirror.rescued}.
        </p>
      <% true -> %>
        <p class="text-faint">Being made…</p>
    <% end %>
    """
  end

  attr :project, :map, required: true
  attr :settings, :map, required: true

  defp settings_form(assigns) do
    ~H"""
    <.form
      for={@settings.form}
      id={"project-settings-form-#{@project.name}"}
      phx-submit="save_project"
      class="space-y-3 border-t border-line-soft bg-deep/30 px-4 py-3"
    >
      <input type="hidden" name="name" value={@project.name} />
      <div>
        <p class="mb-1.5 text-[11px] font-medium text-ink">Target branches</p>
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

  # The open handoff of a worktree, or its latest.
  defp handoff_of(handoffs, path) do
    handoffs
    |> Enum.filter(&(&1.source.top == path))
    |> Enum.sort_by(&{&1.status in [:open, :sent_back], &1.id}, :desc)
    |> List.first()
  end

  defp handoff_label(handoff) do
    conflicts? = (handoff.stats[:conflicts] || 0) > 0 and handoff.status in [:open, :sent_back]

    "handoff ##{handoff.id}, #{status_word(handoff.status)}" <>
      if(conflicts?, do: ", conflicts", else: "")
  end

  defp status_word(:open), do: "open"
  defp status_word(:sent_back), do: "sent back"
  defp status_word(:accepted), do: "accepted"
  defp status_word(:closed), do: "closed"
end
