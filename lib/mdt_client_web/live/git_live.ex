defmodule MDTClientWeb.GitLive do
  @moduledoc """
  The Git tool: repository tabs over a branch list, a commit graph and an
  inspector.

  Every tab owns one `MDTClient.Git.Repository` handle and the state that
  belongs to it: snapshot, selection, SSH credentials and the operation it is running.
  Git work never happens inside a callback; commands run through `start_async/3`
  and always refresh the snapshot in the same task, so a successful mutation and
  the state it produced arrive together.

  Graph geometry lives in `MDTClientWeb.GitLive.Graph.Layout` and the markup in
  `MDTClientWeb.GitLive.Components`; this module only coordinates.
  """
  use MDTClientWeb, :live_view

  alias MDTClient.Git.CommandResult
  alias MDTClient.Git.Core
  alias MDTClient.Git.Error
  alias MDTClient.Git.Files
  alias MDTClient.Preferences
  alias MDTClient.Tools
  alias MDTClientWeb.GitLive.Components
  alias MDTClientWeb.GitLive.Graph.Layout

  @limits [500, 1_000, 2_500, 5_000]
  @default_limit 500

  @impl true
  def mount(_params, _session, socket) do
    tool = Tools.fetch!(:git)

    {:ok,
     socket
     |> assign(:page_title, tool.name)
     |> assign(:tool, tool)
     |> assign(:limits, @limits)
     |> assign(:tabs, [])
     |> assign(:active_id, nil)
     |> assign(:tab, nil)
     |> assign(:opening, nil)
     |> assign(:open_error, nil)
     |> assign(:open_dialog, nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} tool={@tool}>
      <div
        class="flex min-h-0 flex-1 flex-col overflow-hidden"
        phx-window-keydown="close_overlays"
        phx-key="Escape"
      >
        <Components.tab_bar tabs={@tabs} active_id={@active_id} tab={@tab} opening={@opening} />

        <%= if @tab do %>
          <div class="flex min-h-0 flex-1 overflow-hidden">
            <Components.branch_panel tab={@tab} />

            <.resizer
              id="git-branches-resizer"
              panel="git-branches"
              variable="--git-branches-width"
              storage_key="mdt:git-branches-width"
              axis="x"
              min="180"
              max="460"
              label="Resize the branch panel"
            />

            <Components.graph_panel tab={@tab} limits={@limits} />

            <.resizer
              id="git-inspector-resizer"
              panel="git-inspector"
              variable="--git-inspector-width"
              storage_key="mdt:git-inspector-width"
              axis="x"
              edge="end"
              min="260"
              max="680"
              label="Resize the inspector"
            />

            <Components.inspector_panel tab={@tab} />
          </div>
        <% else %>
          <Components.empty_state error={@open_error} />
        <% end %>
      </div>

      <Components.menu_overlay :if={@tab && @tab.menu} tab={@tab} />

      <Components.open_dialog
        :if={@open_dialog}
        reason={@open_dialog.reason}
        error={@open_dialog.error}
        path={@open_dialog.path}
      />

      <Components.confirm_dialog :if={@tab && @tab.confirm} confirm={@tab.confirm} />
    </Layouts.app>
    """
  end

  ## Opening repositories

  @impl true
  def handle_event("open_repository", %{"path" => path}, socket) do
    case String.trim(path) do
      "" ->
        {:noreply, open_failed(socket, Error.new(:invalid_argument, "Choose a folder to open"))}

      path ->
        {:noreply,
         socket
         |> assign(:opening, path)
         |> assign(:open_error, nil)
         |> assign(:open_dialog, nil)
         |> start_async({:open, System.unique_integer([:positive])}, fn ->
           with {:ok, repository} <- Core.open(path) do
             {:ok, repository, load(repository, @default_limit)}
           end
         end)}
    end
  end

  @impl true
  def handle_event("folder_dialog_unavailable", params, socket) do
    {:noreply, open_dialog(socket, params["reason"])}
  end

  @impl true
  def handle_event("close_open_dialog", _params, socket) do
    {:noreply, assign(socket, :open_dialog, nil)}
  end

  ## Tabs

  @impl true
  def handle_event("select_tab", %{"id" => id}, socket) do
    {:noreply, socket |> assign(:active_id, id) |> sync_tab()}
  end

  @impl true
  def handle_event("close_tab", %{"id" => id}, socket) do
    socket =
      case find_tab(socket, id) do
        %{pending: task} when not is_nil(task) -> cancel_async(socket, task)
        _tab -> socket
      end

    tabs = Enum.reject(socket.assigns.tabs, &(&1.id == id))

    active_id =
      cond do
        socket.assigns.active_id != id -> socket.assigns.active_id
        tabs == [] -> nil
        true -> hd(tabs).id
      end

    {:noreply, socket |> assign(tabs: tabs, active_id: active_id) |> sync_tab()}
  end

  ## Selection

  @impl true
  def handle_event("select_commit", %{"id" => id}, socket) do
    {:noreply, update_tab(socket, &%{&1 | selected_commit: id, panel: "commit", menu: nil})}
  end

  @impl true
  def handle_event("select_branch", %{"name" => name}, socket) do
    {:noreply, update_tab(socket, &%{&1 | selected_branch: name})}
  end

  @impl true
  def handle_event("filter_branches", %{"filter" => filter}, socket) do
    {:noreply, update_tab(socket, &%{&1 | filter: filter})}
  end

  @impl true
  def handle_event("set_panel", %{"panel" => panel}, socket) when panel in ~w(commit changes) do
    {:noreply, update_tab(socket, &%{&1 | panel: panel, action: nil})}
  end

  @impl true
  def handle_event("set_limit", %{"limit" => limit}, socket) do
    with %{pending: nil} = tab <- socket.assigns.tab,
         {value, ""} when value != tab.limit <- Integer.parse(limit),
         true <- value in @limits do
      socket = update_tab(socket, &%{&1 | limit: value})
      {:noreply, run(socket, %{tab | limit: value}, :refresh)}
    else
      _unchanged -> {:noreply, socket}
    end
  end

  ## Menus, dialogs and overlays

  @impl true
  def handle_event("open_menu", %{"kind" => kind, "id" => id} = params, socket) do
    case menu_kind(kind) do
      nil ->
        {:noreply, socket}

      kind ->
        menu = %{kind: kind, id: id, at: point(params), anchor: params["anchor"]}
        {:noreply, update_tab(socket, &toggle_menu(&1, menu))}
    end
  end

  @impl true
  def handle_event("close_menu", _params, socket) do
    {:noreply, update_tab(socket, &%{&1 | menu: nil})}
  end

  @impl true
  def handle_event("close_overlays", _params, socket) do
    {:noreply, update_tab(socket, &%{&1 | menu: nil, confirm: nil, ssh_open?: false})}
  end

  @impl true
  def handle_event("cancel_confirm", _params, socket) do
    {:noreply, update_tab(socket, &%{&1 | confirm: nil})}
  end

  @impl true
  def handle_event("confirm_action", _params, socket) do
    case socket.assigns.tab do
      %{confirm: %{action: action}} = tab -> {:noreply, run(socket, tab, action)}
      _tab -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("dismiss_result", _params, socket) do
    {:noreply, update_tab(socket, &%{&1 | result: nil})}
  end

  ## SSH credentials

  @impl true
  def handle_event("toggle_ssh", _params, socket) do
    {:noreply, update_tab(socket, &%{&1 | ssh_open?: not &1.ssh_open?, ssh_error: nil})}
  end

  @impl true
  def handle_event("save_ssh", params, socket) do
    tab = socket.assigns.tab
    private_key = String.trim(params["private_key"] || "")
    public_key = String.trim(params["public_key"] || "")

    case Core.with_ssh_keys(tab.repository, private_key, public_key) do
      {:ok, repository} ->
        :ok = Preferences.put("git_ssh_private_key", repository.ssh_key.private_key)
        :ok = Preferences.put("git_ssh_public_key", repository.ssh_key.public_key)

        {:noreply,
         update_all_tabs(socket, fn current ->
           %{
             current
             | repository: %{current.repository | ssh_key: repository.ssh_key},
               ssh_private_key: repository.ssh_key.private_key,
               ssh_public_key: repository.ssh_key.public_key,
               ssh_open?: false,
               ssh_error: nil
           }
         end)}

      {:error, error} ->
        {:noreply, update_tab(socket, &%{&1 | ssh_error: error.message})}
    end
  end

  @impl true
  def handle_event("clear_ssh", _params, socket) do
    :ok = Preferences.put("git_ssh_private_key", nil)
    :ok = Preferences.put("git_ssh_public_key", nil)

    {:noreply,
     update_all_tabs(socket, fn tab ->
       %{
         tab
         | repository: %{tab.repository | ssh_key: nil},
           ssh_private_key: "",
           ssh_public_key: "",
           ssh_open?: false,
           ssh_error: nil
       }
     end)}
  end

  @impl true
  def handle_event("select_ssh_key", %{"kind" => kind, "path" => path}, socket)
      when kind in ["private", "public"] and is_binary(path) do
    {:noreply,
     update_tab(socket, fn tab ->
       case kind do
         "private" ->
           public_key =
             if File.regular?(path <> ".pub"), do: path <> ".pub", else: tab.ssh_public_key

           %{tab | ssh_private_key: path, ssh_public_key: public_key, ssh_error: nil}

         "public" ->
           %{tab | ssh_public_key: path, ssh_error: nil}
       end
     end)}
  end

  @impl true
  def handle_event("ssh_picker_unavailable", %{"reason" => reason}, socket) do
    {:noreply, update_tab(socket, &%{&1 | ssh_error: reason})}
  end

  @impl true
  def handle_event("copy_public_key", _params, socket) do
    case File.read(socket.assigns.tab.ssh_public_key) do
      {:ok, contents} ->
        {:noreply, push_event(socket, "git_copy_public_key", %{contents: String.trim(contents)})}

      {:error, reason} ->
        message = "Could not read the public key: #{:file.format_error(reason)}"
        {:noreply, update_tab(socket, &%{&1 | ssh_error: message})}
    end
  end

  @impl true
  def handle_event("use_ssh_remote", %{"remote" => remote}, socket) do
    {:noreply, dispatch(socket, {:use_ssh_remote, remote})}
  end

  ## Working tree selection

  @impl true
  def handle_event("toggle_path", %{"path" => path}, socket) do
    {:noreply,
     update_tab(socket, fn tab ->
       selected =
         if MapSet.member?(tab.selected_paths, path) do
           MapSet.delete(tab.selected_paths, path)
         else
           MapSet.put(tab.selected_paths, path)
         end

       %{tab | selected_paths: selected}
     end)}
  end

  @impl true
  def handle_event("select_all_paths", _params, socket) do
    {:noreply,
     update_tab(socket, &%{&1 | selected_paths: MapSet.new(&1.changes, fn file -> file.path end)})}
  end

  @impl true
  def handle_event("clear_paths", _params, socket) do
    {:noreply, update_tab(socket, &%{&1 | selected_paths: MapSet.new()})}
  end

  @impl true
  def handle_event("stash_selected", params, socket) do
    tab = socket.assigns.tab
    message = String.trim(params["message"] || "")
    untracked? = params["include_untracked"] == "true"

    socket = update_tab(socket, &%{&1 | stash_message: message, include_untracked?: untracked?})

    {:noreply, run(socket, tab, {:stash, selected_paths(tab), nil_if_empty(message), untracked?})}
  end

  @impl true
  def handle_event("commit_staged", params, socket) do
    tab = socket.assigns.tab
    message = String.trim(params["message"] || "")

    socket = update_tab(socket, &%{&1 | commit_message: message})
    {:noreply, run(socket, tab, {:commit, message})}
  end

  ## Prepared actions

  @impl true
  def handle_event("prepare", params, socket) do
    case socket.assigns.tab do
      nil -> {:noreply, socket}
      tab -> {:noreply, update_tab(socket, &%{&1 | action: prepare(tab, params), menu: nil})}
    end
  end

  @impl true
  def handle_event("cancel_action", _params, socket) do
    {:noreply, update_tab(socket, &%{&1 | action: nil})}
  end

  @impl true
  def handle_event("submit_action", params, socket) do
    case socket.assigns.tab do
      %{action: %{} = action} = tab ->
        socket = update_tab(socket, &%{&1 | action: nil})
        {:noreply, run(socket, tab, submitted(action, params))}

      _tab ->
        {:noreply, socket}
    end
  end

  ## Commands

  @impl true
  def handle_event("checkout_branch", %{"name" => name}, socket) do
    {:noreply, dispatch(socket, {:checkout_branch, name})}
  end

  @impl true
  def handle_event("request", params, socket) do
    case requested(params, socket.assigns.tab) do
      nil -> {:noreply, socket}
      action -> {:noreply, dispatch(socket, action)}
    end
  end

  ## Async results

  @impl true
  def handle_async({:open, _ref}, {:ok, result}, socket) do
    socket = assign(socket, :opening, nil)

    case result do
      {:ok, repository, {:ok, state}} ->
        {:noreply, open_tab(socket, repository, state)}

      {:ok, _repository, {:error, error}} ->
        {:noreply, open_failed(socket, error)}

      {:error, error} ->
        {:noreply, open_failed(socket, error)}
    end
  end

  @impl true
  def handle_async({:open, _ref}, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:opening, nil)
     |> open_failed(Error.new(:command_failed, "Opening the folder failed: #{inspect(reason)}"))}
  end

  @impl true
  def handle_async({:git, tab_id, _ref} = task, {:ok, {result, state}}, socket) do
    case find_tab(socket, tab_id) do
      %{pending: ^task} = tab -> {:noreply, settle(socket, tab, result, state)}
      _stale -> {:noreply, socket}
    end
  end

  @impl true
  def handle_async({:git, tab_id, _ref} = task, {:exit, reason}, socket) do
    case find_tab(socket, tab_id) do
      %{pending: ^task} = tab ->
        error = Error.new(:command_failed, "The Git command stopped: #{inspect(reason)}")

        {:noreply,
         put_tab(socket, tab.id, &%{&1 | pending: nil, pending_label: nil, error: error})}

      _stale ->
        {:noreply, socket}
    end
  end

  ## Opening

  defp open_tab(socket, repository, state) do
    case Enum.find(socket.assigns.tabs, &(&1.path == repository.path)) do
      nil ->
        tab = new_tab(repository, state)

        socket
        |> assign(:tabs, socket.assigns.tabs ++ [tab])
        |> assign(:active_id, tab.id)
        |> assign(:open_error, nil)
        |> sync_tab()

      existing ->
        socket
        |> assign(:active_id, existing.id)
        |> assign(:open_error, nil)
        |> sync_tab()
    end
  end

  # With no tab open the empty state carries the message; otherwise it has
  # nowhere to appear, so the open dialog comes back holding it.
  defp open_failed(socket, %Error{} = error) do
    socket = assign(socket, :open_error, error)

    if socket.assigns.tabs != [] or socket.assigns.open_dialog do
      put_dialog(socket, error: error, path: socket.assigns.opening || "")
    else
      socket
    end
  end

  defp open_dialog(socket, reason), do: put_dialog(socket, reason: reason)

  defp put_dialog(socket, attrs) do
    dialog = socket.assigns.open_dialog || %{reason: nil, error: nil, path: ""}

    assign(socket, :open_dialog, Enum.into(attrs, dialog))
  end

  defp new_tab(repository, state) do
    {repository, private_key, public_key, ssh_error} = apply_saved_ssh_keys(repository)

    %{
      id: "tab-#{System.unique_integer([:positive])}",
      path: repository.path,
      name: Path.basename(repository.path),
      repository: repository,
      snapshot: state.snapshot,
      graph: Layout.layout(state.snapshot.commits),
      changes: state.changes,
      stashes: state.stashes,
      remotes: state.remotes,
      limit: @default_limit,
      filter: "",
      panel: "commit",
      selected_commit: state.snapshot.head,
      selected_branch: current_branch_name(state.snapshot),
      selected_paths: MapSet.new(),
      menu: nil,
      action: nil,
      confirm: nil,
      error: nil,
      result: nil,
      pending: nil,
      pending_label: nil,
      stash_message: "",
      commit_message: "",
      include_untracked?: true,
      ssh_private_key: private_key,
      ssh_public_key: public_key,
      ssh_open?: false,
      ssh_error: ssh_error
    }
  end

  defp apply_saved_ssh_keys(repository) do
    private_key = Preferences.get("git_ssh_private_key") || ""
    public_key = Preferences.get("git_ssh_public_key") || ""

    if private_key == "" and public_key == "" do
      {repository, private_key, public_key, nil}
    else
      case Core.with_ssh_keys(repository, private_key, public_key) do
        {:ok, repository} -> {repository, private_key, public_key, nil}
        {:error, error} -> {repository, private_key, public_key, error.message}
      end
    end
  end

  defp current_branch_name(snapshot) do
    Enum.find_value(snapshot.branches, fn branch -> branch.current? && branch.full_name end)
  end

  ## Running commands

  defp dispatch(socket, action) do
    case socket.assigns.tab do
      nil -> socket
      tab -> dispatch(socket, tab, action)
    end
  end

  defp dispatch(socket, tab, action) do
    case confirmation(action) do
      nil ->
        run(socket, tab, action)

      confirm ->
        put_tab(socket, tab.id, &%{&1 | confirm: Map.put(confirm, :action, action), menu: nil})
    end
  end

  # One command at a time per tab: two Git processes in the same worktree race
  # for the index lock, and the second failure would be the one shown.
  defp run(socket, %{pending: pending} = tab, _action) when not is_nil(pending) do
    put_tab(socket, tab.id, &%{&1 | menu: nil, confirm: nil})
  end

  defp run(socket, tab, action) do
    task = {:git, tab.id, System.unique_integer([:positive])}
    repository = tab.repository
    limit = tab.limit

    socket
    |> put_tab(
      tab.id,
      &%{&1 | pending: task, pending_label: label(action), menu: nil, confirm: nil, error: nil}
    )
    |> start_async(task, fn -> {perform(repository, action), load(repository, limit)} end)
  end

  # Every command reloads the state it may have changed, so the UI never shows a
  # result without the snapshot that produced it.
  defp load(repository, limit) do
    with {:ok, snapshot} <- Core.snapshot(repository, limit: limit),
         {:ok, changes} <- Files.status(repository),
         {:ok, stashes} <- Core.list_stashes(repository),
         {:ok, remotes} <- Core.list_remotes(repository) do
      {:ok, %{snapshot: snapshot, changes: changes, stashes: stashes, remotes: remotes}}
    end
  end

  defp perform(_repository, :refresh), do: :ok
  defp perform(repository, :fetch), do: Core.fetch(repository)
  defp perform(repository, {:pull, strategy}), do: Core.pull(repository, strategy)
  defp perform(repository, {:push, opts}), do: Core.push(repository, opts)
  defp perform(repository, {:use_ssh_remote, remote}), do: Core.use_ssh_remote(repository, remote)
  defp perform(repository, {:checkout_branch, name}), do: Core.checkout_branch(repository, name)
  defp perform(repository, {:checkout_commit, id}), do: Core.checkout_commit(repository, id)

  defp perform(repository, {:checkout_remote, remote, name}),
    do: Core.checkout_remote_branch(repository, remote, as: name)

  defp perform(repository, {:create_branch, name, start, false}),
    do: Core.create_branch(repository, name, start)

  defp perform(repository, {:create_branch, name, start, true}) do
    with {:ok, _created} <- Core.create_branch(repository, name, start) do
      Core.checkout_branch(repository, name)
    end
  end

  defp perform(repository, {:rename_branch, old, new}),
    do: Core.rename_branch(repository, old, new)

  defp perform(repository, {:delete_branch, name, force?}),
    do: Core.delete_branch(repository, name, force: force?)

  defp perform(repository, {:delete_remote_branch, remote, branch}),
    do: Core.delete_remote_branch(repository, remote, branch)

  defp perform(repository, {:merge, revision}), do: Core.merge(repository, revision)
  defp perform(repository, {:rebase, revision}), do: Core.rebase(repository, revision)
  defp perform(repository, {:cherry_pick, revision}), do: Core.cherry_pick(repository, revision)
  defp perform(repository, {:revert, revision}), do: Core.revert(repository, revision)
  defp perform(repository, {:reset, revision, mode}), do: Core.reset(repository, revision, mode)

  defp perform(repository, {:edit_message, revision, message}),
    do: Core.edit_commit_message(repository, revision, message)

  defp perform(repository, {:commit, message}), do: Core.commit(repository, message)
  defp perform(repository, {:stage, paths}), do: Core.stage(repository, paths)
  defp perform(repository, {:unstage, paths}), do: Core.unstage(repository, paths)

  defp perform(repository, {:stash, paths, message, untracked?}),
    do: Core.stash(repository, paths, message: message, include_untracked: untracked?)

  defp perform(repository, {:apply_stash, reference}), do: Core.apply_stash(repository, reference)
  defp perform(repository, {:pop_stash, reference}), do: Core.pop_stash(repository, reference)
  defp perform(repository, {:drop_stash, reference}), do: Core.drop_stash(repository, reference)
  defp perform(repository, :continue), do: Core.continue_operation(repository)
  defp perform(repository, :skip), do: Core.skip_operation(repository)
  defp perform(repository, :abort), do: Core.abort_operation(repository)

  ## Settling results

  defp settle(socket, tab, result, state) do
    tab =
      tab
      |> apply_state(state)
      |> Map.merge(%{pending: nil, pending_label: nil})
      |> apply_result(result)

    put_tab(socket, tab.id, fn _current -> tab end)
  end

  defp apply_state(tab, {:ok, state}) do
    snapshot = state.snapshot
    commits = MapSet.new(snapshot.commits, & &1.id)
    branches = MapSet.new(snapshot.branches, & &1.full_name)
    paths = MapSet.new(state.changes, & &1.path)

    %{
      tab
      | snapshot: snapshot,
        graph: Layout.layout(snapshot.commits),
        changes: state.changes,
        stashes: state.stashes,
        remotes: state.remotes,
        selected_commit: keep_commit(tab, snapshot, commits),
        selected_branch: keep_branch(tab, snapshot, branches),
        selected_paths: MapSet.intersection(tab.selected_paths, paths)
    }
  end

  defp apply_state(tab, {:error, %Error{} = error}), do: %{tab | error: error}

  defp keep_commit(tab, snapshot, commits) do
    cond do
      tab.selected_commit && MapSet.member?(commits, tab.selected_commit) -> tab.selected_commit
      snapshot.head && MapSet.member?(commits, snapshot.head) -> snapshot.head
      true -> nil
    end
  end

  defp keep_branch(tab, snapshot, branches) do
    if tab.selected_branch && MapSet.member?(branches, tab.selected_branch) do
      tab.selected_branch
    else
      current_branch_name(snapshot)
    end
  end

  defp apply_result(tab, :ok), do: tab

  defp apply_result(tab, {:ok, %CommandResult{} = result}) do
    tab = %{tab | result: result, error: nil}

    # The draft that produced the commit or stash is spent once Git accepted it.
    case result.action do
      :commit -> %{tab | commit_message: ""}
      :stash -> %{tab | stash_message: ""}
      _other -> tab
    end
  end

  defp apply_result(tab, {:error, %Error{} = error}) do
    tab = %{
      tab
      | error: error,
        result: nil,
        ssh_open?: tab.ssh_open? or https_authentication_error?(error)
    }

    cond do
      error.kind == :conflict -> %{tab | panel: "changes"}
      unmerged_branch?(error) -> %{tab | confirm: force_delete_confirmation(error)}
      true -> tab
    end
  end

  defp https_authentication_error?(%Error{message: message}) do
    message =~ "could not read Username for 'https://" or
      message =~ "Authentication failed for 'https://"
  end

  # Git refuses to delete a branch that is not fully merged; rather than hiding
  # the safe attempt, the refusal becomes an explicit second question.
  defp unmerged_branch?(%Error{message: message, args: args}),
    do: args != [] and message =~ "not fully merged"

  defp force_delete_confirmation(%Error{args: args}) do
    name = List.last(args)

    %{
      action: {:delete_branch, name, true},
      title: "Delete an unmerged branch?",
      message:
        "#{name} has commits that are on no other branch. Deleting it now loses them " <>
          "unless you know where they are.",
      label: "Force delete"
    }
  end

  ## Action plumbing

  defp requested(%{"action" => action} = params, tab), do: requested(action, params, tab)
  defp requested(_params, _tab), do: nil

  defp requested(_action, _params, nil), do: nil
  defp requested("refresh", _params, _tab), do: :refresh
  defp requested("fetch", _params, _tab), do: :fetch
  defp requested("pull", _params, _tab), do: {:pull, :ff_only}
  defp requested("push", _params, tab), do: {:push, push_options(tab)}
  defp requested("continue", _params, _tab), do: :continue
  defp requested("skip", _params, _tab), do: :skip
  defp requested("abort", _params, _tab), do: :abort
  defp requested("stage", _params, tab), do: {:stage, selected_paths(tab)}
  defp requested("unstage", _params, tab), do: {:unstage, selected_paths(tab)}

  defp requested("merge", %{"revision" => revision}, _tab), do: {:merge, revision}
  defp requested("rebase", %{"revision" => revision}, _tab), do: {:rebase, revision}
  defp requested("cherry_pick", %{"revision" => revision}, _tab), do: {:cherry_pick, revision}
  defp requested("revert", %{"revision" => revision}, _tab), do: {:revert, revision}

  defp requested("checkout_commit", %{"revision" => revision}, _tab),
    do: {:checkout_commit, revision}

  defp requested("soft_reset", %{"revision" => revision}, _tab), do: {:reset, revision, :soft}
  defp requested("hard_reset", %{"revision" => revision}, _tab), do: {:reset, revision, :hard}

  defp requested("delete_branch", %{"name" => name}, _tab), do: {:delete_branch, name, false}

  defp requested("delete_remote_branch", %{"remote" => remote, "name" => name}, _tab),
    do: {:delete_remote_branch, remote, name}

  defp requested("apply_stash", %{"reference" => reference}, _tab), do: {:apply_stash, reference}
  defp requested("pop_stash", %{"reference" => reference}, _tab), do: {:pop_stash, reference}
  defp requested("drop_stash", %{"reference" => reference}, _tab), do: {:drop_stash, reference}
  defp requested(_action, _params, _tab), do: nil

  # Pushing a branch that has never been pushed needs an explicit destination,
  # so the first push sets the upstream instead of failing.
  defp push_options(%{snapshot: snapshot}) do
    current = Enum.find(snapshot.branches, & &1.current?)

    cond do
      is_nil(current) ->
        []

      current.upstream ->
        []

      remote = default_remote(snapshot) ->
        [remote: remote, branch: current.name, set_upstream: true]

      true ->
        []
    end
  end

  defp default_remote(snapshot) do
    remotes =
      snapshot.branches
      |> Enum.filter(&(&1.kind == :remote))
      |> Enum.map(& &1.remote)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    cond do
      "origin" in remotes -> "origin"
      remotes != [] -> hd(remotes)
      true -> nil
    end
  end

  defp prepare(tab, %{"action" => "create_branch"} = params) do
    %{
      kind: :create_branch,
      value: "",
      start: params["start"] || tab.selected_commit || "HEAD",
      checkout?: true
    }
  end

  defp prepare(_tab, %{"action" => "rename_branch", "name" => name}) do
    %{kind: :rename_branch, value: name, target: name, start: nil, checkout?: false}
  end

  defp prepare(_tab, %{"action" => "checkout_remote", "name" => name}) do
    %{
      kind: :checkout_remote,
      value: local_name(name),
      target: name,
      start: name,
      checkout?: false
    }
  end

  defp prepare(tab, %{"action" => "edit_message", "revision" => revision}) do
    %{
      kind: :edit_message,
      value: full_message(tab, revision),
      target: revision,
      start: Components.short_id(revision),
      checkout?: false
    }
  end

  defp prepare(_tab, _params), do: nil

  defp submitted(%{kind: :create_branch, start: start}, params) do
    {:create_branch, String.trim(params["value"] || ""), start, params["checkout"] == "true"}
  end

  defp submitted(%{kind: :rename_branch, target: target}, params) do
    {:rename_branch, target, String.trim(params["value"] || "")}
  end

  defp submitted(%{kind: :checkout_remote, target: target}, params) do
    {:checkout_remote, target, String.trim(params["value"] || "")}
  end

  defp submitted(%{kind: :edit_message, target: target}, params) do
    {:edit_message, target, String.trim(params["value"] || "")}
  end

  # A remote branch named "origin/feature" becomes the local "feature".
  defp local_name(remote_branch) do
    case String.split(remote_branch, "/", parts: 2) do
      [_remote, name] -> name
      [name] -> name
    end
  end

  defp full_message(tab, revision) do
    case Enum.find(tab.snapshot.commits, &(&1.id == revision)) do
      nil -> ""
      commit -> String.trim_trailing(commit.summary <> "\n\n" <> commit.body)
    end
  end

  defp selected_paths(tab), do: tab.selected_paths |> MapSet.to_list() |> Enum.sort()

  defp nil_if_empty(""), do: nil
  defp nil_if_empty(value), do: value

  ## Confirmations

  defp confirmation({:reset, revision, :hard}) do
    %{
      title: "Hard reset to #{Components.short_id(revision)}?",
      message:
        "The current branch moves to this commit and every uncommitted change in the " <>
          "working tree and index is discarded. This cannot be undone from here.",
      label: "Hard reset"
    }
  end

  defp confirmation({:delete_branch, name, _force?}) do
    %{
      title: "Delete #{name}?",
      message: "The local branch is removed. Commits only reachable from it become unreferenced.",
      label: "Delete branch"
    }
  end

  defp confirmation({:delete_remote_branch, remote, name}) do
    %{
      title: "Delete #{name} on #{remote}?",
      message: "The branch is removed from the remote for everyone who uses it.",
      label: "Delete on remote"
    }
  end

  defp confirmation({:drop_stash, reference}) do
    %{
      title: "Drop #{reference}?",
      message: "The stashed changes are deleted without being applied.",
      label: "Drop stash"
    }
  end

  defp confirmation(:abort) do
    %{
      title: "Abort the operation in progress?",
      message:
        "Git returns the worktree to the state it had before the operation started, " <>
          "discarding the conflict resolution done so far.",
      label: "Abort"
    }
  end

  defp confirmation(_action), do: nil

  ## Labels

  defp label(:refresh), do: "Refreshing"
  defp label(:fetch), do: "Fetching"
  defp label({:pull, _strategy}), do: "Pulling"
  defp label({:push, _opts}), do: "Pushing"
  defp label({:use_ssh_remote, _remote}), do: "Switching remote to SSH"
  defp label({:checkout_branch, _name}), do: "Checking out"
  defp label({:checkout_commit, _id}), do: "Checking out"
  defp label({:checkout_remote, _remote, _name}), do: "Checking out"
  defp label({:create_branch, _name, _start, _checkout?}), do: "Creating branch"
  defp label({:rename_branch, _old, _new}), do: "Renaming branch"
  defp label({:delete_branch, _name, _force?}), do: "Deleting branch"
  defp label({:delete_remote_branch, _remote, _name}), do: "Deleting remote branch"
  defp label({:merge, _revision}), do: "Merging"
  defp label({:rebase, _revision}), do: "Rebasing"
  defp label({:cherry_pick, _revision}), do: "Cherry-picking"
  defp label({:revert, _revision}), do: "Reverting"
  defp label({:reset, _revision, mode}), do: "#{String.capitalize(to_string(mode))} resetting"
  defp label({:edit_message, _revision, _message}), do: "Rewriting message"
  defp label({:commit, _message}), do: "Committing"
  defp label({:stage, _paths}), do: "Staging"
  defp label({:unstage, _paths}), do: "Unstaging"
  defp label({:stash, _paths, _message, _untracked?}), do: "Stashing"
  defp label({:apply_stash, _reference}), do: "Applying stash"
  defp label({:pop_stash, _reference}), do: "Popping stash"
  defp label({:drop_stash, _reference}), do: "Dropping stash"
  defp label(:continue), do: "Continuing"
  defp label(:skip), do: "Skipping"
  defp label(:abort), do: "Aborting"

  ## Tab state

  defp menu_kind("branch"), do: :branch
  defp menu_kind("commit"), do: :commit
  defp menu_kind(_kind), do: nil

  # Clicking the same trigger twice closes the menu; a right click always opens
  # it at the new position.
  defp toggle_menu(%{menu: %{kind: kind, id: id}} = tab, %{kind: kind, id: id, at: nil}),
    do: %{tab | menu: nil}

  defp toggle_menu(tab, menu), do: %{tab | menu: menu}

  # A right click anchors the menu to the pointer; the row button anchors to itself.
  defp point(%{"x" => x, "y" => y}) when is_number(x) and is_number(y), do: %{x: x, y: y}
  defp point(_params), do: nil

  defp find_tab(socket, id), do: Enum.find(socket.assigns.tabs, &(&1.id == id))

  defp update_tab(socket, fun), do: put_tab(socket, socket.assigns.active_id, fun)

  defp update_all_tabs(socket, fun) do
    socket
    |> assign(:tabs, Enum.map(socket.assigns.tabs, fun))
    |> sync_tab()
  end

  defp put_tab(socket, nil, _fun), do: socket

  defp put_tab(socket, id, fun) do
    tabs = Enum.map(socket.assigns.tabs, fn tab -> if tab.id == id, do: fun.(tab), else: tab end)

    socket |> assign(:tabs, tabs) |> sync_tab()
  end

  defp sync_tab(socket) do
    assign(socket, :tab, Enum.find(socket.assigns.tabs, &(&1.id == socket.assigns.active_id)))
  end
end
