defmodule MDTClientWeb.SandboxLive do
  @moduledoc """
  The agent sandbox control panel: the VM, the grants it can be given, the
  approvals it waits on, its activity and its settings, one page each behind
  a sidebar.

  The LiveView coordinates and the `MDTClientWeb.SandboxLive.*` modules draw.
  Everything comes from `MDTClient.Sandbox` and is redrawn from its
  broadcasts, so a decision made in one window shows in every other, and
  timers (grants running out, approvals giving up) show as they happen.
  Broadcasts arrive in bursts while the VM is busy, so redraws are coalesced
  to one every `@refresh_every` milliseconds.
  """
  use MDTClientWeb, :live_view

  import MDTClientWeb.SandboxLive.Components

  alias MDTClient.Desktop.Notifications
  alias MDTClient.Sandbox
  alias MDTClient.Sandbox.{Event, Presets, RequestView, Shares}
  alias MDTClient.Tools
  alias MDTClientWeb.SandboxLive.{Activity, Approvals, Dialogs, Grants, Overview, Settings, Setup}

  @pages [
    {:overview, "Overview", "hero-squares-2x2", "/tools/sandbox"},
    {:approvals, "Approvals", "hero-hand-raised", "/tools/sandbox/approvals"},
    {:grants, "Grants", "hero-key", "/tools/sandbox/grants"},
    {:activity, "Activity", "hero-queue-list", "/tools/sandbox/activity"},
    {:settings, "Settings", "hero-cog-6-tooth", "/tools/sandbox/settings"},
    {:setup, "Setup", "hero-rocket-launch", "/tools/sandbox/setup"}
  ]

  @refresh_every 150

  # Activity rows per page. The server keeps the latest 1,000 events; a page
  # holds this many in the DOM, and only the first page takes new ones in.
  @page_size 50

  @impl true
  def mount(_params, _session, socket) do
    username = socket.assigns.current_scope.user.username
    if connected?(socket), do: Sandbox.subscribe(username)

    {:ok,
     socket
     |> assign(:page_title, "Agent Sandbox")
     |> assign(:tool, Tools.fetch!(:sandbox))
     |> assign(:username, username)
     |> assign(:refresh_timer, nil)
     |> assign(:durations, %{})
     |> assign(:adding, nil)
     |> assign(:confirm, nil)
     |> assign(:create_dialog, nil)
     |> assign(:memory_review, nil)
     |> assign(:name_error, nil)
     |> assign(:filters, %{q: "", group: "all", grant: ""})
     |> assign(:activity, %{cursors: [], older?: false, shown: 0, oldest: nil, fresh: 0})
     |> assign(:settings_tab, "general")
     |> assign(:page_size, @page_size)
     |> assign(:share_form, to_form(%{"path" => "", "mode" => "rw"}, as: :share))
     |> assign(:share_error, nil)
     |> assign(:vm_errors, %{})
     |> assign(:focus, nil)
     |> assign(:desktop, nil)
     |> stream_configure(:events, dom_id: &"event-#{&1.id}")
     |> stream(:events, [])
     |> refresh()
     |> assign_vm_form()
     |> assign_containerfile_form()
     |> assign_name_form()
     |> assign_host_form()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = assign(socket, :page, socket.assigns.live_action)

    socket =
      case socket.assigns.live_action do
        :grant ->
          assign(socket, :grant_id, params["id"])

        :activity ->
          reset_events(socket)

        :approvals ->
          assign(socket, :focus, params["focus"])

        :settings ->
          assign(socket,
            settings_tab: Settings.tab(params["tab"]),
            desktop: Notifications.status()
          )

        _ ->
          socket
      end

    {:noreply, socket |> refresh() |> page_title()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      tool={@tool}
      notices={@notices}
      update={@update}
      sandbox_waiting={@sandbox_waiting}
    >
      <div class="flex min-h-0 flex-1 overflow-hidden">
        <.sidebar
          page={@page}
          vm={@vm}
          waiting={length(@waiting)}
          grants_on={Enum.count(@grants, &(&1.state == :on))}
          proxy={@proxy}
          image={@image}
          setup_done={Setup.done?(@vm, @image, @settings)}
          now={@now}
        />

        <div id="sandbox-page" class="min-h-0 flex-1 overflow-y-auto">
          <div class="mx-auto w-full max-w-6xl px-6 py-6 lg:px-8">
            <%= case @page do %>
              <% :overview -> %>
                <Overview.page
                  vm={@vm}
                  image={@image}
                  created_ref={@created_ref}
                  proxy={@proxy}
                  tools={@tools}
                  settings={@settings}
                  memory={@memory}
                  grants={@grants}
                  grant_map={@grant_map}
                  waiting={@waiting}
                  running={@running}
                  ports={@ports}
                  recent={@recent}
                  stats={@stats}
                  now={@now}
                />
              <% :approvals -> %>
                <Approvals.page
                  waiting={@waiting}
                  running={@running}
                  history={@history}
                  grants={@grant_map}
                  marks={@marks}
                  hold_seconds={@settings.hold_seconds}
                  now={@now}
                  focus={@focus}
                />
              <% :grants -> %>
                <Grants.page grants={@grants} durations={@durations} now={@now} />
              <% :grant -> %>
                <%= if @grant do %>
                  <Grants.detail
                    grant={@grant}
                    has_value={@values[@grant.id]}
                    value_form={@value_form}
                    events={@grant_events}
                    duration={duration(@durations, @grant.id)}
                    now={@now}
                  />
                <% else %>
                  <div id="grant-missing" class="rounded-xl border border-dashed border-line">
                    <.empty icon="hero-key">
                      That grant doesn't exist any more.
                      <.link
                        patch={~p"/tools/sandbox/grants"}
                        class="text-accent hover:underline"
                      >See all grants</.link>
                    </.empty>
                  </div>
                <% end %>
              <% :activity -> %>
                <Activity.page
                  streams={@streams}
                  filters={@filters}
                  activity={@activity}
                  page_size={@page_size}
                  grants={@grants}
                  grant_names={Map.new(@grants, &{&1.id, &1.name})}
                  now={@now}
                />
              <% :settings -> %>
                <Settings.page
                  tab={@settings_tab}
                  vm={@vm}
                  image={@image}
                  builds={@builds}
                  created_ref={@created_ref}
                  snapshots={@snapshots}
                  memory={@memory}
                  folders={@folders}
                  name_form={@name_form}
                  name_error={@name_error}
                  tools={@tools}
                  inbox={@inbox}
                  settings={@settings}
                  containerfile_form={@containerfile_form}
                  containerfile_error={@containerfile_error}
                  vm_form={@vm_form}
                  vm_errors={@vm_errors}
                  share_form={@share_form}
                  share_error={@share_error}
                  host={@host}
                  host_form={@host_form}
                  host_error={@host_error}
                  desktop={@desktop}
                />
              <% :setup -> %>
                <Setup.page vm={@vm} image={@image} settings={@settings} tools={@tools} />
            <% end %>
          </div>
        </div>
      </div>

      <Grants.add_dialog :if={@adding} adding={@adding} waiting={@waiting} />
      <.confirm_dialog :if={@confirm} confirm={@confirm} />
      <Dialogs.create
        :if={@create_dialog}
        mode={@create_dialog}
        vm={@vm}
        image={@image}
        snapshots={@snapshots}
        memory={@memory}
        created_ref={@created_ref}
      />
      <Dialogs.memory_review :if={@memory_review} review={@memory_review} />
    </Layouts.app>
    """
  end

  ## Sidebar

  attr :page, :atom, required: true
  attr :vm, :any, required: true
  attr :waiting, :integer, required: true
  attr :grants_on, :integer, required: true
  attr :proxy, :map, required: true
  attr :image, :map, required: true
  attr :setup_done, :boolean, required: true
  attr :now, DateTime, required: true

  defp sidebar(assigns) do
    assigns = assign(assigns, pages: @pages)

    ~H"""
    <aside
      id="sandbox-nav"
      class="flex w-56 shrink-0 flex-col border-r border-line-soft bg-panel"
    >
      <div class="border-b border-line-soft px-3 py-3">
        <div class="flex items-center gap-2.5">
          <span class={[
            "flex size-8 shrink-0 items-center justify-center rounded-lg border transition-colors",
            if(@vm.status == :running,
              do: "border-ok/35 bg-ok-soft/50 text-ok-strong",
              else: "border-line bg-deep text-muted"
            )
          ]}>
            <.icon name="hero-cube-transparent" class="size-4" />
          </span>
          <div class="min-w-0 flex-1">
            <p class="truncate text-[13px] font-semibold text-ink">{@vm.name}</p>
            <.vm_status vm={@vm} id="sidebar-vm-status" />
          </div>
          <button
            :if={@vm.status in [:stopped, :crashed] and is_nil(@vm.busy) and @image.loaded?}
            type="button"
            id="sidebar-vm-start"
            phx-click="start_vm"
            title="Start the VM"
            class="flex size-7 cursor-pointer items-center justify-center rounded-md text-ok transition-colors hover:bg-ok-soft/50"
          >
            <.icon name="hero-play-solid" class="size-3.5" />
          </button>
          <button
            :if={@vm.status == :running and is_nil(@vm.busy)}
            type="button"
            id="sidebar-vm-stop"
            phx-click="stop_vm"
            title="Stop the VM"
            class="flex size-7 cursor-pointer items-center justify-center rounded-md text-muted transition-colors hover:bg-hover hover:text-bad"
          >
            <.icon name="hero-stop-solid" class="size-3.5" />
          </button>
        </div>
        <p
          :if={@vm.stale?}
          class="mt-2 flex items-center gap-1.5 rounded-md bg-warn-soft/40 px-2 py-1 text-[10px] font-medium text-warn-strong"
        >
          <.icon name="hero-arrow-path-micro" class="size-3" /> Recreate to apply settings
        </p>
      </div>

      <nav aria-label="Agent sandbox" class="flex flex-col gap-0.5 p-2">
        <.link
          :for={{id, label, icon, path} <- @pages}
          patch={path}
          id={"sandbox-nav-#{id}"}
          aria-current={nav_current?(@page, id) && "page"}
          class={[
            "group flex h-8 items-center gap-2.5 rounded-md px-2.5 text-[13px] transition-colors",
            if(nav_current?(@page, id),
              do: "bg-active font-medium text-ink",
              else: "text-muted hover:bg-hover hover:text-ink"
            )
          ]}
        >
          <.icon
            name={icon}
            class={[
              "size-4 transition-colors",
              if(nav_current?(@page, id),
                do: "text-accent",
                else: "text-faint group-hover:text-muted"
              )
            ]}
          />
          <span class="flex-1">{label}</span>
          <span
            :if={id == :approvals and @waiting > 0}
            id="sandbox-nav-waiting"
            class="rounded-full bg-warn px-1.5 py-px text-[10px] font-bold tabular-nums text-deep"
          >
            {@waiting}
          </span>
          <span
            :if={id == :grants and @grants_on > 0}
            class="rounded-full bg-ok-soft px-1.5 py-px text-[10px] font-semibold tabular-nums text-ok-strong"
          >
            {@grants_on} on
          </span>
          <span
            :if={id == :setup and not @setup_done}
            id="sandbox-nav-setup-todo"
            title="Some setup steps are left"
            class="size-1.5 rounded-full bg-accent"
          ></span>
        </.link>
      </nav>

      <div class="flex-1"></div>

      <div
        id="sandbox-health"
        class="m-2 space-y-1.5 rounded-lg border border-line-soft bg-deep/40 p-2.5"
      >
        <p class="flex items-center gap-1.5 text-[11px]">
          <span class={[
            "size-1.5 shrink-0 rounded-full",
            if(@proxy.listening?, do: "bg-ok", else: "bg-bad")
          ]}></span>
          <span class="text-muted">Proxy</span>
          <span class="ml-auto font-mono text-[10px] text-faint">
            {if @proxy.listening?, do: "127.0.0.1:#{@proxy.port}", else: "down"}
          </span>
        </p>
        <p :if={@proxy.error} class="text-[10px] leading-4 text-bad">{@proxy.error}</p>
        <p class="flex items-center gap-1.5 text-[11px]">
          <span class={[
            "size-1.5 shrink-0 rounded-full",
            cond do
              @image.building? -> "bg-warn motion-safe:animate-pulse"
              @image.loaded? -> "bg-ok"
              true -> "bg-faint"
            end
          ]}></span>
          <span class="text-muted">Image</span>
          <span class="ml-auto truncate font-mono text-[10px] text-faint" title={@image.tag}>
            <%= cond do %>
              <% @image.building? -> %>
                building…
              <% @image.loaded? -> %>
                {@image.tag |> String.split(":") |> List.last()}
              <% true -> %>
                not built
            <% end %>
          </span>
        </p>
      </div>
    </aside>
    """
  end

  defp nav_current?(:grant, :grants), do: true
  defp nav_current?(page, id), do: page == id

  ## Confirm

  attr :confirm, :map, required: true

  defp confirm_dialog(assigns) do
    ~H"""
    <div
      id="sandbox-confirm"
      class="fixed inset-0 z-50 flex items-center justify-center p-6"
      role="dialog"
      aria-modal="true"
      aria-labelledby="sandbox-confirm-title"
      phx-window-keydown="cancel_confirm"
      phx-key="Escape"
    >
      <div class="absolute inset-0 bg-black/50" phx-click="cancel_confirm"></div>
      <div class="relative w-full max-w-sm rounded-xl border border-line bg-panel p-4 shadow-2xl shadow-black/30 dark:shadow-black/60">
        <div class="flex items-start gap-2.5">
          <span class="flex size-8 shrink-0 items-center justify-center rounded-lg border border-bad/40 bg-bad-soft/40">
            <.icon name="hero-exclamation-triangle" class="size-4 text-bad" />
          </span>
          <div class="min-w-0">
            <p id="sandbox-confirm-title" class="text-[13px] font-semibold text-ink">
              {@confirm.title}
            </p>
            <p class="mt-1 text-[11px] leading-relaxed text-muted">{@confirm.message}</p>
          </div>
        </div>
        <div class="mt-4 flex items-center justify-end gap-2">
          <.button type="button" id="sandbox-confirm-cancel" phx-click="cancel_confirm">Cancel</.button>
          <.button
            type="button"
            id="sandbox-confirm-accept"
            variant="danger"
            phx-click="accept_confirm"
            phx-mounted={JS.focus()}
          >
            {@confirm.label}
          </.button>
        </div>
      </div>
    </div>
    """
  end

  ## Events

  @impl true
  # Starting a VM that exists goes straight through; creating one first asks
  # what happens to what it keeps.
  def handle_event("start_vm", _params, socket) do
    cond do
      not socket.assigns.image.loaded? ->
        vm_action(socket, &Sandbox.start_vm/1)

      socket.assigns.vm.exists? and not socket.assigns.vm.stale? ->
        vm_action(socket, &Sandbox.start_vm/1)

      socket.assigns.vm.exists? ->
        {:noreply, assign(socket, :create_dialog, :recreate)}

      true ->
        {:noreply, assign(socket, :create_dialog, :create)}
    end
  end

  def handle_event("stop_vm", _params, socket), do: vm_action(socket, &Sandbox.stop_vm/1)

  def handle_event("recreate_vm", _params, socket) do
    if socket.assigns.image.loaded?,
      do: {:noreply, assign(socket, :create_dialog, :recreate)},
      else: vm_action(socket, &Sandbox.recreate_vm/1)
  end

  def handle_event("close_create", _params, socket),
    do: {:noreply, assign(socket, :create_dialog, nil)}

  def handle_event("confirm_create", params, socket) do
    choices = Map.get(params, "create", %{})

    options = %{
      home:
        case choices["home"] do
          "empty" -> :empty
          "snapshot:" <> id -> {:snapshot, id}
          _keep -> :keep
        end,
      cache: if(choices["cache"] == "clear", do: :clear, else: :keep),
      seed_memory: choices["seed_memory"] == "true"
    }

    fun =
      if socket.assigns.create_dialog == :recreate,
        do: &Sandbox.recreate_vm(&1, options),
        else: &Sandbox.start_vm(&1, options)

    vm_action(assign(socket, :create_dialog, nil), fun)
  end

  def handle_event("use_build", %{"ref" => ref}, socket) do
    case Sandbox.use_build(socket.assigns.username, ref) do
      :ok ->
        {:noreply,
         socket
         |> refresh()
         |> put_notice(:success, "#{ref} is current",
           body:
             "Recreate the VM to run it. Its Home from that time is offered if a copy was kept."
         )}

      {:error, :busy} ->
        {:noreply, put_notice(socket, :info, "Wait for the build to finish")}

      {:error, :not_found} ->
        {:noreply, socket |> refresh() |> put_notice(:warning, "That build is gone")}
    end
  end

  def handle_event("save_image_name", %{"image_name" => %{"name" => name}}, socket) do
    case Sandbox.update_settings(socket.assigns.username, %{"image_name" => name}) do
      {:ok, _settings} ->
        {:noreply,
         socket
         |> assign(:name_error, nil)
         |> refresh()
         |> assign_name_form()
         |> put_notice(:success, "Image name saved", body: "The next build uses it.")}

      {:error, errors} ->
        {:noreply,
         assign(socket,
           name_form: to_form(%{"name" => name}, as: :image_name),
           name_error: errors[:image_name]
         )}
    end
  end

  def handle_event("seed_memory", _params, socket) do
    socket =
      case Sandbox.seed_memory(socket.assigns.username) do
        :ok ->
          socket

        {:error, :running} ->
          put_notice(socket, :warning, "Stop the VM first",
            body: "Its memory can only be replaced while nothing in it is writing."
          )

        {:error, :busy} ->
          put_notice(socket, :info, "The VM is busy; try again in a moment")

        {:error, :no_memory} ->
          put_notice(socket, :warning, "No memory of yours to copy",
            body: "OptMem isn't set up on this machine."
          )
      end

    {:noreply, refresh(socket)}
  end

  def handle_event("review_memories", _params, socket) do
    %{entries: entries, upto: upto} = Sandbox.vm_memories(socket.assigns.username)

    {:noreply,
     assign(socket, :memory_review, %{entries: entries, upto: upto, texts: %{}, errors: %{}})}
  end

  def handle_event("close_review", _params, socket),
    do: {:noreply, assign(socket, :memory_review, nil)}

  def handle_event("dismiss_memories", _params, socket) do
    :ok = Sandbox.dismiss_memories(socket.assigns.username, socket.assigns.memory_review.upto)
    {:noreply, socket |> assign(:memory_review, nil) |> refresh()}
  end

  def handle_event("bring_back", params, socket) do
    review = socket.assigns.memory_review
    choices = Map.get(params, "review", %{})
    texts = Map.get(choices, "text", %{})

    picked =
      for index <- Map.get(choices, "pick", []),
          {index, ""} <- [Integer.parse(index)],
          entry = Enum.find(review.entries, &(&1.index == index)),
          do: {entry, String.trim(texts[to_string(index)] || "[vm] " <> entry.text)}

    if picked == [] do
      {:noreply, put_notice(socket, :info, "Tick the memories to add first")}
    else
      results =
        Sandbox.bring_back(
          socket.assigns.username,
          Enum.map(picked, &elem(&1, 1)),
          review.upto
        )

      failed =
        for {{entry, text}, {:error, message}} <- Enum.zip(picked, results),
            do: {entry, text, message}

      added = length(picked) - length(failed)

      if failed == [] do
        {:noreply,
         socket
         |> assign(:memory_review, nil)
         |> refresh()
         |> put_notice(:success, "#{added} added to your memory",
           body: "Your next agent session will be asked to summarize them."
         )}
      else
        added_indexes =
          MapSet.new(for {{entry, _}, :ok} <- Enum.zip(picked, results), do: entry.index)

        review = %{
          review
          | entries: Enum.reject(review.entries, &MapSet.member?(added_indexes, &1.index)),
            texts: Map.new(failed, fn {entry, text, _} -> {entry.index, text} end),
            errors: Map.new(failed, fn {entry, _, message} -> {entry.index, message} end)
        }

        {:noreply,
         socket
         |> assign(:memory_review, review)
         |> put_notice(:warning, "#{length(failed)} not added",
           body: "memo refused them; see each one. #{added} went in."
         )}
      end
    end
  end

  def handle_event("pick_duration", %{"id" => id, "minutes" => minutes}, socket) do
    {:noreply, update(socket, :durations, &Map.put(&1, id, parse_duration(minutes)))}
  end

  def handle_event("turn_on", %{"id" => id}, socket) do
    minutes = socket.assigns.durations |> duration(id) |> to_minutes()
    {:ok, _grant} = Sandbox.turn_on(socket.assigns.username, id, minutes)
    {:noreply, refresh(socket)}
  end

  def handle_event("turn_off", %{"id" => id}, socket) do
    {:ok, _grant} = Sandbox.turn_off(socket.assigns.username, id)
    {:noreply, refresh(socket)}
  end

  def handle_event("allow_all", %{"id" => id, "minutes" => minutes}, socket) do
    socket =
      case Sandbox.allow_all(socket.assigns.username, id, allow_minutes(minutes)) do
        {:ok, _grant} -> socket
        {:error, :off} -> put_notice(socket, :info, "Turn the grant on first")
        {:error, :not_found} -> socket
      end

    {:noreply, refresh(socket)}
  end

  def handle_event("revoke_allowance", %{"id" => id, "allowance" => allowance}, socket) do
    {:ok, _grant} = Sandbox.revoke_allowance(socket.assigns.username, id, allowance)
    {:noreply, refresh(socket)}
  end

  def handle_event("decide", %{"id" => id, "decision" => decision} = params, socket) do
    decision =
      case decision do
        "allow_once" -> :allow_once
        "allow_similar" -> {:allow, :similar, allow_minutes(params["minutes"])}
        "allow_all" -> {:allow, :all, allow_minutes(params["minutes"])}
        "deny" -> :deny
        "deny_and_turn_off" -> :deny_and_turn_off
        "decline" -> :decline
        "send_output" -> :send_output
        "keep_output" -> :keep_output
      end

    {:noreply, socket |> decide(id, decision) |> refresh()}
  end

  # A command, run once from its full card, with its output going to the
  # agent or to you first.
  def handle_event("run_command", %{"run" => %{"id" => id} = params}, socket) do
    output_to = if params["output"] == "review", do: :review, else: :send
    {:noreply, socket |> decide(id, {:run, output_to}) |> refresh()}
  end

  def handle_event("stop_command", %{"id" => id}, socket) do
    socket =
      case Sandbox.stop_command(socket.assigns.username, id) do
        :ok -> socket
        {:error, :not_running} -> put_notice(socket, :info, "It had already ended")
      end

    {:noreply, refresh(socket)}
  end

  def handle_event("save_host_notes", %{"host" => %{"notes" => notes}}, socket) do
    case Sandbox.update_settings(socket.assigns.username, %{"host_notes" => notes}) do
      {:ok, _settings} ->
        {:noreply,
         socket
         |> refresh()
         |> assign_host_form()
         |> put_notice(:info, "Notes saved; agents see them with mdt host")}

      {:error, errors} ->
        {:noreply,
         socket
         |> assign(:host_form, to_form(%{"notes" => notes}, as: :host))
         |> assign(:host_error, errors[:host_notes])}
    end
  end

  def handle_event("probe_host", _params, socket) do
    _ = Sandbox.probe_host(socket.assigns.username)
    {:noreply, refresh(socket)}
  end

  # An agent's ask, answered from its card: for how long, and whether each
  # use still asks.
  def handle_event("turn_on_ask", %{"ask" => %{"id" => id} = params}, socket) do
    minutes = params["minutes"] |> parse_duration() |> to_minutes()
    uses = if params["uses"] == "all", do: :all, else: :ask
    {:noreply, socket |> decide(id, {:turn_on, minutes, uses}) |> refresh()}
  end

  def handle_event("open_add_grant", params, socket) do
    {:noreply, assign(socket, :adding, %{step: :pick, approval_id: params["approval"]})}
  end

  def handle_event("close_add_grant", _params, socket),
    do: {:noreply, assign(socket, :adding, nil)}

  def handle_event("add_grant_back", _params, socket) do
    {:noreply, update(socket, :adding, &%{step: :pick, approval_id: &1.approval_id})}
  end

  def handle_event("pick_preset", %{"preset" => id}, socket) do
    {:ok, preset} = Presets.find(id)

    ask =
      Enum.find(socket.assigns.waiting, &(&1.id == socket.assigns.adding.approval_id))

    params =
      Map.merge(
        %{
          "name" =>
            if(ask && ask.need, do: String.slice(ask.need, 0, 60), else: preset_name(preset))
        },
        preset.fields
      )

    params =
      if ask && ask.need && params["purpose"] in [nil, ""],
        do: Map.put(params, "purpose", ask.need),
        else: params

    {:noreply,
     update(socket, :adding, fn adding ->
       Map.merge(adding, %{
         step: :details,
         preset: preset,
         form: to_form(params, as: :grant),
         errors: %{}
       })
     end)}
  end

  def handle_event("validate_grant", %{"grant" => params}, socket) do
    {:noreply, update(socket, :adding, &%{&1 | form: to_form(params, as: :grant)})}
  end

  def handle_event("create_grant", %{"grant" => params}, socket) do
    username = socket.assigns.username

    case Sandbox.create_grant(username, params) do
      {:ok, grant} ->
        socket =
          case socket.assigns.adding.approval_id do
            nil ->
              put_notice(socket, :success, "#{grant.name} added",
                body:
                  "It starts off. Turn it on when a task needs it, or let an agent ask for it."
              )

            approval_id ->
              socket
              |> decide(approval_id, {:set_up, grant.id})
              |> put_notice(:success, "#{grant.name} added and turned on",
                body: "The agent that asked hears it is on. Each use still waits for you."
              )
          end

        {:noreply,
         socket
         |> assign(:adding, nil)
         |> push_patch(to: ~p"/tools/sandbox/grants/#{grant.id}")}

      {:error, errors} ->
        {:noreply,
         update(socket, :adding, &%{&1 | form: to_form(params, as: :grant), errors: errors})}
    end
  end

  def handle_event("confirm_delete_grant", %{"id" => id}, socket) do
    grant = socket.assigns.grant_map[id]

    {:noreply,
     assign(socket, :confirm, %{
       title: "Remove #{grant.name}?",
       message:
         "Anything waiting on it is refused, agents' asks included. Its allowances go with it. The VM keeps a placeholder that no longer means anything.",
       label: "Remove",
       action: {:delete_grant, id}
     })}
  end

  def handle_event("cancel_confirm", _params, socket),
    do: {:noreply, assign(socket, :confirm, nil)}

  def handle_event("accept_confirm", _params, socket) do
    case socket.assigns.confirm.action do
      {:delete_grant, id} ->
        :ok = Sandbox.delete_grant(socket.assigns.username, id)

        {:noreply,
         socket
         |> assign(:confirm, nil)
         |> push_patch(to: ~p"/tools/sandbox/grants")}
    end
  end

  def handle_event("filter_activity", params, socket) do
    filters = %{
      q: params["q"] || "",
      group: if(Map.has_key?(Event.groups(), params["group"]), do: params["group"], else: "all"),
      grant: params["grant"] || ""
    }

    {:noreply, socket |> assign(:filters, filters) |> reset_events()}
  end

  # Page 1 takes new events in, so its last row moves; the cursor is read
  # again rather than remembered.
  def handle_event("older_activity", _params, socket) do
    %{activity: activity, filters: filters, username: username} = socket.assigns

    cursor =
      case activity.cursors do
        [] ->
          username
          |> Sandbox.events(Map.put(filters, :limit, @page_size))
          |> List.last()
          |> then(&(&1 && &1.id))

        _older ->
          activity.oldest
      end

    {:noreply,
     if(cursor, do: socket |> load_events([cursor | activity.cursors]) |> paged(), else: socket)}
  end

  def handle_event("newer_activity", _params, socket) do
    cursors =
      case socket.assigns.activity.cursors do
        [_ | rest] -> rest
        [] -> []
      end

    {:noreply, socket |> load_events(cursors) |> paged()}
  end

  def handle_event("latest_activity", _params, socket),
    do: {:noreply, socket |> reset_events() |> paged()}

  def handle_event("share_changed", %{"share" => params}, socket) do
    {:noreply, assign(socket, share_form: to_form(params, as: :share), share_error: nil)}
  end

  def handle_event("add_share", %{"share" => params}, socket) do
    mode = if params["mode"] == "ro", do: :ro, else: :rw

    case Sandbox.add_share(socket.assigns.username, params["path"] || "", mode) do
      {:ok, _share} ->
        {:noreply,
         socket
         |> assign(share_form: to_form(%{"path" => "", "mode" => params["mode"]}, as: :share))
         |> assign(:share_error, nil)
         |> refresh()}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           share_form: to_form(params, as: :share),
           share_error: Shares.explain(reason)
         )}
    end
  end

  # Folders picked in the desktop app's folder dialog, any number at once.
  def handle_event("add_shares", %{"paths" => paths} = params, socket) when is_list(paths) do
    mode = if params["mode"] == "ro", do: :ro, else: :rw

    results =
      for path <- paths, is_binary(path) do
        {path, Sandbox.add_share(socket.assigns.username, path, mode)}
      end

    added = Enum.count(results, &match?({_, {:ok, _}}, &1))

    failed =
      for {path, {:error, reason}} <- results,
          do: "#{Path.basename(path)}: #{Shares.explain(reason)}"

    socket =
      socket
      |> assign(:share_error, if(failed == [], do: nil, else: Enum.join(failed, " ")))
      |> refresh()

    socket =
      case added do
        0 -> socket
        1 -> put_notice(socket, :success, "Folder shared", body: recreate_words(socket))
        n -> put_notice(socket, :success, "#{n} folders shared", body: recreate_words(socket))
      end

    {:noreply, socket}
  end

  def handle_event("folder_picker_unavailable", %{"reason" => reason}, socket) do
    {:noreply, assign(socket, :share_error, reason <> " Type the folder's path instead.")}
  end

  def handle_event("remove_share", %{"path" => path}, socket) do
    :ok = Sandbox.remove_share(socket.assigns.username, path)
    {:noreply, refresh(socket)}
  end

  def handle_event("set_share_mode", %{"path" => path, "mode" => mode}, socket) do
    :ok =
      Sandbox.set_share_mode(socket.assigns.username, path, if(mode == "ro", do: :ro, else: :rw))

    {:noreply, refresh(socket)}
  end

  def handle_event("save_settings", %{"vm" => params}, socket) do
    case Sandbox.update_settings(socket.assigns.username, params) do
      {:ok, _settings} ->
        {:noreply,
         socket
         |> assign(:vm_errors, %{})
         |> refresh()
         |> assign_vm_form()
         |> put_notice(:success, "Settings saved")}

      {:error, errors} ->
        {:noreply, assign(socket, vm_form: to_form(params, as: :vm), vm_errors: errors)}
    end
  end

  def handle_event("save_notifications", %{"on" => on}, socket) do
    {:ok, settings} =
      Sandbox.update_settings(socket.assigns.username, %{"desktop_notifications" => on})

    message =
      if settings.desktop_notifications,
        do: "Approvals waiting for you will show on the desktop",
        else: "Desktop notifications are off"

    {:noreply, socket |> refresh() |> put_notice(:info, message)}
  end

  # A notice like the real ones, opening this page. It belongs to this page,
  # so it goes when the page does.
  def handle_event("test_notification", _params, socket) do
    username = socket.assigns.username

    Notifications.show({:test, username}, %{
      summary: "MDT notifications work",
      body: "Agents' requests will show like this. Click one to open it in MDT.",
      scope: username,
      open: "/tools/sandbox/settings"
    })

    {:noreply,
     socket
     |> assign(:desktop, Notifications.status())
     |> put_notice(:info, "Sent a test notification")}
  end

  def handle_event("build_image", _params, socket) do
    socket =
      case Sandbox.build_image(socket.assigns.username) do
        :ok ->
          socket

        {:error, :busy} ->
          put_notice(socket, :info, "A build is already running")

        {:error, :no_podman} ->
          put_notice(socket, :error, "podman is not installed",
            body: "MDT builds the VM image with podman."
          )

        {:error, :no_msb} ->
          put_notice(socket, :error, "MDT's microsandbox runtime is missing",
            body:
              "Packaged MDT ships it. In a source checkout, run scripts/build-microsandbox.sh."
          )
      end

    {:noreply, refresh(socket)}
  end

  def handle_event("save_containerfile", %{"image" => %{"containerfile" => text}}, socket) do
    case Sandbox.update_settings(socket.assigns.username, %{"containerfile" => text}) do
      {:ok, _settings} ->
        {:noreply,
         socket
         |> assign(:containerfile_error, nil)
         |> refresh()
         |> assign_containerfile_form()
         |> put_notice(:success, "Containerfile saved", body: "Build the image to use it.")}

      {:error, errors} ->
        {:noreply,
         assign(socket,
           containerfile_form: to_form(%{"containerfile" => text}, as: :image),
           containerfile_error: errors[:containerfile]
         )}
    end
  end

  def handle_event("reset_containerfile", _params, socket) do
    {:noreply,
     assign(socket,
       containerfile_form:
         to_form(%{"containerfile" => MDTClient.Sandbox.Image.default_containerfile()},
           as: :image
         ),
       containerfile_error: nil
     )}
  end

  def handle_event("set_value", %{"value" => %{"value" => value}}, socket) do
    socket =
      cond do
        String.trim(value) == "" ->
          socket

        Sandbox.set_value(socket.assigns.username, socket.assigns.grant_id, value) == :ok ->
          put_notice(socket, :success, "Value replaced",
            body: "Kept in your vault. The VM still only sees the placeholder."
          )

        true ->
          put_notice(socket, :error, "Could not replace the value")
      end

    {:noreply, socket |> assign(:value_form, to_form(%{"value" => ""}, as: :value)) |> refresh()}
  end

  ## Broadcasts

  @impl true
  def handle_info({:sandbox_changed, _area}, socket), do: {:noreply, schedule_refresh(socket)}

  def handle_info({:sandbox_build_line, _line}, socket), do: {:noreply, schedule_refresh(socket)}

  def handle_info({:sandbox_event, event}, socket) do
    socket =
      if socket.assigns.page == :activity and Event.matches?(event, socket.assigns.filters),
        do: take_event(socket, event),
        else: socket

    {:noreply, schedule_refresh(socket)}
  end

  def handle_info(:refresh, socket) do
    {:noreply, socket |> assign(:refresh_timer, nil) |> refresh()}
  end

  # The first page shows the newest events as they come; an older page stays
  # put and counts what it is missing.
  defp take_event(%{assigns: %{activity: %{cursors: []} = activity}} = socket, event) do
    socket
    |> stream_insert(:events, event, at: 0, limit: @page_size)
    |> assign(:activity, %{
      activity
      | shown: min(activity.shown + 1, @page_size),
        older?: activity.older? or activity.shown >= @page_size
    })
  end

  defp take_event(socket, _event),
    do: update(socket, :activity, &%{&1 | fresh: &1.fresh + 1})

  defp schedule_refresh(%{assigns: %{refresh_timer: nil}} = socket) do
    assign(socket, :refresh_timer, Process.send_after(self(), :refresh, @refresh_every))
  end

  defp schedule_refresh(socket), do: socket

  ## Loading

  defp refresh(socket) do
    username = socket.assigns.username
    snapshot = Sandbox.snapshot(username)
    grant_map = Map.new(snapshot.grants, &{&1.id, &1})

    socket
    |> assign(:now, DateTime.utc_now() |> DateTime.truncate(:second))
    |> assign(snapshot)
    |> assign(:grant_map, grant_map)
    |> assign(:marks, RequestView.marks(snapshot.grants))
    |> assign_page_data(grant_map)
  end

  defp assign_page_data(socket, grant_map) do
    username = socket.assigns.username

    case socket.assigns[:page] do
      :overview ->
        hour = Sandbox.events(username, %{limit: 500})
        since = DateTime.add(socket.assigns.now, -3600, :second)
        last_hour = Enum.filter(hour, &(DateTime.compare(&1.at, since) == :gt))

        socket
        |> assign(:recent, Enum.take(hour, 7))
        |> assign(:stats, %{
          waiting: length(socket.assigns.waiting),
          connections: Enum.count(last_hour, &(&1.outcome in [:tunnel, :swapped, :allowed])),
          credentials: Enum.count(last_hour, &(&1.outcome in [:swapped, :allowed])),
          blocked: Enum.count(last_hour, &(&1.outcome in [:blocked, :violation]))
        })

      :grant ->
        grant = grant_map[socket.assigns.grant_id]

        socket
        |> assign(:grant, grant)
        |> assign_new(:value_form, fn -> to_form(%{"value" => ""}, as: :value) end)
        |> assign(
          :grant_events,
          if(grant, do: Sandbox.events(username, %{grant: grant.id, limit: 10}), else: [])
        )

      _other ->
        socket
    end
  end

  defp reset_events(socket), do: load_events(socket, [])

  defp paged(socket), do: push_event(socket, "activity_paged", %{})

  # `cursors` are the ids each older page starts after, the current page's
  # first; none is the newest page.
  defp load_events(socket, cursors) do
    filters =
      socket.assigns.filters
      |> Map.put(:limit, @page_size + 1)
      |> then(fn filters ->
        case cursors do
          [before | _] -> Map.put(filters, :before, before)
          [] -> filters
        end
      end)

    {page, rest} = socket.assigns.username |> Sandbox.events(filters) |> Enum.split(@page_size)

    socket
    |> assign(:activity, %{
      cursors: cursors,
      older?: rest != [],
      shown: length(page),
      oldest: page |> List.last() |> then(&(&1 && &1.id)),
      fresh: 0
    })
    |> stream(:events, page, reset: true)
  end

  defp assign_vm_form(socket) do
    settings = socket.assigns.settings

    assign(
      socket,
      :vm_form,
      to_form(
        %{
          "cpus" => settings.cpus,
          "memory_gib" => settings.memory_gib,
          "disk_gib" => settings.disk_gib,
          "write_budget_gib" => settings.write_budget_gib,
          "hold_seconds" => settings.hold_seconds,
          "proxy_port" => settings.proxy_port
        },
        as: :vm
      )
    )
  end

  defp assign_host_form(socket) do
    socket
    |> assign(:host_form, to_form(%{"notes" => socket.assigns.settings.host_notes}, as: :host))
    |> assign(:host_error, nil)
  end

  defp assign_name_form(socket) do
    assign(
      socket,
      :name_form,
      to_form(%{"name" => socket.assigns.settings.image_name}, as: :image_name)
    )
  end

  defp assign_containerfile_form(socket) do
    socket
    |> assign(
      :containerfile_form,
      to_form(%{"containerfile" => socket.assigns.settings.containerfile}, as: :image)
    )
    |> assign(:containerfile_error, nil)
  end

  defp page_title(socket) do
    title =
      case socket.assigns.page do
        :grant -> (socket.assigns[:grant] && socket.assigns.grant.name) || "Grant"
        page -> @pages |> List.keyfind(page, 0) |> elem(1)
      end

    assign(socket, :page_title, "#{title} · Agent Sandbox")
  end

  defp vm_action(socket, fun) do
    case fun.(socket.assigns.username) do
      :ok ->
        {:noreply, refresh(socket)}

      {:error, :busy} ->
        {:noreply, put_notice(socket, :info, "The VM is busy; try again in a moment")}

      {:error, :no_image} ->
        {:noreply,
         put_notice(socket, :warning, "Build the image first",
           body: "Setup → Build the image. The VM boots from it."
         )}

      {:error, :no_snapshot} ->
        {:noreply, socket |> refresh() |> put_notice(:warning, "That copy of Home is gone")}

      {:error, :no_memory} ->
        {:noreply,
         put_notice(socket, :warning, "No memory of yours to copy",
           body: "OptMem isn't set up on this machine."
         )}

      {:error, _other} ->
        {:noreply, put_notice(socket, :error, "The VM could not be created with those choices")}
    end
  end

  ## Small things

  defp duration(durations, id), do: Map.get(durations, id, 60)

  defp recreate_words(socket) do
    if socket.assigns.vm.exists?,
      do: "The VM sees it once it is recreated.",
      else: "The VM sees it when it is created."
  end

  # `JS.push` sends the integer as JSON, a form would send a string.
  defp parse_duration("until_off"), do: "until_off"
  defp parse_duration(minutes) when is_integer(minutes), do: minutes
  defp parse_duration(minutes) when is_binary(minutes), do: String.to_integer(minutes)

  defp to_minutes("until_off"), do: :until_off
  defp to_minutes(minutes) when is_integer(minutes), do: minutes

  defp allow_minutes("grant"), do: :grant
  defp allow_minutes(minutes), do: String.to_integer(minutes)

  defp decide(socket, id, decision) do
    case Sandbox.decide(socket.assigns.username, id, decision) do
      :ok ->
        socket

      {:error, :not_waiting} ->
        put_notice(socket, :info, "That was already settled")

      {:error, :bad_decision} ->
        put_notice(socket, :error, "That choice doesn't fit this approval")
    end
  end

  # Types start unnamed; a preset suggests its own name.
  defp preset_name(%{id: id}) when id in [:token, :network, :file], do: ""
  defp preset_name(%{name: name}), do: name
end
