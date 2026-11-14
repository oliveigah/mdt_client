defmodule MDTClientWeb.SandboxLive.Settings do
  @moduledoc """
  The settings page, in four tabs:

    * **General** - the folders the VM sees, its size, how long a request
      waits for you, and desktop notifications;
    * **Image** - its name, your Containerfile, MDT's layer, the build and
      the builds kept;
    * **Memory & storage** - the VM's memory and its round trip with yours,
      and the folders it keeps (Home, Cache, its memory);
    * **Host & network** - this machine as agents see it, and what the
      network always refuses.
  """
  use MDTClientWeb, :html

  import MDTClientWeb.SandboxLive.Components

  alias MDTClient.Sandbox
  alias MDTClient.Sandbox.Image

  @tabs [
    {"general", "General", "hero-adjustments-horizontal-micro"},
    {"image", "Image", "hero-cube-micro"},
    {"storage", "Memory & storage", "hero-circle-stack-micro"},
    {"host", "Host & network", "hero-computer-desktop-micro"}
  ]

  @tab_ids Enum.map(@tabs, &elem(&1, 0))

  @doc "The tab a `tab` query parameter names, General if none or unknown."
  @spec tab(String.t() | nil) :: String.t()
  def tab(id) when id in @tab_ids, do: id
  def tab(_id), do: "general"

  attr :tab, :string, default: "general"
  attr :vm, :any, required: true
  attr :image, :map, required: true
  attr :builds, :list, required: true
  attr :created_ref, :string, default: nil
  attr :snapshots, :list, required: true
  attr :memory, :map, required: true
  attr :folders, :map, required: true
  attr :name_form, :any, required: true
  attr :name_error, :string, default: nil
  attr :tools, :map, required: true
  attr :inbox, :string, required: true
  attr :settings, :any, required: true
  attr :containerfile_form, :any, required: true
  attr :containerfile_error, :string, default: nil
  attr :vm_form, :any, required: true
  attr :vm_errors, :map, required: true
  attr :share_form, :any, required: true
  attr :share_error, :string, default: nil
  attr :host, :map, required: true
  attr :host_form, :any, required: true
  attr :host_error, :string, default: nil

  attr :desktop, :any,
    default: nil,
    doc: "`MDTClient.Desktop.Notifications.status/0`, nil until known"

  def page(assigns) do
    assigns = assign(assigns, :tabs, @tabs)

    ~H"""
    <.page_header id="settings-header" title="Settings">
      <:help>
        How the VM is built. Microsandbox can't change mounts or resources on a VM that exists, so most changes here apply when it is recreated.
      </:help>
    </.page_header>

    <div
      :if={@vm.stale?}
      id="settings-stale"
      class="mb-4 flex flex-wrap items-center gap-3 rounded-xl border border-warn/35 bg-warn-soft/30 px-4 py-2.5"
    >
      <.icon name="hero-arrow-path" class="size-4 text-warn" />
      <p class="flex flex-1 items-center gap-1.5 text-xs text-ink">
        The VM still runs with the previous settings or image.
        <.help id="settings-stale-help" label="About recreating">
          Recreating starts a fresh root filesystem from the current image; you choose what happens to its Home and Cache.
        </.help>
      </p>
      <.button
        id="settings-recreate"
        phx-click="recreate_vm"
        disabled={not is_nil(@vm.busy) or not @image.loaded?}
      >
        Recreate now
      </.button>
    </div>

    <nav
      id="settings-tabs"
      aria-label="Settings sections"
      class="mb-5 flex flex-wrap items-center gap-1 border-b border-line-soft"
    >
      <.link
        :for={{id, label, icon} <- @tabs}
        id={"settings-tab-#{id}"}
        patch={tab_path(id)}
        aria-current={@tab == id && "page"}
        class={[
          "-mb-px flex items-center gap-1.5 border-b-2 px-3 py-2 text-[13px] transition-colors",
          if(@tab == id,
            do: "border-accent font-medium text-ink",
            else: "border-transparent text-muted hover:border-line hover:text-ink"
          )
        ]}
      >
        <.icon
          name={icon}
          class={["size-3.5", if(@tab == id, do: "text-accent", else: "text-faint")]}
        />
        {label}
        <span
          :if={id == "image" and not @image.loaded?}
          class="size-1.5 rounded-full bg-accent"
          title="Not built yet"
        ></span>
      </.link>
    </nav>

    <%= case @tab do %>
      <% "general" -> %>
        <.general {assigns} />
      <% "image" -> %>
        <.image_tab {assigns} />
      <% "storage" -> %>
        <.storage {assigns} />
      <% "host" -> %>
        <.host_tab {assigns} />
    <% end %>
    """
  end

  defp tab_path("general"), do: ~p"/tools/sandbox/settings"
  defp tab_path(id), do: ~p"/tools/sandbox/settings?tab=#{id}"

  ## General

  defp general(assigns) do
    assigns = assign(assigns, :pick_from, pick_from(assigns.settings.shares))

    ~H"""
    <div class="space-y-5">
      <.card id="settings-shares" title="Shared folders" body_class="">
        <:help>
          Each folder appears at the same path in the VM, read-only unless you say otherwise. What the VM writes in a read-write folder can run on your machine when you use that folder: a git hook, a build script, an editor task. The VM's own work belongs on its Work disk (/work), which nothing here opens. Every git repository in a shared folder is a project: the Projects page opens it in the VM, with a mirror in /work, and only from a read-only folder. Never shared: your home folder itself, ~/.ssh, ~/.gnupg, ~/.optmem, cloud CLI logins and MDT's own data. Folders can't sit inside one another, since the VM could unmount the inner one.
        </:help>
        <:actions>
          <span class="text-[11px] text-faint">{length(@settings.shares)} shared</span>
        </:actions>
        <ul id="shares" class="divide-y divide-line-soft">
          <li :if={@settings.shares == []}>
            <.empty icon="hero-folder">
              The VM sees no folder of yours yet. Share project folders, one by one.
            </.empty>
          </li>
          <li
            :for={{share, index} <- Enum.with_index(@settings.shares)}
            id={"share-#{index}"}
            class="group/share flex items-center gap-3 px-4 py-2.5 transition-colors hover:bg-hover/30"
          >
            <.icon
              name={if share.mode == :rw, do: "hero-folder-open", else: "hero-lock-closed"}
              class={[
                "size-4 shrink-0",
                if(share.mode == :rw, do: "text-accent", else: "text-faint")
              ]}
            />
            <div class="min-w-0 flex-1">
              <p class="truncate text-xs font-medium text-ink">{Path.basename(share.path)}</p>
              <p class="truncate font-mono text-[10px] text-faint" title={share.path}>
                {share.path}
              </p>
            </div>
            <.segmented
              id={"share-mode-#{index}"}
              options={[{:ro, "Read-only"}, {:rw, "Read-write"}]}
              value={share.mode}
              event="set_share_mode"
              name="mode"
              values={%{"path" => share.path}}
              confirm={%{"rw" => read_write_warning()}}
            />
            <button
              type="button"
              id={"share-remove-#{index}"}
              phx-click="remove_share"
              phx-value-path={share.path}
              title="Stop sharing"
              class="flex size-7 cursor-pointer items-center justify-center rounded text-faint transition-colors hover:bg-bad-soft/40 hover:text-bad"
            >
              <.icon name="hero-x-mark" class="size-3.5" />
            </button>
          </li>
        </ul>
        <.form
          for={@share_form}
          id="share-form"
          phx-submit="add_share"
          phx-change="share_changed"
          class="border-t border-line-soft bg-deep/30 px-4 py-3"
        >
          <div class="flex flex-wrap items-center gap-2">
            <button
              type="button"
              id="share-pick"
              phx-hook=".PickFolders"
              data-default-path={@pick_from}
              data-read-write-warning={read_write_warning()}
              class="inline-flex cursor-pointer items-center gap-1.5 rounded-md bg-accent px-3 py-1.5 text-[13px] font-semibold leading-none text-deep transition-all hover:brightness-110 active:scale-[0.98] active:brightness-95 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent"
            >
              <.icon name="hero-folder-plus-micro" class="size-3.5" /> Choose folders…
            </button>
            <span class="text-[11px] text-faint">or</span>
            <div class="min-w-48 flex-1">
              <input
                type="text"
                name={@share_form[:path].name}
                id="share-path"
                value={@share_form[:path].value}
                placeholder="type a path: ~/projects/some-repo"
                autocomplete="off"
                spellcheck="false"
                class={[input_classes(), "font-mono text-xs", @share_error && "border-bad/70"]}
              />
            </div>
            <select
              name={@share_form[:mode].name}
              id="share-mode"
              title="How new folders are shared"
              class="rounded-md border border-line bg-deep px-2 py-1.5 text-xs text-ink outline-none focus:border-accent/60"
            >
              <option value="ro" selected={@share_form[:mode].value != "rw"}>Read-only</option>
              <option value="rw" selected={@share_form[:mode].value == "rw"}>Read-write</option>
            </select>
            <.button
              type="submit"
              id="share-add"
              data-confirm={@share_form[:mode].value == "rw" && read_write_warning()}
            >
              <.icon name="hero-plus-micro" class="size-3.5" /> Share
            </.button>
          </div>
          <p
            :if={@share_error}
            id="share-error"
            class="mt-2 flex items-start gap-1.5 text-[11px] leading-4 text-bad"
          >
            <.icon name="hero-exclamation-circle-micro" class="mt-px size-3.5 shrink-0" />
            {@share_error}
          </p>
        </.form>
      </.card>

      <.card id="settings-vm" title="Size and timing">
        <:help>
          <span class="block">
            The root disk holds what the image and the VM write outside its own disks (apt packages, /tmp, /var), and starts empty when the VM is recreated. Home, Cache and Work are the disks the VM keeps. Every disk takes space on this machine only as it fills. A bigger Home, Cache or Work applies at the next start, and none is ever made smaller. Folder writes is how much the VM may add to each read-write folder (its memory, your shares) per boot, so a runaway agent can't fill your disk. The root disk and folder writes need the VM recreated.
          </span>
          <span class="mt-1.5 block">
            Hold is how long a request waits for your decision before it gives up; the image sets HEX_HTTP_TIMEOUT above it, since Hex otherwise gives up after 15 seconds.
          </span>
        </:help>
        <.form for={@vm_form} id="vm-form" phx-submit="save_settings" class="space-y-4">
          <div class="grid grid-cols-2 gap-4 sm:grid-cols-3">
            <.number_field
              field={@vm_form[:cpus]}
              label="CPUs"
              min="1"
              max="64"
              error={@vm_errors[:cpus]}
            />
            <.number_field
              field={@vm_form[:memory_gib]}
              label="Memory, GiB"
              min="1"
              max="512"
              error={@vm_errors[:memory_gib]}
            />
            <.number_field
              field={@vm_form[:disk_gib]}
              label="Root disk, GiB"
              min="4"
              max="4096"
              error={@vm_errors[:disk_gib]}
            />
            <.number_field
              field={@vm_form[:write_budget_gib]}
              label="Folder writes, GiB"
              min="1"
              max="4096"
              error={@vm_errors[:write_budget_gib]}
            />
            <.number_field
              field={@vm_form[:hold_seconds]}
              label="Hold, s"
              min="30"
              max="600"
              error={@vm_errors[:hold_seconds]}
            />
            <.number_field
              field={@vm_form[:home_gib]}
              label="Home disk, GiB"
              min="1"
              max="4096"
              error={@vm_errors[:home_gib]}
            />
            <.number_field
              field={@vm_form[:cache_gib]}
              label="Cache disk, GiB"
              min="1"
              max="4096"
              error={@vm_errors[:cache_gib]}
            />
            <.number_field
              field={@vm_form[:work_gib]}
              label="Work disk, GiB"
              min="1"
              max="4096"
              error={@vm_errors[:work_gib]}
            />
          </div>
          <div class="flex items-center gap-2 border-t border-line-soft pt-3">
            <span class="flex min-w-0 flex-1 items-center gap-1 truncate text-[11px] text-muted">
              <%= if @tools.msb do %>
                <.icon name="hero-check-circle-micro" class="size-3.5 shrink-0 text-ok" />
                <span class="truncate font-mono" title={@tools.msb}>MDT's msb ready</span>
              <% else %>
                <.icon name="hero-exclamation-triangle-micro" class="size-3.5 shrink-0 text-warn" />
                MDT's microsandbox runtime is missing
              <% end %>
            </span>
            <.button type="submit" id="vm-save" variant="primary">Save</.button>
          </div>
        </.form>
      </.card>

      <.notifications_card settings={@settings} desktop={@desktop} />
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PickFolders">
      export default {
        mounted() {
          this.el.addEventListener("click", async (event) => {
            event.preventDefault()
            await this.pick()
          })
        },

        async pick() {
          // The desktop shell exposes the native picker through the Tauri IPC.
          // In a plain browser there is nothing to call, so the path is typed.
          const dialog = window.__TAURI__?.dialog
          const invoke = window.__TAURI_INTERNALS__?.invoke || window.__TAURI__?.core?.invoke
          const mode = () => document.getElementById("share-mode")?.value || "ro"

          if (!dialog && !invoke) {
            document.getElementById("share-path")?.focus()
            return this.pushEvent("folder_picker_unavailable", {
              reason: "The folder picker only opens in the desktop app.",
            })
          }

          const options = {
            directory: true,
            multiple: true,
            recursive: false,
            title: "Share folders with the VM",
            defaultPath: this.el.dataset.defaultPath || undefined,
          }

          try {
            const selection = dialog
              ? await dialog.open(options)
              : await invoke("plugin:dialog|open", {options})
            const picked = selection == null ? [] : Array.isArray(selection) ? selection : [selection]
            const paths = picked
              .map((item) => (item && typeof item === "object" ? item.path : item))
              .filter(Boolean)

            if (!paths.length) return
            // Read-write is asked about first, like the other ways to choose it.
            if (mode() === "rw" && !window.confirm(this.el.dataset.readWriteWarning)) return
            this.pushEvent("add_shares", {paths, mode: mode()})
          } catch (error) {
            this.pushEvent("folder_picker_unavailable", {
              reason: `The folder picker could not be opened: ${error?.message || error}.`,
            })
          }
        },
      }
    </script>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :error, :string, default: nil
  attr :rest, :global, include: ~w(min max)

  defp number_field(assigns) do
    ~H"""
    <div>
      <.input field={@field} type="number" label={@label} {@rest} />
      <p :if={@error} class="mt-1 text-[11px] text-bad">{@error}</p>
    </div>
    """
  end

  # The picker opens where the latest shared folder sits, or in your home.
  # Asked before a folder is shared read-write, however that is chosen.
  defp read_write_warning do
    "What the VM writes in a read-write folder can run on your machine when you use that " <>
      "folder: a git hook, a build script, an editor task. Share it read-write anyway?"
  end

  defp pick_from([]), do: System.user_home() || ""
  defp pick_from(shares), do: shares |> List.last() |> Map.fetch!(:path) |> Path.dirname()

  ## Image

  defp image_tab(assigns) do
    current = Enum.find(assigns.builds, &(&1.ref == assigns.image.tag))

    assigns =
      assign(assigns,
        mdt_layer: Image.mdt_layer(),
        current: current,
        different_default?: assigns.settings.containerfile != Image.default_containerfile(),
        edited?: current != nil and current.containerfile != assigns.settings.containerfile
      )

    ~H"""
    <.card id="settings-image" title="The VM's image" class="mb-5" body_class="">
      <:help>
        Your Containerfile, then MDT's layer, built with podman on this machine and handed to microsandbox. MDT's default comes with Bash, completion, language runtimes and development CLIs already installed. The build runs here, in a rootless podman container, which isolates less than the VM: install scripts in your Containerfile run there.
      </:help>
      <:actions>
        <span
          id="image-state"
          class={[
            "rounded-full border px-2 py-0.5 text-[10px] font-medium",
            cond do
              @image.building? -> "border-warn/40 bg-warn-soft/40 text-warn-strong"
              @image.loaded? -> "border-ok/30 bg-ok-soft/40 text-ok-strong"
              true -> "border-line text-muted"
            end
          ]}
        >
          <%= cond do %>
            <% @image.building? -> %>
              Building…
            <% @image.loaded? -> %>
              Built
            <% true -> %>
              Not built
          <% end %>
        </span>
        <.button
          id="image-build"
          variant={if(@image.loaded?, do: "secondary", else: "primary")}
          phx-click="build_image"
          disabled={@image.building? or not @tools.podman}
        >
          <.icon name="hero-wrench-screwdriver-micro" class="size-3.5" />
          {if @image.loaded?, do: "Rebuild", else: "Build"}
        </.button>
      </:actions>

      <div
        id="image-setup-guide"
        class="flex flex-wrap items-center gap-x-4 gap-y-2 border-b border-line-soft px-4 py-2.5"
      >
        <p class="flex-1 text-[11px] leading-5 text-muted">
          Save the recipe, build it, then recreate the VM to use it.
        </p>
        <.form
          for={@name_form}
          id="image-name-form"
          phx-submit="save_image_name"
          class="flex items-center gap-2"
        >
          <label for="image-name" class="text-[11px] font-medium text-muted">Name</label>
          <input
            type="text"
            id="image-name"
            name={@name_form[:name].name}
            value={@name_form[:name].value}
            spellcheck="false"
            autocomplete="off"
            class={[
              "w-52 rounded-md border bg-deep px-2 py-1 font-mono text-xs text-ink outline-none focus:border-accent/60",
              if(@name_error, do: "border-bad/70", else: "border-line")
            ]}
          />
          <.help id="image-name-help" label="About the image name">
            Each build is tagged with its date and number, like
            <span class="font-mono">{@settings.image_name}:{Date.to_iso8601(Date.utc_today())}.1</span>
          </.help>
          <.button type="submit" id="image-name-save">Save</.button>
        </.form>
        <p :if={@name_error} id="image-name-error" class="w-full text-right text-[11px] text-bad">
          {@name_error}
        </p>
      </div>

      <p
        :if={@different_default?}
        id="containerfile-default-differs"
        class="flex items-center gap-2 border-b border-line-soft bg-accent-soft/20 px-4 py-2 text-[11px] text-ink"
      >
        <.icon name="hero-information-circle-micro" class="size-3.5 shrink-0 text-accent" />
        <span class="flex-1">
          Your recipe differs from MDT's current default. To adopt it, choose "Start from MDT's default", review, save and build.
        </span>
      </p>

      <p
        :if={@edited?}
        id="containerfile-edited"
        class="flex items-center gap-2 border-b border-warn/30 bg-warn-soft/25 px-4 py-2 text-[11px] text-ink"
      >
        <.icon name="hero-pencil-square-micro" class="size-3.5 text-warn" />
        The Containerfile changed since the current build. Build to use it.
      </p>

      <p
        :if={not @tools.podman}
        class="flex items-center gap-2 border-b border-bad/30 bg-bad-soft/20 px-4 py-2 text-[11px] text-bad"
      >
        <.icon name="hero-x-circle-micro" class="size-3.5 shrink-0" />
        podman is not installed, so the image can't be built.
      </p>

      <div class="grid gap-0 lg:grid-cols-[minmax(0,1.2fr)_minmax(0,1fr)]">
        <.form
          for={@containerfile_form}
          id="containerfile-form"
          phx-submit="save_containerfile"
          class="flex min-w-0 flex-col border-line-soft lg:border-r"
        >
          <div class="flex items-center gap-2 border-b border-line-soft px-4 py-2">
            <p class="flex-1 text-[10px] font-semibold uppercase tracking-wide text-muted">
              Containerfile
            </p>
            <button
              type="button"
              id="containerfile-reset"
              phx-click="reset_containerfile"
              class="cursor-pointer rounded px-1.5 py-0.5 text-[10px] text-faint transition-colors hover:bg-hover hover:text-ink"
            >
              Start from MDT's default
            </button>
          </div>
          <textarea
            name={@containerfile_form[:containerfile].name}
            id="containerfile"
            spellcheck="false"
            rows="18"
            class="min-h-80 w-full flex-1 resize-y border-0 bg-deep px-4 py-3 font-mono text-[11px] leading-5 text-ink outline-none focus:ring-2 focus:ring-inset focus:ring-accent/25"
          >{@containerfile_form[:containerfile].value}</textarea>
          <div class="flex items-center gap-2 border-t border-line-soft px-4 py-2">
            <p :if={@containerfile_error} id="containerfile-error" class="flex-1 text-[11px] text-bad">
              {@containerfile_error}
            </p>
            <p
              :if={is_nil(@containerfile_error)}
              class="flex-1 truncate font-mono text-[10px] text-faint"
              title={@image.tag}
            >
              {@image.tag || "not built yet"}
            </p>
            <.button type="submit" id="containerfile-save">Save</.button>
          </div>
        </.form>

        <div class="flex min-w-0 flex-col">
          <%= if @image.building? or @image.log != [] or @image.error do %>
            <div class="flex items-center gap-2 border-b border-line-soft px-4 py-2">
              <p class="flex-1 text-[10px] font-semibold uppercase tracking-wide text-muted">
                Build log
              </p>
              <.icon
                :if={@image.building?}
                name="hero-arrow-path-micro"
                class="size-3.5 animate-spin text-warn"
              />
            </div>
            <p
              :if={@image.error}
              id="image-error"
              class="border-b border-bad/30 bg-bad-soft/20 px-4 py-2 text-[11px] text-bad"
            >
              {@image.error}
            </p>
            <pre
              id="build-log"
              class="max-h-96 min-h-48 flex-1 overflow-auto bg-deep/60 px-4 py-3 font-mono text-[10px] leading-4 text-muted"
              phx-no-curly-interpolation
            ><%= @image.log |> Enum.take(160) |> Enum.reverse() |> Enum.join("\n") %></pre>
          <% else %>
            <div class="flex items-center gap-2 border-b border-line-soft px-4 py-2">
              <p class="flex flex-1 items-center gap-1.5 text-[10px] font-semibold uppercase tracking-wide text-muted">
                MDT adds this layer
                <.help id="mdt-layer-help" label="About MDT's layer">
                  It points at /mnt/mdt and /cache. The image holds nothing of this identity's; CA, grant and helper updates arrive without rebuilding it.
                </.help>
              </p>
            </div>
            <pre
              id="mdt-layer"
              class="max-h-96 flex-1 overflow-auto bg-deep/40 px-4 py-3 font-mono text-[10px] leading-4 text-faint"
              phx-no-curly-interpolation
            ><%= String.trim(@mdt_layer) %></pre>
          <% end %>
        </div>
      </div>
    </.card>

    <.card id="settings-builds" title="Builds kept" body_class="">
      <:help>
        The current one and the two before it. Going back means using a build, not the recipe: rebuilding the same Containerfile later gives other versions.
      </:help>
      <ul class="divide-y divide-line-soft">
        <li :if={@builds == []} id="builds-empty">
          <.empty icon="hero-archive-box">No build yet. Build the image above.</.empty>
        </li>
        <li
          :for={build <- @builds}
          id={"build-" <> String.replace(build.tag, ".", "-")}
          class="px-4 py-2.5"
        >
          <div class="flex flex-wrap items-center gap-3">
            <.icon
              name="hero-archive-box"
              class={[
                "size-4 shrink-0",
                if(build.ref == @image.tag, do: "text-accent", else: "text-faint")
              ]}
            />
            <span class="font-mono text-xs text-ink">{build.tag}</span>
            <span
              :if={build.ref == @image.tag}
              class="rounded-full border border-accent/30 bg-accent/10 px-1.5 py-px text-[9px] font-semibold uppercase tracking-wide text-accent"
            >
              current
            </span>
            <span
              :if={build.ref == @created_ref and @vm.exists?}
              class="rounded-full border border-ok/30 bg-ok-soft/40 px-1.5 py-px text-[9px] font-semibold uppercase tracking-wide text-ok-strong"
            >
              the VM runs it
            </span>
            <span class="text-[11px] text-muted">
              {Calendar.strftime(build.built_at, "%b %-d, %H:%M")} UTC
            </span>
            <span :if={build.size} class="text-[11px] text-faint">{gigabytes(build.size)}</span>
            <span class="flex-1"></span>
            <.button
              :if={build.ref != @image.tag}
              id={"build-use-" <> String.replace(build.tag, ".", "-")}
              phx-click="use_build"
              phx-value-ref={build.ref}
              disabled={@image.building?}
            >
              Make current
            </.button>
          </div>
          <details :if={build.versions != ""} class="group mt-1.5 pl-7">
            <summary class="cursor-pointer list-none text-[10px] text-faint transition-colors hover:text-ink [&::-webkit-details-marker]:hidden">
              <.icon
                name="hero-chevron-right-micro"
                class="size-3 transition-transform group-open:rotate-90"
              /> What's in it
            </summary>
            <pre
              class="mt-1.5 max-h-56 overflow-auto rounded-md bg-deep/60 px-3 py-2 font-mono text-[10px] leading-4 text-muted"
              phx-no-curly-interpolation
            ><%= String.trim(build.versions) %></pre>
          </details>
        </li>
      </ul>
    </.card>
    """
  end

  ## Memory & storage

  defp storage(assigns) do
    ~H"""
    <div class="grid items-start gap-5 lg:grid-cols-2">
      <.card id="settings-vm-memory" title="The VM's memory">
        <:help>
          The VM has its own OptMem. It can start from a copy of yours, and what it learns comes back only through your review. Copying replaces what the VM remembers (moved aside, not deleted) with every memory you have, work ones included, and only while the VM is stopped.
        </:help>
        <%= if @memory.host? do %>
          <p id="vm-memory-state" class="text-xs leading-5 text-ink">
            <%= if @memory.seeded_at do %>
              Started from a copy of yours ({@memory.seed_count} memories) on {Calendar.strftime(
                @memory.seeded_at,
                "%b %-d, %H:%M"
              )} UTC.
            <% else %>
              Its own, never copied from yours.
            <% end %>
          </p>
          <div class="mt-3 flex flex-wrap gap-2">
            <.button id="vm-memory-review" variant="primary" phx-click="review_memories">
              <.icon name="hero-inbox-arrow-down-micro" class="size-3.5" /> Review what it noted
            </.button>
            <.button
              id="vm-memory-seed"
              phx-click="seed_memory"
              disabled={@vm.status in [:running, :starting] or not is_nil(@vm.busy)}
              title={
                if(@vm.status in [:running, :starting],
                  do: "Stop the VM first",
                  else: "Replace the VM's memory with a copy of yours"
                )
              }
            >
              <.icon name="hero-document-duplicate-micro" class="size-3.5" /> Copy mine in
            </.button>
          </div>
        <% else %>
          <p class="text-xs leading-5 text-muted">
            OptMem isn't installed on this machine (~/.optmem/memo), so the VM's memory can't be set up or compared with yours.
          </p>
        <% end %>
      </.card>

      <.card id="settings-folders" title="What the VM keeps">
        <:help>
          The VM's own disks, and two folders of MDT's. The disks survive recreating the VM. They are files on this machine that only the VM opens: nothing here reads what is inside, so nothing in them can run here. Whatever in Home runs code in the VM (agent hooks, MCP servers, shell files) survives a recreate unless you start it empty.
        </:help>
        <dl class="space-y-2.5 text-xs">
          <.kept
            label="Home"
            path={@folders.home}
            guest="/root"
            text="Logins, shell history, Zed's server, agent settings."
          />
          <.kept
            label="Cache"
            path={@folders.cache}
            guest="/cache"
            text="Tool versions installed in the VM and package caches."
          />
          <.kept
            label="Work"
            path={@folders.work}
            guest="/work"
            text="Your projects and everything built in them. Recreating never empties it."
          />
          <.kept
            label="The VM's memory"
            path={@folders.optmem}
            guest="/root/.optmem"
            text="Its own OptMem. Emptying Home leaves it alone."
          />
          <.kept
            label="From MDT, read-only"
            path={@inbox}
            guest="/mnt/mdt"
            text="CA bundle, placeholders, the agents' instructions, grants as they are now."
          />
        </dl>
        <div class="mt-3 border-t border-line-soft pt-3">
          <p class="text-[11px] font-medium text-muted">Copies of Home</p>
          <p :if={@snapshots == []} id="snapshots-empty" class="mt-1 text-[11px] text-faint">
            None yet. One is taken before each recreate, three at most.
          </p>
          <ul :if={@snapshots != []} id="snapshots" class="mt-1.5 space-y-1">
            <li
              :for={snapshot <- @snapshots}
              id={"snapshot-#{snapshot.id}"}
              class="flex items-center gap-2 text-[11px]"
            >
              <.icon name="hero-camera-micro" class="size-3.5 text-faint" />
              <span class="text-ink">
                {Calendar.strftime(snapshot.taken_at, "%b %-d, %H:%M")} UTC
              </span>
              <span :if={snapshot.tag} class="font-mono text-[10px] text-faint">
                ran {snapshot.tag}
              </span>
            </li>
          </ul>
        </div>
      </.card>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :path, :string, required: true
  attr :guest, :string, required: true
  attr :text, :string, required: true

  defp kept(assigns) do
    ~H"""
    <div class="group/kept">
      <dt class="flex items-baseline gap-2">
        <span class="font-medium text-ink">{@label}</span>
        <span class="font-mono text-[10px] text-muted">{@guest}</span>
      </dt>
      <dd class="text-[11px] leading-4 text-muted">{@text}</dd>
      <dd class="truncate font-mono text-[10px] text-faint" title={@path}>{@path}</dd>
    </div>
    """
  end

  ## Host & network

  defp host_tab(assigns) do
    assigns = assign(assigns, :refused, Sandbox.refused_addresses())

    ~H"""
    <div class="grid items-start gap-5 lg:grid-cols-[minmax(0,1.3fr)_minmax(0,1fr)]">
      <.card id="settings-host" title="This machine, as agents see it">
        <:help>
          What mdt host prints and /mnt/mdt/host.md holds, so agents can write commands that run here. They never probe it themselves.
        </:help>
        <dl class="grid grid-cols-[auto_minmax(0,1fr)] gap-x-4 gap-y-1 text-xs">
          <dt class="text-muted">System</dt>
          <dd id="host-os" class="text-ink">{@host.facts.os} · {@host.facts.kernel}</dd>
          <dt class="text-muted">Architecture</dt>
          <dd class="font-mono text-[11px] text-ink">{@host.facts.arch}</dd>
          <dt class="text-muted">Shell</dt>
          <dd class="font-mono text-[11px] text-ink">{@host.facts.shell}</dd>
          <dt class="text-muted">Tools</dt>
          <dd id="host-tools" class="flex flex-wrap items-center gap-x-2 text-ink">
            <%= cond do %>
              <% @host.probing? -> %>
                <span class="text-muted">Looking…</span>
              <% is_nil(@host.tools) -> %>
                <span class="text-muted">Not checked yet</span>
              <% true -> %>
                <span>{length(@host.tools)} found</span>
            <% end %>
            <button
              type="button"
              id="host-probe"
              phx-click="probe_host"
              disabled={@host.probing?}
              class="cursor-pointer text-[11px] text-accent hover:underline disabled:cursor-default disabled:opacity-50"
            >
              Check again
            </button>
          </dd>
        </dl>
        <.form
          for={@host_form}
          id="host-notes-form"
          phx-submit="save_host_notes"
          class="mt-3 space-y-2 border-t border-line-soft pt-3"
        >
          <.input
            field={@host_form[:notes]}
            id="host-notes"
            type="textarea"
            label="Your notes for agents"
            rows="3"
            placeholder="e.g. The work VPN comes up with openvpn3 session-start --config work. Kubernetes contexts: staging, prod."
            class={[input_classes(), "leading-5", @host_error && "border-bad/70"]}
          />
          <p :if={@host_error} id="host-notes-error" class="text-[11px] text-bad">
            {@host_error}
          </p>
          <div class="flex items-center gap-2">
            <details id="host-preview" class="group/preview flex-1">
              <summary class="cursor-pointer list-none text-[11px] text-accent hover:underline [&::-webkit-details-marker]:hidden">
                What agents read
              </summary>
              <pre
                id="host-text"
                class="mt-2 max-h-80 overflow-auto whitespace-pre-wrap rounded-lg border border-line-soft bg-deep/50 p-2.5 font-mono text-[10px] leading-4 text-ink"
              >{@host.text}</pre>
            </details>
            <.button type="submit" id="host-notes-save" class="self-start">Save</.button>
          </div>
        </.form>
      </.card>

      <.card id="settings-network" title="Network">
        <:help>
          All of the VM's TCP goes through MDT. If MDT isn't running, the VM has no internet.
        </:help>
        <dl class="space-y-3 text-xs">
          <div>
            <dt class="text-muted">Private ranges</dt>
            <dd class="mt-1 text-[11px] leading-4 text-ink">
              Refused unless a network grant that lists them is on.
            </dd>
          </div>
          <div>
            <dt class="flex items-center gap-1.5 text-muted">
              Always refused
              <.help id="refused-help" label="About always refused addresses">
                Loopback and every address of this machine, read from its network interfaces, so the VM can't reach MDT or anything else listening here. A network grant naming one exact address and port opens it, for a tunnel.
              </.help>
            </dt>
            <dd id="refused-addresses" class="mt-1.5 flex flex-wrap gap-1">
              <span
                :for={address <- @refused}
                class="rounded border border-bad/25 bg-bad-soft/20 px-1.5 py-0.5 font-mono text-[10px] text-ink"
              >
                {address}
              </span>
            </dd>
          </div>
          <div class="rounded-lg border border-line-soft bg-deep/50 p-2.5">
            <p class="text-[11px] leading-4 text-muted">
              <span class="font-medium text-ink">Not covered:</span>
              DNS. Microsandbox answers it outside MDT, so query names can carry data out.
            </p>
          </div>
        </dl>
      </.card>
    </div>
    """
  end

  defp gigabytes(bytes), do: "#{Float.round(bytes / 1_000_000_000, 2)} GB"

  attr :settings, :any, required: true
  attr :desktop, :any, required: true

  defp notifications_card(assigns) do
    ~H"""
    <.card
      id="settings-notifications"
      title="Desktop notifications"
      subtitle="A notification for each approval that waits for you, so you hear of it while working in another window. Clicking one brings MDT forward on that approval; deciding happens there."
    >
      <div class="space-y-3">
        <div class="flex items-center gap-3">
          <.switch
            id="desktop-notifications-switch"
            on={@settings.desktop_notifications}
            label="Desktop notifications"
            phx-click="save_notifications"
            phx-value-on={to_string(not @settings.desktop_notifications)}
          />
          <span class="flex-1 text-xs text-ink">Notify me when an approval waits</span>
          <.button
            type="button"
            id="desktop-notifications-test"
            phx-click="test_notification"
            disabled={not desktop_connected?(@desktop)}
          >
            Send a test
          </.button>
        </div>
        <p id="desktop-notifications-status" class="flex items-start gap-1.5 text-[11px] leading-4">
          <span class={[
            "mt-1 size-1.5 shrink-0 rounded-full",
            case @desktop do
              {:connected, _info} -> "bg-ok"
              :connecting -> "bg-warn motion-safe:animate-pulse"
              _other -> "bg-faint"
            end
          ]}></span>
          <span class="text-muted">{desktop_words(@desktop)}</span>
        </p>
        <p class="text-[10px] leading-4 text-faint">
          GNOME lists them under MDT in Settings, Notifications, where you can turn off banners or sounds. A notification closes once its approval is decided or gives up.
        </p>
      </div>
    </.card>
    """
  end

  defp desktop_connected?({:connected, _info}), do: true
  defp desktop_connected?(_status), do: false

  defp desktop_words({:connected, %{name: name, version: version}}),
    do: "Shown by #{name} #{version}, through the session bus"

  defp desktop_words(:connecting), do: "Connecting to the desktop…"
  defp desktop_words({:unavailable, reason}), do: reason
  defp desktop_words(:off), do: "Not shown here: this MDT runs without a desktop"
  defp desktop_words(nil), do: "Checking the desktop…"
end
