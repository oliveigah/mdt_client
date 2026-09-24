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

  require Logger

  alias MDTClient.Git.CommandResult
  alias MDTClient.Git.Core
  alias MDTClient.Git.Error
  alias MDTClient.Git.FileChange
  alias MDTClient.Git.Files
  alias MDTClient.Preferences
  alias MDTClient.Tools
  alias MDTClientWeb.GitLive.Session
  alias MDTClientWeb.GitLive.Components
  alias MDTClientWeb.GitLive.Graph.Layout

  @limits [500, 1_000, 2_500, 5_000]
  @default_limit 500
  @refresh_interval :timer.seconds(60)

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
     |> assign_graph(nil)
     |> assign(:opening, nil)
     |> assign(:open_error, nil)
     |> assign(:open_dialog, nil)
     |> assign(:refresh_checks, %{})
     |> assign(:restore_order, [])
     |> assign(:restore_active, nil)
     |> restore_session()}
  end

  # The folders that were open last time come back, in the order they were in.
  # A folder that has since moved or stopped being a worktree is dropped without
  # complaint: it is not something the reader asked for right now.
  defp restore_session(socket) do
    if connected?(socket) do
      paths = Session.repositories()
      schedule_refresh()

      socket
      |> assign(:restore_order, paths)
      |> assign(:restore_active, Session.active_repository())
      |> then(fn socket -> Enum.reduce(paths, socket, &start_open(&2, &1, :restore)) end)
    else
      socket
    end
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

        <%= if @active_id do %>
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

            <Components.graph_panel
              snapshot={@graph_snapshot}
              graph={@graph_layout}
              changes={@graph_changes}
              pending={@graph_pending}
              pending_label={@graph_pending_label}
              limit={@graph_limit}
              panel={@graph_panel}
              selected_commit={@graph_selected_commit}
              selected_commits={@graph_selected_commits}
              selected_branch={@graph_selected_branch}
              menu={@graph_menu}
              diff={@graph_diff}
              limits={@limits}
            />

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

      <Components.open_dialog :if={@open_dialog} dialog={@open_dialog} />

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
         |> assign(:open_error, nil)
         |> assign(:open_dialog, nil)
         |> start_open(path, :manual)}
    end
  end

  @impl true
  def handle_event("clone_repository", params, socket) do
    url = String.trim(params["url"] || "")
    parent = String.trim(params["parent"] || "")
    name = String.trim(params["name"] || "")
    name = if name == "", do: Core.clone_name(url), else: name

    cond do
      url == "" ->
        {:noreply, clone_failed(socket, "Enter the address of the repository to clone")}

      parent == "" ->
        {:noreply, clone_failed(socket, "Choose the folder the clone should go into")}

      name == "" ->
        {:noreply, clone_failed(socket, "Give the new folder a name")}

      true ->
        destination = Path.join(Path.expand(parent), name)
        keys = saved_ssh_keys()

        {:noreply,
         socket
         |> put_dialog(url: url, parent: parent, name: name, error: nil, cloning: destination)
         |> start_async({:open, System.unique_integer([:positive])}, fn ->
           {:manual, destination,
            with {:ok, repository} <- Core.clone(url, destination, keys) do
              {:ok, repository, load(repository, @default_limit)}
            end}
         end)}
    end
  end

  @impl true
  def handle_event("clone_parent_selected", %{"path" => path}, socket) do
    {:noreply, put_dialog(socket, parent: path)}
  end

  @impl true
  def handle_event("set_open_mode", %{"mode" => mode}, socket) when mode in ~w(open clone) do
    {:noreply, put_dialog(socket, mode: mode, error: nil)}
  end

  @impl true
  def handle_event("open_repository_dialog", _params, socket) do
    {:noreply, put_dialog(socket, [])}
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
    socket = socket |> assign(:active_id, id) |> sync_tab() |> remember_session()

    {:noreply, auto_refresh(socket)}
  end

  @impl true
  def handle_event("reorder_tabs", %{"order" => order}, socket) when is_list(order) do
    tabs = MDTClientWeb.Tabs.reorder(socket.assigns.tabs, order)

    {:noreply,
     socket
     |> assign(:tabs, tabs)
     |> assign(:restore_order, Enum.map(tabs, & &1.path))
     |> remember_session()}
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

    {:noreply,
     socket
     |> assign(tabs: tabs, active_id: active_id)
     |> sync_tab()
     |> remember_session()}
  end

  ## Selection

  # Commits are picked like files: a click takes one, Ctrl or Cmd adds or drops
  # one, and Shift takes the run from the commit clicked last. The inspector
  # follows the commit clicked.
  @impl true
  def handle_event("select_commit", %{"id" => id} = params, socket) do
    range? = params["shiftKey"] == true
    toggle? = params["ctrlKey"] == true or params["metaKey"] == true

    socket =
      update_tab(socket, fn tab ->
        %{
          pick_commit(tab, id, range?, toggle?)
          | panel: "commit",
            commit_changes: nil,
            menu: nil,
            diff: nil
        }
      end)

    {:noreply, refresh_reads(socket)}
  end

  @impl true
  def handle_event("clear_commits", _params, socket) do
    {:noreply,
     update_tab(socket, fn tab ->
       %{tab | selected_commits: MapSet.new(List.wrap(tab.selected_commit))}
     end)}
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
    {:noreply, refresh_reads(update_tab(socket, &%{&1 | panel: panel, action: nil}))}
  end

  @impl true
  def handle_event("show_working_tree", _params, socket) do
    {:noreply, update_tab(socket, &%{&1 | panel: "changes", diff: nil, menu: nil})}
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

      :file ->
        side = file_side(params["side"])
        menu = %{kind: :file, id: id, side: side, at: point(params), anchor: params["anchor"]}
        {:noreply, update_tab(socket, &(&1 |> select_for_menu({side, id}) |> toggle_menu(menu)))}

      :commit ->
        menu = %{kind: :commit, id: id, at: point(params), anchor: params["anchor"]}
        {:noreply, update_tab(socket, &(&1 |> commit_for_menu(id) |> toggle_menu(menu)))}

      kind ->
        menu = %{kind: kind, id: id, at: point(params), anchor: params["anchor"]}
        {:noreply, update_tab(socket, &toggle_menu(&1, menu))}
    end
  end

  # Reading starts a command, and a command closes menus, so a commit picked by
  # a right click has its files read once its menu is out of the way.
  @impl true
  def handle_event("close_menu", _params, socket) do
    {:noreply, refresh_reads(update_tab(socket, &%{&1 | menu: nil}))}
  end

  @impl true
  def handle_event("close_overlays", _params, socket) do
    socket = update_tab(socket, &%{&1 | menu: nil, confirm: nil, ssh_open?: false})
    {:noreply, refresh_reads(socket)}
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
  def handle_event("dismiss_notice", %{"id" => id}, socket) do
    {:noreply,
     update_tab(
       socket,
       &%{&1 | notices: Enum.reject(&1.notices, fn notice -> notice.id == id end)}
     )}
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
  def handle_event("toggle_stashes", _params, socket) do
    {:noreply, update_tab(socket, &%{&1 | stashes_open?: not &1.stashes_open?})}
  end

  @impl true
  def handle_event("view_diff", %{"path" => path, "side" => side} = params, socket) do
    case {socket.assigns.tab, diff_side(side)} do
      {%{} = tab, side} when not is_nil(side) ->
        open = %{
          path: path,
          side: side,
          commit: params["commit"],
          diff: nil,
          error: nil,
          pinned?: true
        }

        socket = put_tab(socket, tab.id, &%{&1 | diff: open, menu: nil})

        {:noreply, refresh_reads(socket)}

      _unknown ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("close_diff", _params, socket) do
    {:noreply, update_tab(socket, &%{&1 | diff: nil})}
  end

  # A plain click picks one file, Ctrl or Cmd adds or drops one, and Shift takes
  # every row from the file picked last to this one, in the order they are
  # shown, the unstaged list first.
  @impl true
  def handle_event("select_path", %{"path" => path} = params, socket) do
    row = {file_side(params["side"]), path}
    range? = params["shiftKey"] == true
    toggle? = params["ctrlKey"] == true or params["metaKey"] == true

    {:noreply, update_tab(socket, &select_path(&1, row, range?, toggle?))}
  end

  @impl true
  def handle_event("select_all_paths", _params, socket) do
    {:noreply,
     update_tab(socket, &%{&1 | selected_paths: MapSet.new(&1.changes, fn file -> file.path end)})}
  end

  @impl true
  def handle_event("clear_paths", _params, socket) do
    {:noreply, update_tab(socket, &%{&1 | selected_paths: MapSet.new(), selection_anchor: nil})}
  end

  @impl true
  def handle_event("prepare_stash", _params, socket) do
    {:noreply, update_tab(socket, &%{&1 | stashing?: true, menu: nil})}
  end

  @impl true
  def handle_event("cancel_stash", _params, socket) do
    {:noreply, update_tab(socket, &%{&1 | stashing?: false, stash_message: ""})}
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

  ## Background refresh

  @impl true
  def handle_info(:auto_refresh, socket) do
    schedule_refresh()
    {:noreply, auto_refresh(socket)}
  end

  # Work done outside MDT should show up without being asked for, but not while
  # the reader is in the middle of something the refresh would disturb.
  defp auto_refresh(socket) do
    case socket.assigns.tab do
      %{pending: nil, menu: nil, confirm: nil, action: nil} = tab ->
        if socket.assigns.open_dialog, do: socket, else: start_refresh_check(socket, tab)

      _busy ->
        socket
    end
  end

  defp schedule_refresh, do: Process.send_after(self(), :auto_refresh, @refresh_interval)

  defp start_refresh_check(socket, tab) do
    if Map.has_key?(socket.assigns.refresh_checks, tab.id) do
      socket
    else
      task = {:git_check, tab.id, System.unique_integer([:positive])}
      repository = tab.repository
      fingerprint = tab.fingerprint
      limit = tab.limit
      reads = requested_reads(tab)

      socket
      |> assign(:refresh_checks, Map.put(socket.assigns.refresh_checks, tab.id, task))
      |> start_async(task, fn ->
        case Core.fingerprint(repository) do
          {:ok, ^fingerprint} -> {:unchanged, fingerprint}
          {:ok, _changed} -> {:changed, load(repository, limit, reads)}
          {:error, error} -> {:error, error}
        end
      end)
    end
  end

  ## Async results

  @impl true
  def handle_async(
        {:git_check, tab_id, _ref} = task,
        {:ok, {:changed, state}},
        socket
      ) do
    case Map.fetch(socket.assigns.refresh_checks, tab_id) do
      {:ok, ^task} ->
        socket = clear_refresh_check(socket, tab_id)

        case find_tab(socket, tab_id) do
          %{pending: nil} = tab when tab_id == socket.assigns.active_id ->
            tab = apply_state(tab, state)

            {:noreply,
             socket
             |> put_tab(tab.id, fn _current -> tab end)
             |> refresh_reads(state)}

          _unchanged_or_busy ->
            {:noreply, socket}
        end

      _stale ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_async({:git_check, tab_id, _ref} = task, _outcome, socket) do
    case Map.fetch(socket.assigns.refresh_checks, tab_id) do
      {:ok, ^task} -> {:noreply, clear_refresh_check(socket, tab_id)}
      _stale -> {:noreply, socket}
    end
  end

  @impl true
  def handle_async({:open, _ref}, {:ok, {kind, path, result}}, socket) do
    socket = finished_opening(socket, path)
    log_open_result(socket.assigns.current_scope.user.username, kind, path, result)

    case {result, kind} do
      {{:ok, repository, {:ok, state}}, _kind} ->
        {:noreply, open_tab(socket, repository, state, kind)}

      {_failure, :restore} ->
        {:noreply, forget_repository(socket, path)}

      {{:ok, _repository, {:error, error}}, :manual} ->
        {:noreply, open_failed(socket, error)}

      {{:error, error}, :manual} ->
        {:noreply, open_failed(socket, error)}
    end
  end

  @impl true
  def handle_async({:open, _ref}, {:exit, reason}, socket) do
    Logger.warning("git repository open task exited kind=#{exit_kind(reason)}",
      user: socket.assigns.current_scope.user.username,
      system: :git_gui
    )

    {:noreply,
     socket
     |> assign(:opening, nil)
     |> put_dialog(cloning: nil)
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
         put_tab(socket, tab.id, fn current ->
           current
           |> Map.merge(%{pending: nil, pending_label: nil})
           |> add_notice(:error, error)
         end)}

      _stale ->
        {:noreply, socket}
    end
  end

  ## Opening

  defp start_open(socket, path, kind) do
    socket
    |> assign(:opening, if(kind == :manual, do: path, else: socket.assigns.opening))
    |> start_async({:open, System.unique_integer([:positive])}, fn ->
      {kind, path,
       with {:ok, repository} <- Core.open(path) do
         {:ok, repository, load(repository, @default_limit)}
       end}
    end)
  end

  defp finished_opening(socket, path) do
    socket = put_dialog_if_open(socket, cloning: nil)

    if socket.assigns.opening == path, do: assign(socket, :opening, nil), else: socket
  end

  defp open_tab(socket, repository, state, kind) do
    socket =
      case Enum.find(socket.assigns.tabs, &(&1.path == repository.path)) do
        nil ->
          tab = new_tab(repository, state)

          socket
          |> assign(:tabs, order_tabs(socket, socket.assigns.tabs ++ [tab]))
          |> activate(tab, kind)

        existing ->
          activate(socket, existing, kind)
      end

    socket =
      socket
      |> assign(:open_error, nil)
      |> assign(:open_dialog, nil)
      |> sync_tab()

    # Restoring changes nothing about which folders are remembered, and writing
    # a half restored list would lose the rest if the app stopped right now.
    if kind == :manual, do: remember_session(socket), else: socket
  end

  # A restored folder only takes focus if it was the active one last time, so
  # tabs coming back in parallel cannot fight over the selection.
  defp activate(socket, tab, :manual), do: assign(socket, :active_id, tab.id)

  defp activate(socket, tab, :restore) do
    if is_nil(socket.assigns.active_id) or tab.path == socket.assigns.restore_active do
      assign(socket, :active_id, tab.id)
    else
      socket
    end
  end

  # Restored folders land in whatever order Git answers, so the saved order is
  # reapplied; anything opened since keeps its place at the end.
  defp order_tabs(socket, tabs) do
    order = socket.assigns.restore_order

    Enum.sort_by(tabs, fn tab ->
      case Enum.find_index(order, &(&1 == tab.path)) do
        nil -> length(order)
        index -> index
      end
    end)
  end

  defp remember_session(socket) do
    Session.remember(Enum.map(socket.assigns.tabs, & &1.path), active_path(socket))
    socket
  end

  defp forget_repository(socket, path) do
    Session.forget(path)
    socket
  end

  defp active_path(socket) do
    case socket.assigns.tab ||
           Enum.find(socket.assigns.tabs, &(&1.id == socket.assigns.active_id)) do
      nil -> nil
      tab -> tab.path
    end
  end

  defp saved_ssh_keys do
    [
      private_key: Preferences.get("git_ssh_private_key") || nil,
      public_key: Preferences.get("git_ssh_public_key") || nil
    ]
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
  end

  defp clone_failed(socket, message) do
    put_dialog(socket, error: Error.new(:invalid_argument, message), cloning: nil)
  end

  defp put_dialog_if_open(socket, attrs) do
    if socket.assigns.open_dialog, do: put_dialog(socket, attrs), else: socket
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
    dialog =
      socket.assigns.open_dialog ||
        %{
          reason: nil,
          error: nil,
          path: "",
          mode: "open",
          url: "",
          parent: "",
          name: "",
          cloning: nil
        }

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
      graph: state.graph,
      commits_by_id: state.commits_by_id,
      fingerprint: state.fingerprint,
      changes: state.changes,
      stashes: state.stashes,
      remotes: state.remotes,
      limit: @default_limit,
      filter: "",
      panel: "commit",
      selected_commit: state.snapshot.head,
      selected_commits: MapSet.new(List.wrap(state.snapshot.head)),
      commit_anchor: state.snapshot.head,
      selected_branch: current_branch_name(state.snapshot),
      selected_paths: MapSet.new(),
      selection_anchor: nil,
      menu: nil,
      action: nil,
      confirm: nil,
      notices: [],
      pending: nil,
      pending_label: nil,
      stash_message: "",
      stashing?: false,
      commit_message: "",
      stashes_open?: true,
      diff: nil,
      commit_changes: nil,
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
  defp run(socket, tab, action, opts \\ [])

  defp run(socket, %{pending: pending} = tab, _action, _opts) when not is_nil(pending) do
    put_tab(socket, tab.id, &%{&1 | menu: nil, confirm: nil})
  end

  defp run(socket, tab, action, opts) do
    task = {:git, tab.id, System.unique_integer([:positive])}
    repository = tab.repository
    limit = tab.limit
    username = socket.assigns.current_scope.user.username

    reads = requested_reads(tab)

    # A refresh on a timer should not flash a spinner over the toolbar.
    label = if Keyword.get(opts, :quiet, false), do: nil, else: label(action)

    if action != :refresh do
      Logger.info(
        "git action started action=#{label(action)} repository=#{inspect(repository.path)}",
        user: username,
        system: :git_gui
      )
    end

    socket
    |> put_tab(
      tab.id,
      &%{&1 | pending: task, pending_label: label, menu: nil, confirm: nil}
    )
    |> start_async(task, fn ->
      result = perform(repository, action)
      state = load(repository, limit, reads)
      log_action_result(username, repository.path, action, result, state)
      {result, state}
    end)
  end

  defp log_action_result(username, path, action, result, state) do
    metadata = [user: username, system: :git_gui]
    context = "action=#{label(action)} repository=#{inspect(path)}"

    case {result, state} do
      {{:error, %Error{} = error}, _state} ->
        Logger.warning("git action failed #{context} kind=#{error.kind}", metadata)

      {_result, {:error, %Error{} = error}} ->
        Logger.warning("git refresh failed #{context} kind=#{error.kind}", metadata)

      _success when action != :refresh ->
        Logger.info("git action completed #{context}", metadata)

      _refresh ->
        :ok
    end
  end

  defp log_open_result(username, kind, path, result) do
    metadata = [user: username, system: :git_gui]

    case result do
      {:ok, _repository, {:ok, _state}} ->
        Logger.info("git repository opened path=#{inspect(path)} source=#{kind}", metadata)

      {:ok, _repository, {:error, %Error{} = error}} ->
        Logger.warning(
          "git repository load failed path=#{inspect(path)} kind=#{error.kind}",
          metadata
        )

      {:error, %Error{} = error} ->
        Logger.warning(
          "git repository open failed path=#{inspect(path)} kind=#{error.kind}",
          metadata
        )
    end
  end

  defp exit_kind({%{__struct__: module}, _stack}), do: inspect(module)
  defp exit_kind(%{__struct__: module}), do: inspect(module)
  defp exit_kind(reason) when is_atom(reason), do: to_string(reason)
  defp exit_kind(_reason), do: "other"

  defp requested_reads(tab) do
    %{
      diff: tab.diff && Map.take(tab.diff, [:path, :side, :commit, :pinned?]),
      commit: commit_changes_wanted(tab)
    }
  end

  # Every command reloads the state it may have changed, so the UI never shows a
  # result without the snapshot that produced it.
  # The file list of a commit is only fetched while it is on screen; the graph
  # does not need it, and it is one more Git process per refresh.
  # The inspector shows a commit's files as soon as one is picked, so they are
  # fetched with the rest of its metadata rather than on a second click.
  defp commit_changes_wanted(%{panel: "commit"} = tab), do: tab.selected_commit
  defp commit_changes_wanted(_tab), do: nil

  defp load(repository, limit, reads \\ %{diff: nil, commit: nil}) do
    [snapshot, changes, stashes, remotes, fingerprint_sources] =
      [
        fn -> Core.snapshot(repository, limit: limit) end,
        fn -> Files.status(repository) end,
        fn -> Core.list_stashes(repository) end,
        fn -> Core.list_remotes(repository) end,
        fn -> Core.fingerprint_sources(repository) end
      ]
      |> Enum.map(&Task.async/1)
      |> Task.await_many(:infinity)

    with {:ok, snapshot} <- snapshot,
         {:ok, changes} <- changes,
         {:ok, stashes} <- stashes,
         {:ok, remotes} <- remotes,
         {:ok, fingerprint_sources} <- fingerprint_sources do
      {:ok,
       %{
         snapshot: snapshot,
         graph: Layout.layout(snapshot.commits),
         commits_by_id: Map.new(snapshot.commits, &{&1.id, &1}),
         commit_ids: MapSet.new(snapshot.commits, & &1.id),
         branch_names: MapSet.new(snapshot.branches, & &1.full_name),
         paths: MapSet.new(changes, & &1.path),
         fingerprint: Core.fingerprint(repository, changes, fingerprint_sources),
         changes: changes,
         stashes: stashes,
         remotes: remotes,
         diff: load_diff(repository, changes, reads.diff),
         commit_changes: load_commit_changes(repository, reads.commit)
       }}
    end
  end

  defp load_commit_changes(_repository, nil), do: nil

  defp load_commit_changes(repository, commit),
    do: {commit, Files.commit_status(repository, commit)}

  # A diff of a commit is history, so the working tree has no say in it.
  defp load_diff(repository, _changes, %{commit: commit} = request) when is_binary(commit) do
    {request, Files.diff(repository, request.path, side: :commit, commit: commit)}
  end

  # The open diff travels with the rest of the state, so staging a file updates
  # the view instead of leaving yesterday's lines on screen.
  defp load_diff(_repository, _changes, nil), do: nil

  defp load_diff(repository, changes, %{path: path} = request) do
    case Enum.find(changes, &(&1.path == path)) do
      nil ->
        {request, :gone}

      change ->
        side = if request.pinned?, do: request.side, else: readable_side(change, request.side)
        {request, Files.diff(repository, path, side: side, untracked: change.untracked?)}
    end
  end

  # Staging a file empties its unstaged side; following it across keeps the view
  # on the change the reader was looking at.
  defp readable_side(change, :unstaged) do
    if is_nil(change.unstaged) and not is_nil(change.staged), do: :staged, else: :unstaged
  end

  defp readable_side(change, :staged) do
    if is_nil(change.staged) and not is_nil(change.unstaged), do: :unstaged, else: :staged
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

  defp perform(repository, {:squash, revisions, message}),
    do: Core.squash(repository, revisions, message)

  defp perform(repository, {:commit, message}), do: Core.commit(repository, message)
  defp perform(repository, {:stage, paths}), do: Core.stage(repository, paths)
  defp perform(repository, {:unstage, paths}), do: Core.unstage(repository, paths)
  defp perform(repository, {:discard, paths}), do: Core.discard(repository, paths)

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

    socket
    |> put_tab(tab.id, fn _current -> tab end)
    |> refresh_reads(state)
  end

  # A diff or a commit file list asked for while a command was running is left
  # waiting for an answer, so it is fetched as soon as the tab is free again.
  defp refresh_reads(socket) do
    case socket.assigns.tab do
      %{pending: nil} = tab ->
        if waiting_on_read?(tab), do: run(socket, tab, :refresh, quiet: true), else: socket

      _busy ->
        socket
    end
  end

  # After a load that failed there is nothing to chase: the repository itself is
  # unreadable, and asking again would only spin.
  defp refresh_reads(socket, {:ok, _state}), do: refresh_reads(socket)
  defp refresh_reads(socket, _failed), do: socket

  defp waiting_on_read?(tab) do
    match?(%{diff: nil, error: nil}, tab.diff) or
      (not is_nil(commit_changes_wanted(tab)) and is_nil(tab.commit_changes))
  end

  defp apply_state(tab, {:ok, state}) do
    snapshot = state.snapshot

    %{
      tab
      | snapshot: snapshot,
        graph: if(snapshot.commits == tab.snapshot.commits, do: tab.graph, else: state.graph),
        commits_by_id: state.commits_by_id,
        fingerprint: state.fingerprint,
        changes: state.changes,
        stashes: state.stashes,
        remotes: state.remotes,
        selected_commit: keep_commit(tab, snapshot, state.commit_ids),
        selected_commits: keep_commits(tab, snapshot, state.commit_ids),
        selected_branch: keep_branch(tab, snapshot, state.branch_names),
        selected_paths: MapSet.intersection(tab.selected_paths, state.paths),
        diff: keep_diff(tab, state.diff),
        commit_changes: keep_commit_changes(tab, state.commit_changes)
    }
  end

  defp apply_state(tab, {:error, %Error{} = error}), do: add_notice(tab, :error, error)

  defp clear_refresh_check(socket, tab_id) do
    assign(socket, :refresh_checks, Map.delete(socket.assigns.refresh_checks, tab_id))
  end

  # A result that answers a different request than the one on screen is stale:
  # the reader opened another file while this load was in flight.
  defp keep_diff(%{diff: %{path: path} = open} = _tab, {%{path: path}, outcome}) do
    case outcome do
      :gone -> nil
      {:ok, diff} -> %{open | diff: diff, side: diff.side, error: nil, pinned?: false}
      {:error, error} -> %{open | diff: nil, error: error, pinned?: false}
    end
  end

  defp keep_diff(tab, _stale), do: tab.diff

  # An answer about a commit that is no longer selected is of no use.
  defp keep_commit_changes(%{selected_commit: commit} = _tab, {commit, {:ok, files}}),
    do: %{commit: commit, files: files, error: nil}

  defp keep_commit_changes(%{selected_commit: commit} = _tab, {commit, {:error, error}}),
    do: %{commit: commit, files: [], error: error}

  defp keep_commit_changes(tab, _stale), do: tab.commit_changes

  defp keep_commit(tab, snapshot, commits) do
    cond do
      tab.selected_commit && MapSet.member?(commits, tab.selected_commit) -> tab.selected_commit
      snapshot.head && MapSet.member?(commits, snapshot.head) -> snapshot.head
      true -> nil
    end
  end

  defp keep_commits(tab, snapshot, commits) do
    kept = MapSet.intersection(tab.selected_commits, commits)
    focus = keep_commit(tab, snapshot, commits)

    cond do
      is_nil(focus) -> MapSet.new()
      MapSet.member?(kept, focus) -> kept
      true -> MapSet.new([focus])
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
    tab = add_notice(tab, :success, result)

    # The draft that produced the commit or stash is spent once Git accepted it.
    case result.action do
      :commit -> %{tab | commit_message: ""}
      :stash -> %{tab | stash_message: "", stashing?: false}
      _other -> tab
    end
  end

  defp apply_result(tab, {:error, %Error{} = error}) do
    tab =
      tab
      |> add_notice(:error, error)
      |> Map.put(:ssh_open?, tab.ssh_open? or https_authentication_error?(error))

    cond do
      error.kind == :conflict -> %{tab | panel: "changes"}
      unmerged_branch?(error) -> %{tab | confirm: force_delete_confirmation(error)}
      true -> tab
    end
  end

  defp add_notice(tab, kind, content) do
    notice = %{
      id: Integer.to_string(System.unique_integer([:positive])),
      kind: kind,
      content: content
    }

    %{tab | notices: tab.notices ++ [notice]}
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
  defp requested("stage", _params, tab), do: on_selection(:stage, tab, &FileChange.unstaged?/1)
  defp requested("unstage", _params, tab), do: on_selection(:unstage, tab, &FileChange.staged?/1)
  defp requested("discard", _params, tab), do: on_selection(:discard, tab, fn _change -> true end)

  defp requested("stage_path", %{"path" => path}, _tab), do: {:stage, [path]}
  defp requested("unstage_path", %{"path" => path}, _tab), do: {:unstage, [path]}
  defp requested("stage_all", _params, tab), do: {:stage, side_paths(tab, :unstaged)}
  defp requested("unstage_all", _params, tab), do: {:unstage, side_paths(tab, :staged)}

  defp requested("merge", %{"revision" => revision}, _tab), do: {:merge, revision}
  defp requested("rebase", %{"revision" => revision}, _tab), do: {:rebase, revision}
  defp requested("cherry_pick", %{"revision" => revision}, _tab), do: {:cherry_pick, revision}

  defp requested("cherry_pick_selection", _params, tab) do
    case picked_commits(tab) do
      [] -> nil
      ids -> {:cherry_pick, Enum.reverse(ids)}
    end
  end

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

  defp prepare(tab, %{"action" => "squash"}) do
    case picked_commits(tab) do
      [_, _ | _] = ids ->
        %{
          kind: :squash,
          value: ids |> Enum.reverse() |> Enum.map_join("\n\n", &full_message(tab, &1)),
          target: ids,
          start: nil,
          checkout?: false
        }

      _fewer ->
        nil
    end
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

  defp submitted(%{kind: :squash, target: ids}, params) do
    {:squash, ids, String.trim(params["value"] || "")}
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

  # The picked commits, newest first, the way the graph lists them.
  defp picked_commits(tab) do
    for commit <- tab.snapshot.commits,
        MapSet.member?(tab.selected_commits, commit.id),
        do: commit.id
  end

  defp pick_commit(tab, id, true = _range?, toggle?) do
    case commit_range(tab, tab.commit_anchor, id) do
      nil ->
        pick_commit(tab, id, false, toggle?)

      ids ->
        base = if toggle?, do: tab.selected_commits, else: MapSet.new()
        %{tab | selected_commits: MapSet.union(base, MapSet.new(ids)), selected_commit: id}
    end
  end

  defp pick_commit(tab, id, false, true = _toggle?) do
    if MapSet.member?(tab.selected_commits, id) do
      selected = MapSet.delete(tab.selected_commits, id)
      # Dropping the commit on show hands the inspector to the newest one left.
      focus =
        if tab.selected_commit == id,
          do: List.first(picked_commits(%{tab | selected_commits: selected})),
          else: tab.selected_commit

      %{tab | selected_commits: selected, selected_commit: focus, commit_anchor: id}
    else
      selected = MapSet.put(tab.selected_commits, id)
      %{tab | selected_commits: selected, selected_commit: id, commit_anchor: id}
    end
  end

  defp pick_commit(tab, id, false, false) do
    %{tab | selected_commits: MapSet.new([id]), selected_commit: id, commit_anchor: id}
  end

  # A right click on a picked commit acts on everything picked; on any other
  # commit it picks that one alone.
  defp commit_for_menu(tab, id) do
    if MapSet.member?(tab.selected_commits, id),
      do: tab,
      else: %{pick_commit(tab, id, false, false) | commit_changes: nil}
  end

  defp commit_range(_tab, nil, _id), do: nil

  defp commit_range(tab, anchor, id) do
    ids = Enum.map(tab.snapshot.commits, & &1.id)

    with from when is_integer(from) <- Enum.find_index(ids, &(&1 == anchor)),
         to when is_integer(to) <- Enum.find_index(ids, &(&1 == id)) do
      Enum.slice(ids, min(from, to)..max(from, to)//1)
    end
  end

  # An action on the selection covers the files it can change, and a selection
  # it cannot change at all asks for nothing.
  defp on_selection(action, tab, applies?) do
    selected = Enum.filter(tab.changes, &MapSet.member?(tab.selected_paths, &1.path))

    case for(change <- selected, applies?.(change), do: change.path) do
      [] -> nil
      paths -> {action, paths}
    end
  end

  defp select_path(tab, row, true = _range?, toggle?) do
    case file_range(tab, tab.selection_anchor, row) do
      nil ->
        select_path(tab, row, false, toggle?)

      paths ->
        # The anchor stays put, so the next Shift click reaches from the same row.
        base = if toggle?, do: tab.selected_paths, else: MapSet.new()
        %{tab | selected_paths: MapSet.union(base, MapSet.new(paths))}
    end
  end

  defp select_path(tab, {_side, path} = row, false, true = _toggle?) do
    selected =
      if MapSet.member?(tab.selected_paths, path),
        do: MapSet.delete(tab.selected_paths, path),
        else: MapSet.put(tab.selected_paths, path)

    %{tab | selected_paths: selected, selection_anchor: row}
  end

  defp select_path(tab, {_side, path} = row, false, false) do
    %{tab | selected_paths: MapSet.new([path]), selection_anchor: row}
  end

  # A right click on a picked file acts on everything picked; on any other file
  # it picks that file alone, the way a file manager does.
  defp select_for_menu(tab, {_side, path} = row) do
    if MapSet.member?(tab.selected_paths, path),
      do: tab,
      else: select_path(tab, row, false, false)
  end

  defp file_range(_tab, nil, _row), do: nil

  defp file_range(tab, anchor, row) do
    rows = file_rows(tab)

    with from when is_integer(from) <- row_index(rows, anchor),
         to when is_integer(to) <- row_index(rows, row) do
      rows |> Enum.slice(min(from, to)..max(from, to)//1) |> Enum.map(&elem(&1, 1))
    end
  end

  # Staging or unstaging the anchor moves it to the other list, where the same
  # path is the next best place to start from.
  defp row_index(rows, {_side, path} = row) do
    Enum.find_index(rows, &(&1 == row)) || Enum.find_index(rows, &(elem(&1, 1) == path))
  end

  defp file_rows(tab) do
    for(change <- tab.changes, FileChange.unstaged?(change), do: {:unstaged, change.path}) ++
      for change <- tab.changes, FileChange.staged?(change), do: {:staged, change.path}
  end

  defp file_side("staged"), do: :staged
  defp file_side(_side), do: :unstaged

  defp side_paths(tab, :staged),
    do: tab.changes |> Enum.filter(&FileChange.staged?/1) |> Enum.map(& &1.path)

  defp side_paths(tab, :unstaged),
    do: tab.changes |> Enum.filter(&FileChange.unstaged?/1) |> Enum.map(& &1.path)

  defp diff_side("staged"), do: :staged
  defp diff_side("unstaged"), do: :unstaged
  defp diff_side("commit"), do: :commit
  defp diff_side(_side), do: nil

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

  defp confirmation({:discard, paths}) do
    subject =
      case paths do
        [path] -> path
        paths -> "#{length(paths)} files"
      end

    %{
      title: "Discard changes to #{subject}?",
      message:
        "Staged and unstaged edits are thrown away and the files return to their last " <>
          "committed state; new files are deleted. This cannot be undone.",
      label: "Discard"
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
  defp label({:squash, _revisions, _message}), do: "Squashing"
  defp label({:commit, _message}), do: "Committing"
  defp label({:stage, _paths}), do: "Staging"
  defp label({:unstage, _paths}), do: "Unstaging"
  defp label({:discard, _paths}), do: "Discarding"
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
  defp menu_kind("file"), do: :file
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
    tab = Enum.find(socket.assigns.tabs, &(&1.id == socket.assigns.active_id))

    socket
    |> assign(:tab, tab)
    |> assign_graph(tab)
  end

  # The commit graph is the largest tree in this LiveView. Keeping its inputs as
  # independent assigns lets LiveView skip it when an unrelated tab field, such
  # as an inspector draft or SSH form value, changes.
  defp assign_graph(socket, nil) do
    assign(socket,
      graph_snapshot: nil,
      graph_layout: nil,
      graph_changes: [],
      graph_pending: nil,
      graph_pending_label: nil,
      graph_limit: @default_limit,
      graph_panel: "commit",
      graph_selected_commit: nil,
      graph_selected_commits: MapSet.new(),
      graph_selected_branch: nil,
      graph_menu: nil,
      graph_diff: nil
    )
  end

  defp assign_graph(socket, tab) do
    assign(socket,
      graph_snapshot: tab.snapshot,
      graph_layout: tab.graph,
      graph_changes: tab.changes,
      graph_pending: tab.pending,
      graph_pending_label: tab.pending_label,
      graph_limit: tab.limit,
      graph_panel: tab.panel,
      graph_selected_commit: tab.selected_commit,
      graph_selected_commits: tab.selected_commits,
      graph_selected_branch: tab.selected_branch,
      graph_menu: tab.menu,
      graph_diff: tab.diff
    )
  end
end
