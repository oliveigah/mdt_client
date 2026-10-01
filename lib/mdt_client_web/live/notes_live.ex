defmodule MDTClientWeb.NotesLive do
  @moduledoc """
  The notes tool: every note kept, and searchable, on the left, the open ones
  ahead of those done, and the note open on the right, its Markdown beside
  the page it renders to.

  A note never saved is a draft: it has an identifier, but no place in the
  library until it is given a title or something is written in it.

  Notes are written from outside this page too, so it follows
  `MDTClient.Notes.Library.subscribe/1` and redraws what others change.
  """
  use MDTClientWeb, :live_view

  alias MDTClient.Notes.Library
  alias MDTClient.Notes.Markdown
  alias MDTClient.Notes.Note
  alias MDTClient.Tools

  @modes [
    {"write", "Write", "hero-pencil-micro"},
    {"split", "Split", "hero-view-columns-micro"},
    {"preview", "Preview", "hero-eye-micro"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    username = socket.assigns.current_scope.user.username
    if connected?(socket), do: Library.subscribe(username)

    current =
      case Library.latest(username) do
        {:ok, note} -> current(note)
        :error -> current(Note.new(), false)
      end

    {:ok,
     socket
     |> assign(:page_title, "Notes")
     |> assign(:tool, Tools.fetch!(:notes))
     |> assign(:username, username)
     |> assign(:sidebar?, true)
     |> assign(:collapsed, MapSet.new())
     |> assign(:menu, nil)
     |> assign(:term, "")
     |> assign(:mode, "split")
     |> assign_current(current)
     |> assign_list()}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    case Library.get(socket.assigns.username, id) do
      {:ok, note} -> {:noreply, assign_current(socket, current(note))}
      :error -> {:noreply, put_flash(socket, :error, "Note not found")}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      tool={@tool}
      notices={@notices}
      update={@update}
    >
      <div class="flex min-h-0 flex-1 overflow-hidden">
        <.note_list
          :if={@sidebar?}
          groups={@groups}
          term={@term}
          count={@count}
          collapsed={@collapsed}
          current_id={@current.id}
        />

        <.resizer
          :if={@sidebar?}
          id="note-list-resizer"
          panel="note-list-panel"
          variable="--note-list-width"
          storage_key="mdt:note-list-width"
          axis="x"
          min="200"
          max="560"
        />

        <.workspace current={@current} html={@html} mode={@mode} sidebar?={@sidebar?} />
      </div>

      <.note_menu :if={@menu} menu={@menu} />
    </Layouts.app>
    """
  end

  ## Note list

  attr :groups, :list, required: true
  attr :term, :string, required: true
  attr :count, :integer, required: true
  attr :collapsed, :any, required: true, doc: "MapSet of collapsed group keys"
  attr :current_id, :string, required: true

  defp note_list(assigns) do
    ~H"""
    <aside
      id="note-list-panel"
      class="flex w-[var(--note-list-width,17rem)] min-w-0 shrink-0 flex-col bg-panel"
    >
      <div class="flex h-9 shrink-0 items-center gap-2 border-b border-line-soft px-2.5">
        <span class="text-[11px] font-semibold uppercase tracking-wide text-muted">Notes</span>
        <span class="rounded bg-deep px-1.5 py-0.5 font-mono text-[10px] text-faint">{@count}</span>
        <div class="flex-1"></div>
        <button
          type="button"
          id="new-note"
          phx-click="new_note"
          title="New note"
          class="flex size-6 cursor-pointer items-center justify-center rounded text-faint transition-colors hover:bg-hover hover:text-accent"
        >
          <.icon name="hero-plus" class="size-3.5" />
        </button>
        <button
          type="button"
          phx-click="toggle_sidebar"
          title="Hide notes"
          class="flex size-6 cursor-pointer items-center justify-center rounded text-faint transition-colors hover:bg-hover hover:text-ink"
        >
          <.icon name="hero-chevron-double-left" class="size-3.5" />
        </button>
      </div>

      <div class="shrink-0 border-b border-line-soft p-2">
        <form
          id="note-search"
          phx-change="search"
          phx-submit="search"
          class="relative"
          autocomplete="off"
        >
          <.icon
            name="hero-magnifying-glass"
            class="pointer-events-none absolute left-2 top-1/2 size-3.5 -translate-y-1/2 text-faint"
          />
          <input
            type="text"
            name="term"
            value={@term}
            placeholder="Search every word written"
            phx-debounce="120"
            class="w-full rounded-md border border-line bg-deep py-1.5 pl-7 pr-7 text-xs text-ink outline-none transition-colors placeholder:text-faint focus:border-accent/60 focus:ring-2 focus:ring-accent/15"
          />
          <button
            :if={@term != ""}
            type="button"
            phx-click="clear_search"
            title="Clear search"
            class="absolute right-1.5 top-1/2 flex size-5 -translate-y-1/2 cursor-pointer items-center justify-center rounded text-faint transition-colors hover:bg-hover hover:text-ink"
          >
            <.icon name="hero-x-mark" class="size-3.5" />
          </button>
        </form>
      </div>

      <%!-- A click opens a note, the circle beside it marks it done, and a
            right click offers what else can be done with it. --%>
      <div
        id="note-list"
        phx-hook="MDTClientWeb.PanelComponents.RowMenu"
        role="listbox"
        aria-label="Notes"
        class="min-h-0 flex-1 overflow-y-auto px-1.5 py-2"
      >
        <p :if={@groups == []} class="px-2 py-6 text-center text-xs text-faint">
          <%= if @term == "" do %>
            Nothing here yet — write something down.
          <% else %>
            No note mentions “{@term}”.
          <% end %>
        </p>

        <div :for={{label, key, entries} <- @groups} id={"note-group-#{key}"} class="mb-1">
          <button
            type="button"
            id={"note-group-toggle-#{key}"}
            phx-click="toggle_group"
            phx-value-group={key}
            aria-expanded={to_string(!MapSet.member?(@collapsed, key))}
            class="flex w-full cursor-pointer items-center gap-1 rounded px-1.5 py-1 text-[10px] font-semibold uppercase tracking-wider text-faint transition-colors hover:bg-hover hover:text-muted"
          >
            <.icon
              name="hero-chevron-right"
              class={["size-3 transition-transform", !MapSet.member?(@collapsed, key) && "rotate-90"]}
            />
            <span class="min-w-0 flex-1 truncate text-left">{label}</span>
            <span class="font-mono normal-case">{length(entries)}</span>
          </button>

          <div :if={!MapSet.member?(@collapsed, key)} role="group" aria-label={label}>
            <.note_entry :for={entry <- entries} entry={entry} active={entry.id == @current_id} />
          </div>
        </div>
      </div>
    </aside>
    """
  end

  attr :entry, :map, required: true
  attr :active, :boolean, required: true

  defp note_entry(assigns) do
    ~H"""
    <div
      id={"note-row-#{@entry.id}"}
      data-menu-kind="note"
      data-menu-id={@entry.id}
      class={[
        "group relative flex select-none items-start gap-1.5 rounded-md pl-1.5 pr-2 transition-colors",
        if(@active,
          do: "bg-active shadow-[inset_2px_0_0_0_var(--color-accent)]",
          else: "hover:bg-hover"
        )
      ]}
    >
      <.done_toggle
        id={"note-done-#{@entry.id}"}
        note_id={@entry.id}
        done={@entry.done_at != nil}
        class="mt-[7px] size-3.5"
      />

      <button
        type="button"
        id={"note-#{@entry.id}"}
        phx-click="open_note"
        phx-value-id={@entry.id}
        role="option"
        aria-selected={to_string(@active)}
        class="flex min-w-0 flex-1 cursor-pointer flex-col gap-0.5 py-1.5 text-left focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-accent"
      >
        <span class="flex w-full items-center gap-2">
          <span class={[
            "min-w-0 flex-1 truncate text-xs transition-colors",
            if(@entry.done_at,
              do: "text-muted line-through decoration-faint",
              else: "text-ink"
            )
          ]}>
            {@entry.title}
          </span>
          <span class="shrink-0 font-mono text-[10px] text-faint">{@entry.when}</span>
        </span>
        <%= cond do %>
          <% @entry.snippet -> %>
            <.snippet parts={@entry.snippet} />
          <% @entry.excerpt -> %>
            <span class="w-full truncate text-[11px] text-faint">{@entry.excerpt}</span>
          <% true -> %>
        <% end %>
      </button>

      <div class={[
        "absolute right-1 top-1 hidden items-center gap-0.5 rounded group-hover:flex",
        if(@active, do: "bg-active", else: "bg-hover")
      ]}>
        <button
          type="button"
          phx-click="delete_note"
          phx-value-id={@entry.id}
          data-confirm="Delete this note?"
          title="Delete this note"
          class="flex size-5 cursor-pointer items-center justify-center rounded text-faint transition-colors hover:bg-panel hover:text-bad"
        >
          <.icon name="hero-trash" class="size-3" />
        </button>
      </div>
    </div>
    """
  end

  # The words around a search match, the match itself marked.
  attr :parts, :any, required: true, doc: "`{before, match, after}`"

  defp snippet(%{parts: {before, match, rest}} = assigns) do
    assigns = assign(assigns, before: before, match: match, rest: rest)

    ~H"""
    <span class="w-full truncate text-[11px] text-muted">
      {@before}<mark class="rounded-sm bg-warn-soft px-0.5 text-warn-strong">{@match}</mark>{@rest}
    </span>
    """
  end

  # The round check that marks a note done, or open again. It asks for the
  # state it shows the opposite of, so a double click cannot undo itself.
  attr :id, :string, required: true
  attr :note_id, :string, required: true
  attr :done, :boolean, required: true
  attr :disabled, :boolean, default: false
  attr :class, :any, default: nil

  defp done_toggle(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      phx-click="set_done"
      phx-value-id={@note_id}
      phx-value-done={to_string(!@done)}
      disabled={@disabled}
      role="checkbox"
      aria-checked={to_string(@done)}
      title={if @done, do: "Done — click to reopen", else: "Mark done"}
      class={[
        "flex shrink-0 cursor-pointer items-center justify-center rounded-full border-[1.5px] transition-all duration-150 active:scale-90",
        "disabled:cursor-default disabled:opacity-40 disabled:active:scale-100",
        if(@done,
          do: "border-ok bg-ok text-panel hover:bg-ok/80",
          else:
            "border-faint/70 text-transparent hover:border-ok hover:text-ok/70 disabled:hover:border-faint/70 disabled:hover:text-transparent"
        ),
        @class
      ]}
    >
      <.icon name="hero-check-micro" class="size-[85%]" />
    </button>
    """
  end

  attr :menu, :map, required: true

  defp note_menu(assigns) do
    ~H"""
    <.context_menu
      id="note-menu"
      anchor={@menu.anchor || "note-row-#{@menu.id}"}
      at={@menu.at}
      label="Note actions"
    >
      <.menu_item
        id="note-menu-open"
        icon="hero-arrow-top-right-on-square"
        phx-click="open_note"
        phx-value-id={@menu.id}
      >
        Open note
      </.menu_item>
      <.menu_item
        id="note-menu-done"
        icon={if @menu.done?, do: "hero-arrow-uturn-left", else: "hero-check-circle"}
        phx-click="set_done"
        phx-value-id={@menu.id}
        phx-value-done={to_string(!@menu.done?)}
      >
        {if @menu.done?, do: "Reopen", else: "Mark done"}
      </.menu_item>

      <.menu_separator />

      <.menu_item
        id="note-menu-delete"
        icon="hero-trash"
        danger
        phx-click="delete_note"
        phx-value-id={@menu.id}
        data-confirm="Delete this note?"
      >
        Delete…
      </.menu_item>
    </.context_menu>
    """
  end

  ## Workspace

  attr :current, :map, required: true
  attr :html, :string, required: true
  attr :mode, :string, required: true
  attr :sidebar?, :boolean, required: true

  # Everything for one note sits in a form named after it. Switching notes
  # swaps the form whole, so the title and body inputs start fresh rather
  # than keeping what the browser had for the previous note, and anything
  # still being typed is sent with the identifier of the note it belongs to.
  defp workspace(assigns) do
    assigns =
      assign(assigns,
        default_title: Note.default_title(),
        max_body: Note.max_body(),
        modes: @modes
      )

    ~H"""
    <section class="flex min-w-0 flex-1 flex-col bg-app">
      <form
        id={"note-form-#{@current.id}"}
        phx-change="edit"
        phx-submit={JS.push("edit") |> JS.focus(to: "#note-body-#{@current.id}")}
        autocomplete="off"
        class="flex min-h-0 flex-1 flex-col"
      >
        <input type="hidden" name="note_id" value={@current.id} />

        <div class="flex h-9 shrink-0 items-stretch border-b border-line-soft bg-panel">
          <button
            :if={!@sidebar?}
            type="button"
            id="show-note-list"
            phx-click="toggle_sidebar"
            title="Show notes"
            class="flex w-9 shrink-0 cursor-pointer items-center justify-center border-r border-line-soft text-faint transition-colors hover:bg-hover hover:text-ink"
          >
            <.icon name="hero-chevron-double-right" class="size-3.5" />
          </button>

          <div class="flex min-w-0 flex-1 items-center gap-2 pl-3">
            <.done_toggle
              id="note-done"
              note_id={@current.id}
              done={@current.done_at != nil}
              disabled={!@current.saved?}
              class="size-4"
            />
            <input
              type="text"
              id={"note-title-#{@current.id}"}
              name="title"
              value={if @current.title == @default_title, do: "", else: @current.title}
              placeholder={@default_title}
              phx-debounce="300"
              phx-mounted={!@current.saved? && JS.focus()}
              maxlength="200"
              spellcheck="false"
              aria-label="Note title"
              class={[
                "min-w-0 max-w-xl flex-1 rounded border border-transparent bg-transparent px-1.5 py-0.5 text-[13px] font-medium outline-none transition-colors placeholder:text-faint hover:border-line-soft focus:border-accent/50 focus:bg-deep",
                if(@current.done_at, do: "text-muted", else: "text-ink")
              ]}
            />
          </div>

          <div
            id="note-mode"
            role="radiogroup"
            aria-label="Layout"
            class="my-1.5 flex shrink-0 items-center gap-0.5 rounded-md border border-line bg-deep p-0.5"
          >
            <button
              :for={{mode, label, icon} <- @modes}
              type="button"
              id={"note-mode-#{mode}"}
              phx-click="set_mode"
              phx-value-mode={mode}
              role="radio"
              aria-checked={to_string(@mode == mode)}
              title={label}
              class={[
                "flex h-5 cursor-pointer items-center gap-1 rounded px-1.5 text-[11px] transition-colors",
                if(@mode == mode,
                  do: "bg-active text-ink",
                  else: "text-faint hover:text-ink"
                )
              ]}
            >
              <.icon name={icon} class="size-3.5" />
              <span class="hidden lg:inline">{label}</span>
            </button>
          </div>

          <span
            id="note-status"
            class="flex shrink-0 items-center gap-1.5 px-3 text-[11px] text-faint"
          >
            <%= cond do %>
              <% !@current.saved? -> %>
                <.icon name="hero-pencil" class="size-3.5" /> Draft · kept once you write
              <% @current.done_at -> %>
                <.icon name="hero-check-circle" class="size-3.5 text-ok" />
                Done {when_label(@current.done_at)}
              <% true -> %>
                <.icon name="hero-check-circle" class="size-3.5 text-ok" />
                Saved {when_label(@current.updated_at)}
            <% end %>
          </span>
        </div>

        <div class="flex min-h-0 flex-1">
          <div
            id="note-write-pane"
            class={[
              "flex min-w-0 flex-col bg-deep",
              case @mode do
                "write" -> "flex-1"
                "split" -> "w-[var(--note-editor-width,50%)] min-w-56 shrink-0"
                "preview" -> "hidden"
              end
            ]}
          >
            <textarea
              id={"note-body-#{@current.id}"}
              name="body"
              phx-debounce="400"
              maxlength={@max_body}
              spellcheck="false"
              aria-label="Note body, in Markdown"
              placeholder="Write in Markdown. Use - [ ] for a checklist, **bold**, `code`, # headings…"
              class="min-h-0 flex-1 resize-none bg-transparent px-6 py-5 font-mono text-[13px] leading-relaxed text-ink caret-accent outline-none placeholder:text-faint"
            >{@current.body}</textarea>
          </div>

          <.resizer
            :if={@mode == "split"}
            id="note-editor-resizer"
            panel="note-write-pane"
            variable="--note-editor-width"
            storage_key="mdt:note-editor-width"
            axis="x"
            min="240"
            max="1400"
            label="Resize the editor"
          />

          <div
            id="note-preview-pane"
            class={[
              "min-w-0 flex-1 overflow-y-auto bg-panel",
              @mode == "write" && "hidden"
            ]}
          >
            <%= if @html == "" do %>
              <div class="flex h-full items-center justify-center p-6">
                <div class="flex flex-col items-center gap-3 text-center">
                  <span class="flex size-11 items-center justify-center rounded-xl border border-line bg-deep text-accent shadow-sm">
                    <.icon name="hero-document-text" class="size-5" />
                  </span>
                  <div>
                    <p class="text-sm text-ink">Nothing written yet</p>
                    <p class="mt-0.5 text-xs text-muted">
                      The note shows up here, rendered, as you write it.
                    </p>
                  </div>
                  <button
                    :if={@mode == "preview"}
                    type="button"
                    id="start-writing"
                    phx-click={JS.push("set_mode", value: %{mode: "split"})}
                    class="cursor-pointer rounded-md border border-line px-2.5 py-1 text-xs text-muted transition-colors hover:border-accent/60 hover:text-accent"
                  >
                    Start writing
                  </button>
                </div>
              </div>
            <% else %>
              <article
                id="note-preview"
                class="markdown mx-auto w-full max-w-3xl px-8 py-6"
              >
                {raw(@html)}
              </article>
            <% end %>
          </div>
        </div>
      </form>
    </section>
    """
  end

  ## Events

  # A change to the title or the body of the note the form is for. Anything
  # but the note open is one just left, still typing as it was switched
  # away from; a note deleted meanwhile stays deleted.
  @impl true
  def handle_event("edit", %{"note_id" => id} = params, socket) do
    %{username: username, current: current} = socket.assigns
    attrs = edits(params)

    cond do
      id == current.id and not current.saved? and blank?(attrs) ->
        {:noreply, socket}

      id == current.id ->
        {:ok, note} = Library.save(username, id, attrs)
        {:noreply, socket |> assign_current(current(note)) |> assign_list()}

      match?({:ok, _note}, Library.get(username, id)) ->
        {:ok, _note} = Library.save(username, id, attrs)
        {:noreply, assign_list(socket)}

      true ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("set_done", %{"id" => id, "done" => done}, socket) do
    socket = assign(socket, :menu, nil)

    case Library.set_done(socket.assigns.username, id, done == "true") do
      {:ok, note} ->
        socket =
          if id == socket.assigns.current.id,
            do: assign_current(socket, current(note)),
            else: socket

        {:noreply, assign_list(socket)}

      :error ->
        {:noreply, socket |> assign_list() |> put_flash(:error, "That note is gone")}
    end
  end

  @impl true
  def handle_event("set_mode", %{"mode" => mode}, socket) when mode in ~w(write split preview) do
    {:noreply, assign(socket, :mode, mode)}
  end

  @impl true
  def handle_event("new_note", _params, socket) do
    {:noreply, assign_current(socket, current(Note.new(), false))}
  end

  @impl true
  def handle_event("open_note", %{"id" => id}, socket) do
    socket = assign(socket, :menu, nil)

    if id == socket.assigns.current.id do
      {:noreply, socket}
    else
      case Library.get(socket.assigns.username, id) do
        {:ok, note} ->
          {:noreply, assign_current(socket, current(note))}

        :error ->
          {:noreply, socket |> assign_list() |> put_flash(:error, "That note is gone")}
      end
    end
  end

  # Deleting the note open moves on to the one changed last.
  @impl true
  def handle_event("delete_note", %{"id" => id}, socket) do
    _deleted = Library.delete(socket.assigns.username, id)
    socket = socket |> assign(:menu, nil) |> assign_list()

    if id == socket.assigns.current.id,
      do: {:noreply, open_latest(socket)},
      else: {:noreply, socket}
  end

  @impl true
  def handle_event("search", %{"term" => term}, socket) do
    {:noreply, socket |> assign(:term, term) |> assign_list()}
  end

  @impl true
  def handle_event("clear_search", _params, socket) do
    {:noreply, socket |> assign(:term, "") |> assign_list()}
  end

  @impl true
  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, :sidebar?, !socket.assigns.sidebar?)}
  end

  @impl true
  def handle_event("toggle_group", %{"group" => group}, socket) do
    collapsed = socket.assigns.collapsed

    collapsed =
      if MapSet.member?(collapsed, group),
        do: MapSet.delete(collapsed, group),
        else: MapSet.put(collapsed, group)

    {:noreply, assign(socket, :collapsed, collapsed)}
  end

  @impl true
  def handle_event("open_menu", %{"kind" => "note", "id" => id} = params, socket) do
    case Library.get(socket.assigns.username, id) do
      {:ok, note} ->
        menu = %{id: id, done?: Note.done?(note), at: point(params), anchor: params["anchor"]}
        {:noreply, assign(socket, :menu, menu)}

      :error ->
        {:noreply, assign_list(socket)}
    end
  end

  @impl true
  def handle_event("close_menu", _params, socket) do
    {:noreply, assign(socket, :menu, nil)}
  end

  # A note written, marked or deleted somewhere else. The list is redrawn,
  # and so is the note open if it was the one changed; while its body is
  # being typed in, the browser keeps what is typed rather than this.
  @impl true
  def handle_info({:notes_changed, id}, socket) do
    socket = assign_list(socket)
    %{username: username, current: current} = socket.assigns

    if current.saved? and id in [:all, current.id] do
      case Library.get(username, current.id) do
        {:ok, note} -> {:noreply, assign_current(socket, current(note))}
        :error -> {:noreply, open_latest(socket)}
      end
    else
      {:noreply, socket}
    end
  end

  ## Helpers

  # Only what the page shows.
  defp current(%Note{} = note, saved? \\ true) do
    %{
      id: note.id,
      title: note.title,
      body: note.body,
      done_at: note.done_at,
      updated_at: note.updated_at,
      saved?: saved?
    }
  end

  # The body is rendered again only when it changed, not on every keystroke
  # in the title or the search.
  defp assign_current(socket, current) do
    html =
      case socket.assigns do
        %{current: %{body: body}, html: html} when body == current.body -> html
        _other -> if String.trim(current.body) == "", do: "", else: Markdown.to_html(current.body)
      end

    assign(socket, current: current, html: html)
  end

  defp open_latest(socket) do
    case Library.latest(socket.assigns.username) do
      {:ok, note} -> assign_current(socket, current(note))
      :error -> assign_current(socket, current(Note.new(), false))
    end
  end

  defp edits(params) do
    for {param, field} <- [{"title", :title}, {"body", :body}],
        Map.has_key?(params, param),
        into: %{},
        do: {field, params[param]}
  end

  defp blank?(attrs), do: Enum.all?(attrs, fn {_field, value} -> String.trim(value) == "" end)

  defp assign_list(socket) do
    entries =
      socket.assigns.username
      |> Library.list(socket.assigns.term)
      |> Enum.map(&Map.put(&1, :when, when_label(&1.done_at || &1.updated_at)))

    {done, open} = Enum.split_with(entries, & &1.done_at)

    groups =
      Enum.reject([{"Open", "open", open}, {"Done", "done", done}], fn {_label, _key, entries} ->
        entries == []
      end)

    assign(socket, groups: groups, count: length(entries))
  end

  # Today's notes by the time, older ones by the day, read against the wall
  # clock of this machine.
  defp when_label(%DateTime{} = at) do
    at = local(at)
    today = NaiveDateTime.to_date(NaiveDateTime.local_now())

    cond do
      NaiveDateTime.to_date(at) == today -> Calendar.strftime(at, "%H:%M")
      at.year == today.year -> Calendar.strftime(at, "%b %-d")
      true -> Calendar.strftime(at, "%b %-d, %Y")
    end
  end

  defp local(%DateTime{} = at) do
    at
    |> DateTime.to_naive()
    |> NaiveDateTime.to_erl()
    |> :calendar.universal_time_to_local_time()
    |> NaiveDateTime.from_erl!()
  end

  # A right click places the menu at the pointer; the keyboard anchors it to the row.
  defp point(%{"x" => x, "y" => y}) when is_number(x) and is_number(y), do: %{x: x, y: y}
  defp point(_params), do: nil
end
