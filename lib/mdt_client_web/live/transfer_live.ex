defmodule MDTClientWeb.TransferLive do
  @moduledoc """
  Exports everything an identity keeps into one file, and imports such files.

  Files are read and written by the server, which runs on this machine, so the
  page deals only in paths: the desktop app's native dialogs pick them, and in
  a plain browser they are typed. Importing is two steps — the file is opened
  and checked first, and nothing changes until the user has seen what it
  holds, chosen to merge or replace, and confirmed. `MDTClient.Transfer` does
  the work.
  """
  use MDTClientWeb, :live_view

  alias MDTClient.HttpClient.Utils
  alias MDTClient.Transfer

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Export and import")
     |> assign(:username, socket.assigns.current_scope.user.username)
     |> assign(:included, Enum.map(Transfer.participants(), & &1.label()))
     |> assign(:picker_notice, nil)
     |> reset_export()
     |> reset_import()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} notices={@notices}>
      <div class="flex min-h-0 flex-1 justify-center overflow-y-auto p-6">
        <div class="w-full max-w-2xl py-2">
          <header class="mb-6 flex items-start gap-3">
            <span class="flex size-9 shrink-0 items-center justify-center rounded-lg border border-line bg-panel text-accent">
              <.icon name="hero-arrows-right-left" class="size-5" />
            </span>
            <div>
              <h1 class="text-lg font-semibold tracking-tight">Export and import</h1>
              <p class="text-[13px] text-muted">
                Move everything MDT keeps for {@username} between installations, in one
                encrypted file.
              </p>
            </div>
          </header>

          <div class="flex flex-col gap-4">
            <.card
              id="export-card"
              icon="hero-arrow-down-tray"
              title="Export your data"
              notice={picker_notice(@picker_notice, "export")}
            >
              <%= if @exported do %>
                <.exported exported={@exported} />
              <% else %>
                <.export_form
                  form={@export_form}
                  included={@included}
                  pending={@exporting}
                  error={@export_error}
                />
              <% end %>
            </.card>

            <.card
              id="import-card"
              icon="hero-arrow-up-tray"
              title="Import a file"
              notice={picker_notice(@picker_notice, "import")}
            >
              <%= cond do %>
                <% @imported -> %>
                  <.imported imported={@imported} />
                <% @plan -> %>
                  <.plan
                    plan={@plan}
                    mode={@import_mode}
                    username={@username}
                    pending={@importing}
                    error={@import_error}
                  />
                <% true -> %>
                  <.import_form form={@import_form} pending={@reading} error={@import_error} />
              <% end %>
            </.card>
          </div>
        </div>
      </div>
    </Layouts.app>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PickTransferPath">
      export default {
        mounted() {
          this.el.addEventListener("click", async (event) => {
            event.preventDefault()
            await this.pick()
          })
        },

        async pick() {
          // Same IPC as the Git folder picker. Outside the desktop shell there
          // is nothing to call, and the path is typed instead.
          const dialog = window.__TAURI__?.dialog
          const invoke = window.__TAURI_INTERNALS__?.invoke || window.__TAURI__?.core?.invoke
          const target = this.el.dataset.target

          if (!dialog && !invoke) {
            return this.pushEvent("picker_unavailable", {
              target,
              reason: "The native file picker is only available in the desktop app. Type the path instead.",
            })
          }

          const exports = {name: "MDT export", extensions: ["mdtexport"]}
          const saving = this.el.dataset.mode === "save"
          const command = saving ? "save" : "open"
          const options = saving
            ? {title: "Save the export", defaultPath: this.el.dataset.defaultPath, filters: [exports]}
            : {
                title: "Choose a file to import",
                directory: false,
                multiple: false,
                filters: [exports, {name: "All files", extensions: ["*"]}],
              }

          try {
            const selection = dialog
              ? await dialog[command](options)
              : await invoke(`plugin:dialog|${command}`, {options})
            const first = Array.isArray(selection) ? selection[0] : selection
            const path = first && typeof first === "object" ? first.path : first

            if (path) this.pushEvent("select_path", {target, path})
          } catch (error) {
            this.pushEvent("picker_unavailable", {
              target,
              reason: `The file picker could not be opened: ${error?.message || error}`,
            })
          }
        }
      }
    </script>
    """
  end

  ## Components

  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :notice, :string, default: nil
  slot :inner_block, required: true

  defp card(assigns) do
    ~H"""
    <section id={@id} class="rounded-xl border border-line bg-panel">
      <div class="flex h-10 items-center gap-2 border-b border-line-soft px-4">
        <.icon name={@icon} class="size-4 text-accent" />
        <h2 class="text-[13px] font-semibold">{@title}</h2>
      </div>
      <div class="p-4">
        <p
          :if={@notice}
          id={"#{@id}-notice"}
          class="mb-3 flex items-start gap-1.5 text-[11px] leading-relaxed text-muted"
        >
          <.icon name="hero-information-circle" class="mt-px size-3.5 shrink-0" />
          {@notice}
        </p>
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :included, :list, required: true
  attr :pending, :boolean, required: true
  attr :error, :string, default: nil

  defp export_form(assigns) do
    ~H"""
    <.form
      for={@form}
      id="export-form"
      phx-change="change_export"
      phx-submit="export"
      class="flex flex-col gap-3"
    >
      <.path_field
        field={@form[:path]}
        label="Save to"
        mode="save"
        target="export"
        placeholder={"~/mdt-export#{Transfer.extension()}"}
      />

      <p class="flex items-start gap-1.5 text-[11px] leading-relaxed text-faint">
        <.icon name="hero-lock-closed" class="mt-px size-3.5 shrink-0" />
        <span>
          Encrypted with your sign in password. Importing it into this profile needs nothing
          more; anywhere else, it needs that password.
        </span>
      </p>

      <.error_line :if={@error} id="export-error" message={@error} />

      <div class="flex flex-wrap items-center gap-2 border-t border-line-soft pt-3">
        <span class="text-[11px] text-faint">Includes</span>
        <span
          :for={label <- @included}
          class="rounded border border-line-soft bg-deep px-1.5 py-0.5 text-[11px] text-muted"
        >
          {label}
        </span>
        <div class="flex-1"></div>
        <.button type="submit" id="export-submit" variant="primary" disabled={@pending}>
          <.icon :if={@pending} name="hero-arrow-path" class="size-4 motion-safe:animate-spin" />
          {if @pending, do: "Exporting…", else: "Export"}
        </.button>
      </div>
    </.form>
    """
  end

  attr :exported, :map, required: true

  defp exported(assigns) do
    ~H"""
    <div id="exported" class="flex items-start gap-3">
      <span class="flex size-8 shrink-0 items-center justify-center rounded-lg bg-ok-soft text-ok">
        <.icon name="hero-check" class="size-4" />
      </span>
      <div class="min-w-0 flex-1">
        <p class="text-[13px] font-medium">Export saved</p>
        <p class="truncate font-mono text-[11px] text-muted" title={@exported.path}>
          {@exported.path}
        </p>
        <p class="mt-0.5 text-[11px] text-faint">{Utils.format_bytes(@exported.size)}</p>
      </div>
      <.button type="button" id="export-again" phx-click="reset_export" variant="ghost">
        Export again
      </.button>
    </div>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :pending, :boolean, required: true
  attr :error, :string, default: nil

  defp import_form(assigns) do
    ~H"""
    <.form
      for={@form}
      id="import-form"
      phx-change="change_import"
      phx-submit="read"
      class="flex flex-col gap-3"
    >
      <.path_field
        field={@form[:path]}
        label="File"
        mode="open"
        target="import"
        placeholder={"~/mdt-export#{Transfer.extension()}"}
      />

      <div class="flex flex-col gap-2">
        <.input
          field={@form[:custom_password]}
          type="checkbox"
          label="Use a different password"
        />
        <%= if custom_password?(@form) do %>
          <.input
            field={@form[:password]}
            type="password"
            label="File password"
            autocomplete="off"
            phx-mounted={JS.focus()}
          />
          <p class="text-[11px] leading-relaxed text-faint">
            The sign in password the file was exported with, if it is not your current one.
          </p>
        <% else %>
          <p class="text-[11px] leading-relaxed text-faint">
            Opened with your sign in password. Use a different one for a file exported before a
            password change, or on another profile.
          </p>
        <% end %>
      </div>

      <.error_line :if={@error} id="import-error" message={@error} />

      <div class="flex items-center gap-2 border-t border-line-soft pt-3">
        <p class="text-[11px] text-faint">
          Nothing changes until you have seen what the file holds.
        </p>
        <div class="flex-1"></div>
        <.button type="submit" id="import-open" disabled={@pending}>
          <.icon :if={@pending} name="hero-arrow-path" class="size-4 motion-safe:animate-spin" />
          {if @pending, do: "Opening…", else: "Open file"}
        </.button>
      </div>
    </.form>
    """
  end

  attr :plan, MDTClient.Transfer.Plan, required: true
  attr :mode, :atom, required: true
  attr :username, :string, required: true
  attr :pending, :boolean, required: true
  attr :error, :string, default: nil

  defp plan(assigns) do
    ~H"""
    <div id="import-plan" class="flex flex-col gap-3">
      <div class="flex items-center gap-3 rounded-lg border border-line-soft bg-deep px-3 py-2.5">
        <.icon name="hero-document-check" class="size-5 shrink-0 text-accent" />
        <div class="min-w-0">
          <p class="text-[13px]">
            Exported {format_time(@plan.created_at)} by
            <span class="font-medium">{@plan.username}</span>
          </p>
          <p class="text-[11px] text-faint">
            MDT {@plan.app_version}<span :if={@plan.username != @username}> · its data goes into your profile, {@username}</span>
          </p>
        </div>
      </div>

      <ul class="flex flex-col divide-y divide-line-soft rounded-lg border border-line-soft">
        <li
          :for={section <- @plan.sections}
          id={"import-section-#{slug(section.key)}"}
          class="flex items-center gap-2 px-3 py-2"
        >
          <.icon name="hero-check-circle" class="size-4 shrink-0 text-ok" />
          <span class="text-[13px]">{section.label}</span>
          <span class="ml-auto text-xs text-muted">{section.summary}</span>
        </li>
        <li
          :for={key <- @plan.skipped}
          id={"import-skipped-#{slug(key)}"}
          class="flex items-center gap-2 px-3 py-2"
        >
          <.icon name="hero-minus-circle" class="size-4 shrink-0 text-faint" />
          <span class="font-mono text-xs text-muted">{key}</span>
          <span class="ml-auto text-xs text-faint">Unknown to this version, skipped</span>
        </li>
      </ul>

      <%= if @plan.sections == [] do %>
        <p id="import-plan-empty" class="text-xs text-muted">
          Nothing in this file can be imported by this version of MDT.
        </p>
      <% else %>
        <div
          id="import-mode"
          role="radiogroup"
          aria-label="How to import"
          class="grid gap-2 sm:grid-cols-2"
        >
          <.mode_option
            mode={:merge}
            current={@mode}
            icon="hero-arrows-pointing-in"
            title="Merge"
            description="Adds what is new to what you have. Nothing here is removed."
          />
          <.mode_option
            mode={:replace}
            current={@mode}
            icon="hero-arrow-path-rounded-square"
            title="Replace"
            description="Swaps each section above for the file's. What is there now goes."
          />
        </div>

        <div
          :if={@mode == :replace}
          id="import-replace-warning"
          class="flex items-start gap-2 rounded-md border border-warn/30 bg-warn-soft px-3 py-2"
        >
          <.icon name="hero-exclamation-triangle" class="mt-px size-4 shrink-0 text-warn" />
          <p class="text-xs leading-relaxed text-warn">
            Replacing discards what {@username} has for each section above, and cannot be undone.
          </p>
        </div>
      <% end %>

      <.error_line :if={@error} id="import-error" message={@error} />

      <div class="flex items-center justify-end gap-2">
        <.button
          type="button"
          id="import-cancel"
          phx-click="cancel_import"
          variant="ghost"
          disabled={@pending}
        >
          Cancel
        </.button>
        <.button
          type="button"
          id="import-confirm"
          phx-click="import"
          variant={if @mode == :replace, do: "danger", else: "primary"}
          disabled={@pending or @plan.sections == []}
        >
          <.icon :if={@pending} name="hero-arrow-path" class="size-4 motion-safe:animate-spin" />
          {confirm_label(@mode, @pending)}
        </.button>
      </div>
    </div>
    """
  end

  attr :mode, :atom, required: true
  attr :current, :atom, required: true
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, required: true

  defp mode_option(assigns) do
    ~H"""
    <button
      type="button"
      id={"import-mode-#{@mode}"}
      role="radio"
      aria-checked={to_string(@mode == @current)}
      phx-click="set_import_mode"
      phx-value-mode={@mode}
      class={[
        "flex cursor-pointer items-start gap-2.5 rounded-lg border px-3 py-2.5 text-left transition-colors",
        "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent",
        if(@mode == @current,
          do: "border-accent/60 bg-accent-soft/40",
          else: "border-line-soft hover:border-line hover:bg-hover"
        )
      ]}
    >
      <.icon
        name={@icon}
        class={["mt-px size-4 shrink-0", if(@mode == @current, do: "text-accent", else: "text-faint")]}
      />
      <span class="flex flex-col gap-0.5">
        <span class="text-[13px] font-medium">{@title}</span>
        <span class="text-[11px] leading-relaxed text-muted">{@description}</span>
      </span>
    </button>
    """
  end

  attr :imported, :map, required: true

  defp imported(assigns) do
    ~H"""
    <div id="imported" class="flex items-start gap-3">
      <span class="flex size-8 shrink-0 items-center justify-center rounded-lg bg-ok-soft text-ok">
        <.icon name="hero-check" class="size-4" />
      </span>
      <div class="min-w-0 flex-1">
        <p class="text-[13px] font-medium">
          {if @imported.mode == :replace, do: "Imported, replacing", else: "Imported and merged"}
        </p>
        <p :for={section <- @imported.sections} class="text-[11px] text-muted">
          {section.label} · {section.summary}
        </p>
      </div>
      <.button type="button" id="import-again" phx-click="reset_import" variant="ghost">
        Done
      </.button>
    </div>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :mode, :string, required: true, values: ~w(save open)
  attr :target, :string, required: true
  attr :placeholder, :string, default: nil

  defp path_field(assigns) do
    ~H"""
    <div>
      <label
        for={@field.id}
        class="mb-1 block text-[11px] font-medium uppercase tracking-wide text-muted"
      >
        {@label}
      </label>
      <div class="flex items-start gap-2">
        <div class="min-w-0 flex-1">
          <.input
            field={@field}
            type="text"
            placeholder={@placeholder}
            autocomplete="off"
            spellcheck="false"
            class={[input_classes(), "font-mono"]}
          />
        </div>
        <.button
          type="button"
          id={"#{@target}-browse"}
          phx-hook=".PickTransferPath"
          data-mode={@mode}
          data-target={@target}
          data-default-path={@field.value}
          class="shrink-0"
        >
          <.icon name="hero-folder-open" class="size-4" /> Browse
        </.button>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :message, :string, required: true

  defp error_line(assigns) do
    ~H"""
    <p id={@id} class="flex items-start gap-1.5 text-xs text-bad">
      <.icon name="hero-exclamation-circle" class="mt-px size-4 shrink-0" />
      {@message}
    </p>
    """
  end

  ## Events

  @impl true
  def handle_event("change_export", %{"export" => params}, socket) do
    {:noreply, assign(socket, :export_form, to_export_form(params))}
  end

  def handle_event("export", %{"export" => params}, %{assigns: %{exporting: false}} = socket) do
    case export_errors(params) do
      [] ->
        username = socket.assigns.username
        path = export_path(params["path"])

        {:noreply,
         socket
         |> assign(:exporting, true)
         |> assign(:export_error, nil)
         |> assign(:export_form, to_export_form(%{"path" => path}))
         |> start_async(:export, fn ->
           with :ok <- Transfer.export(username, path) do
             case File.stat(path) do
               {:ok, %File.Stat{size: size}} -> {:ok, %{path: path, size: size}}
               {:error, reason} -> {:error, {:file, reason}}
             end
           end
         end)}

      errors ->
        {:noreply, assign(socket, :export_form, to_export_form(params, errors))}
    end
  end

  def handle_event("export", _params, socket), do: {:noreply, socket}

  def handle_event("reset_export", _params, socket), do: {:noreply, reset_export(socket)}

  def handle_event("change_import", %{"import" => params}, socket) do
    {:noreply, assign(socket, :import_form, to_import_form(params))}
  end

  def handle_event("read", %{"import" => params}, %{assigns: %{reading: false}} = socket) do
    case import_errors(params) do
      [] ->
        username = socket.assigns.username
        path = Path.expand(params["path"])
        custom? = custom_password?(params)
        opts = if custom?, do: [password: params["password"]], else: []

        {:noreply,
         socket
         |> assign(:reading, true)
         |> assign(:import_error, nil)
         |> assign(:import_form, to_import_form(Map.put(params, "path", path)))
         |> start_async({:read, custom?}, fn -> Transfer.read(username, path, opts) end)}

      errors ->
        {:noreply, assign(socket, :import_form, to_import_form(params, errors))}
    end
  end

  def handle_event("read", _params, socket), do: {:noreply, socket}

  def handle_event("set_import_mode", %{"mode" => mode}, %{assigns: %{importing: false}} = socket) do
    {:noreply, assign(socket, :import_mode, import_mode(mode))}
  end

  def handle_event("set_import_mode", _params, socket), do: {:noreply, socket}

  def handle_event("import", _params, %{assigns: %{plan: plan, importing: false}} = socket)
      when not is_nil(plan) do
    username = socket.assigns.username
    mode = socket.assigns.import_mode

    {:noreply,
     socket
     |> assign(:importing, true)
     |> assign(:import_error, nil)
     |> start_async(:import, fn -> Transfer.import(username, plan, mode) end)}
  end

  def handle_event("import", _params, socket), do: {:noreply, socket}

  # A typed password was only needed to open the file; going back asks for it
  # again.
  def handle_event("cancel_import", _params, %{assigns: %{importing: false}} = socket) do
    params = Map.take(socket.assigns.import_form.params, ["path", "custom_password"])
    {:noreply, socket |> reset_import() |> assign(:import_form, to_import_form(params))}
  end

  def handle_event("cancel_import", _params, socket), do: {:noreply, socket}

  def handle_event("reset_import", _params, socket), do: {:noreply, reset_import(socket)}

  def handle_event("select_path", %{"target" => "export", "path" => path}, socket) do
    params = Map.put(socket.assigns.export_form.params, "path", export_path(path))

    {:noreply,
     socket |> assign(:export_form, to_export_form(params)) |> assign(:picker_notice, nil)}
  end

  def handle_event("select_path", %{"target" => "import", "path" => path}, socket) do
    params = Map.put(socket.assigns.import_form.params, "path", path)

    {:noreply,
     socket |> assign(:import_form, to_import_form(params)) |> assign(:picker_notice, nil)}
  end

  def handle_event("picker_unavailable", %{"target" => target, "reason" => reason}, socket) do
    {:noreply, assign(socket, :picker_notice, {target, reason})}
  end

  ## Async results

  @impl true
  def handle_async(:export, {:ok, {:ok, exported}}, socket) do
    {:noreply,
     socket
     |> assign(:exporting, false)
     |> assign(:exported, exported)
     |> assign(:export_form, to_export_form(%{"path" => exported.path}))}
  end

  def handle_async(:export, {:ok, {:error, reason}}, socket) do
    {:noreply, socket |> assign(:exporting, false) |> assign(:export_error, message(reason))}
  end

  def handle_async(:export, {:exit, _reason}, socket) do
    {:noreply, socket |> assign(:exporting, false) |> assign(:export_error, crashed("exporting"))}
  end

  def handle_async({:read, _custom?}, {:ok, {:ok, plan}}, socket) do
    {:noreply, socket |> assign(:reading, false) |> assign(:plan, plan)}
  end

  # The sign in password did not open it, so it was exported under another
  # one: ask for that instead.
  def handle_async({:read, false}, {:ok, {:error, :bad_password}}, socket) do
    params = Map.put(socket.assigns.import_form.params, "custom_password", "true")

    {:noreply,
     socket
     |> assign(:reading, false)
     |> assign(:import_form, to_import_form(params))
     |> assign(
       :import_error,
       "This file was not exported with your current sign in password. Enter the password it was made with."
     )}
  end

  def handle_async({:read, _custom?}, {:ok, {:error, reason}}, socket) do
    {:noreply, socket |> assign(:reading, false) |> assign(:import_error, message(reason))}
  end

  def handle_async({:read, _custom?}, {:exit, _reason}, socket) do
    {:noreply, socket |> assign(:reading, false) |> assign(:import_error, crashed("opening"))}
  end

  def handle_async(:import, {:ok, :ok}, socket) do
    imported = %{
      mode: socket.assigns.import_mode,
      sections: Enum.map(socket.assigns.plan.sections, &Map.take(&1, [:label, :summary]))
    }

    {:noreply,
     socket
     |> reset_import()
     |> assign(:imported, imported)
     |> put_flash(:info, "Import complete")}
  end

  def handle_async(:import, {:ok, {:error, reason}}, socket) do
    {:noreply, socket |> assign(:importing, false) |> assign(:import_error, message(reason))}
  end

  def handle_async(:import, {:exit, _reason}, socket) do
    {:noreply, socket |> assign(:importing, false) |> assign(:import_error, crashed("importing"))}
  end

  ## Helpers

  defp reset_export(socket) do
    # The server runs on the user's machine, so its local date is theirs.
    today = NaiveDateTime.to_date(NaiveDateTime.local_now())
    default = Path.join(System.user_home!(), Transfer.filename(socket.assigns.username, today))

    socket
    |> assign(:export_form, to_export_form(%{"path" => default}))
    |> assign(:export_error, nil)
    |> assign(:exporting, false)
    |> assign(:exported, nil)
  end

  # The decrypted plan goes with the password that opened it. Merging is the
  # default since it cannot lose anything.
  defp reset_import(socket) do
    socket
    |> assign(:import_form, to_import_form(%{}))
    |> assign(:import_error, nil)
    |> assign(:import_mode, :merge)
    |> assign(:reading, false)
    |> assign(:importing, false)
    |> assign(:plan, nil)
    |> assign(:imported, nil)
  end

  defp to_export_form(params, errors \\ []), do: to_form(params, as: :export, errors: errors)
  defp to_import_form(params, errors \\ []), do: to_form(params, as: :import, errors: errors)

  defp export_errors(params) do
    if blank?(params["path"]), do: [path: {"Choose where to save the export", []}], else: []
  end

  defp import_errors(params) do
    [
      blank?(params["path"]) && {:path, {"Choose the file to import", []}},
      (custom_password?(params) and blank?(params["password"])) &&
        {:password, {"Enter the password the file was exported with", []}}
    ]
    |> Enum.filter(& &1)
  end

  defp custom_password?(%Phoenix.HTML.Form{} = form), do: custom_password?(form.params)

  defp custom_password?(params),
    do: Phoenix.HTML.Form.normalize_value("checkbox", params["custom_password"])

  defp import_mode("replace"), do: :replace
  defp import_mode(_merge), do: :merge

  defp confirm_label(_mode, true), do: "Importing…"
  defp confirm_label(:merge, false), do: "Import and merge"
  defp confirm_label(:replace, false), do: "Replace my data"

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""

  # Native save dialogs do not add the extension a filter names, and a file
  # without it is hidden from the open dialog's default filter.
  defp export_path(path) do
    path = Path.expand(path)
    if Path.extname(path) == "", do: path <> Transfer.extension(), else: path
  end

  defp picker_notice({target, reason}, target), do: reason
  defp picker_notice(_notice, _target), do: nil

  defp message({:file, reason}) do
    reason |> :file.format_error() |> to_string() |> String.capitalize() |> Kernel.<>(".")
  end

  defp message(:blank_password), do: "Enter the file's password."
  defp message(:bad_password), do: "That password does not open this file."
  defp message(:not_an_export), do: "This file is not an MDT export."
  defp message(:damaged), do: "This file is damaged and cannot be read."

  defp message(:unsupported_version),
    do: "This file was exported by a newer version of MDT. Update MDT to import it."

  defp message({:newer_section, label}),
    do: "The #{label} in this file comes from a newer version of MDT. Update MDT to import it."

  defp message({:invalid_section, _label, reason}) when is_binary(reason), do: reason
  defp message({:invalid_section, label, _reason}), do: "The #{label} in this file is damaged."

  defp message({:export_failed, label, _reason}),
    do: "The #{label} could not be read, so nothing was exported."

  defp message({:import_failed, label, _reason}),
    do: "The #{label} could not be imported. Anything already imported was put back as it was."

  # The task logs its own crash; the reason is no use to someone reading this.
  defp crashed(action), do: "Something went wrong #{action} the file."

  defp format_time(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")

  defp slug(key), do: String.replace(key, ~r/[^A-Za-z0-9_-]/, "-")
end
