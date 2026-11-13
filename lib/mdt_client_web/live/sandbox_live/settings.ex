defmodule MDTClientWeb.SandboxLive.Settings do
  @moduledoc """
  The settings page: the VM's image (its name, your Containerfile, MDT's
  layer, the build and the builds kept), its size, the folders it sees, what
  the network always refuses, the folders it keeps (Home, Cache, its memory)
  and the round trip of its memory with yours.
  """
  use MDTClientWeb, :html

  import MDTClientWeb.SandboxLive.Components

  alias MDTClient.Sandbox
  alias MDTClient.Sandbox.Image

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

  def page(assigns) do
    current = Enum.find(assigns.builds, &(&1.ref == assigns.image.tag))

    assigns =
      assign(assigns,
        refused: Sandbox.refused_addresses(),
        mdt_layer: Image.mdt_layer(),
        current: current,
        different_default?: assigns.settings.containerfile != Image.default_containerfile(),
        edited?: current != nil and current.containerfile != assigns.settings.containerfile
      )

    ~H"""
    <.page_header
      title="Settings"
      subtitle="How the VM is built. Microsandbox can't change mounts or resources on a VM that exists, so changes here apply when it is recreated."
    />

    <div
      :if={@vm.stale?}
      id="settings-stale"
      class="mb-5 flex flex-wrap items-center gap-3 rounded-xl border border-warn/35 bg-warn-soft/30 px-4 py-3"
    >
      <.icon name="hero-arrow-path" class="size-4 text-warn" />
      <p class="flex-1 text-xs text-ink">
        The VM still runs with the previous settings or image. Recreating it starts a fresh root filesystem from the current image; you choose what happens to its Home and Cache.
      </p>
      <.button
        id="settings-recreate"
        phx-click="recreate_vm"
        disabled={not is_nil(@vm.busy) or not @image.loaded?}
      >
        Recreate now
      </.button>
    </div>

    <.card
      id="settings-image"
      title="The VM's image"
      subtitle="Your Containerfile, then MDT's layer. Built with podman on this machine and handed to microsandbox."
      class="mb-5"
      body_class=""
    >
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
        class="border-b border-line-soft px-4 py-3 text-[11px] leading-5 text-muted"
      >
        <p>
          MDT's default comes with Bash, completion, language runtimes and development CLIs already installed. Save the recipe, build the image, then recreate the VM to use it. Restarting keeps the same image.
        </p>
        <p :if={@different_default?} id="containerfile-default-differs" class="mt-1 text-ink">
          Your saved recipe differs from MDT's current default. To adopt the current setup, choose "Start from MDT's default" below, save, and build. Review any customizations before replacing them. You can keep Home and Cache when recreating.
        </p>
      </div>

      <.form
        for={@name_form}
        id="image-name-form"
        phx-submit="save_image_name"
        class="flex flex-wrap items-center gap-2 border-b border-line-soft px-4 py-2.5"
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
            "w-64 rounded-md border bg-deep px-2 py-1 font-mono text-xs text-ink outline-none focus:border-accent/60",
            if(@name_error, do: "border-bad/70", else: "border-line")
          ]}
        />
        <.button type="submit" id="image-name-save">Save</.button>
        <p :if={@name_error} id="image-name-error" class="text-[11px] text-bad">{@name_error}</p>
        <p class="ml-auto text-[10px] text-faint">
          Each build is tagged with its date and number, like
          <span class="font-mono">{@settings.image_name}:{Date.to_iso8601(Date.utc_today())}.1</span>
        </p>
      </.form>

      <p
        :if={@edited?}
        id="containerfile-edited"
        class="flex items-center gap-2 border-b border-warn/30 bg-warn-soft/25 px-4 py-2 text-[11px] text-ink"
      >
        <.icon name="hero-pencil-square-micro" class="size-3.5 text-warn" />
        The Containerfile changed since the current build. Build to use it.
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
              class="flex-1 font-mono text-[10px] text-faint"
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
              <p class="flex-1 text-[10px] font-semibold uppercase tracking-wide text-muted">
                MDT adds this layer
              </p>
            </div>
            <pre
              id="mdt-layer"
              class="max-h-96 flex-1 overflow-auto bg-deep/40 px-4 py-3 font-mono text-[10px] leading-4 text-faint"
              phx-no-curly-interpolation
            ><%= String.trim(@mdt_layer) %></pre>
          <% end %>
          <ul class="space-y-1.5 border-t border-line-soft px-4 py-3 text-[10px] leading-4 text-muted">
            <li class="flex gap-2">
              <.icon name="hero-finger-print-micro" class="mt-px size-3 shrink-0 text-accent" />
              MDT's layer points at /mnt/mdt and /cache. The image holds nothing of this identity's; CA, grant and helper updates arrive without rebuilding it.
            </li>
            <li class="flex gap-2">
              <.icon name="hero-exclamation-triangle-micro" class="mt-px size-3 shrink-0 text-warn" />
              The build runs here, in a rootless podman container, which isolates less than the VM. Install scripts in your Containerfile run there.
            </li>
            <li :if={not @tools.podman} class="flex gap-2 text-bad">
              <.icon name="hero-x-circle-micro" class="mt-px size-3 shrink-0" />
              podman is not installed, so the image can't be built.
            </li>
          </ul>
        </div>
      </div>
    </.card>

    <.card
      id="settings-builds"
      title="Builds kept"
      subtitle="The current one and the two before it. Going back means using a build, not the recipe: rebuilding the same Containerfile later gives other versions."
      class="mb-5"
      body_class=""
    >
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

    <div class="grid gap-5 lg:grid-cols-[minmax(0,1.3fr)_minmax(0,1fr)]">
      <div class="space-y-5">
        <.card
          id="settings-shares"
          title="Shared folders"
          subtitle="Each folder appears at the same path in the VM. Pick project folders one by one."
          body_class=""
        >
          <ul class="divide-y divide-line-soft">
            <li :if={@settings.shares == []}>
              <.empty icon="hero-folder">The VM sees no folder of yours yet.</.empty>
            </li>
            <li
              :for={{share, index} <- Enum.with_index(@settings.shares)}
              id={"share-#{index}"}
              class="flex items-center gap-3 px-4 py-2.5"
            >
              <.icon
                name={if share.mode == :rw, do: "hero-folder-open", else: "hero-lock-closed"}
                class={[
                  "size-4 shrink-0",
                  if(share.mode == :rw, do: "text-accent", else: "text-faint")
                ]}
              />
              <p class="min-w-0 flex-1 truncate font-mono text-[11px] text-ink" title={share.path}>
                {share.path}
              </p>
              <.segmented
                id={"share-mode-#{index}"}
                options={[{:rw, "Read-write"}, {:ro, "Read-only"}]}
                value={share.mode}
                event="set_share_mode"
                name="mode"
                values={%{"path" => share.path}}
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
            class="flex flex-wrap items-start gap-2 border-t border-line-soft bg-deep/30 px-4 py-3"
          >
            <div class="min-w-64 flex-1">
              <input
                type="text"
                name={@share_form[:path].name}
                id="share-path"
                value={@share_form[:path].value}
                placeholder="~/projects/some-repo"
                autocomplete="off"
                spellcheck="false"
                class={[input_classes(), "font-mono text-xs", @share_error && "border-bad/70"]}
              />
              <p
                :if={@share_error}
                id="share-error"
                class="mt-1.5 flex items-start gap-1.5 text-[11px] leading-4 text-bad"
              >
                <.icon name="hero-exclamation-circle-micro" class="mt-px size-3.5 shrink-0" />
                {@share_error}
              </p>
            </div>
            <select
              name={@share_form[:mode].name}
              id="share-mode"
              class="rounded-md border border-line bg-deep px-2 py-1.5 text-xs text-ink outline-none focus:border-accent/60"
            >
              <option value="rw" selected={@share_form[:mode].value != "ro"}>Read-write</option>
              <option value="ro" selected={@share_form[:mode].value == "ro"}>Read-only</option>
            </select>
            <.button type="submit" id="share-add">
              <.icon name="hero-plus-micro" class="size-3.5" /> Share
            </.button>
          </.form>
          <p class="border-t border-line-soft px-4 py-2.5 text-[10px] leading-4 text-faint">
            Never shared: your home folder itself, ~/.ssh, ~/.gnupg, ~/.optmem, cloud CLI logins and MDT's own data. Folders can't sit inside one another, since the VM could unmount the inner one. Anything you later run from a shared folder on this machine runs outside the VM.
          </p>
        </.card>

        <.card id="settings-vm" title="Size and timing">
          <.form for={@vm_form} id="vm-form" phx-submit="save_settings" class="space-y-4">
            <div class="grid gap-4 sm:grid-cols-3">
              <div>
                <.input field={@vm_form[:cpus]} type="number" label="CPUs" min="1" max="64" />
                <p :if={@vm_errors[:cpus]} class="mt-1 text-[11px] text-bad">{@vm_errors[:cpus]}</p>
              </div>
              <div>
                <.input
                  field={@vm_form[:memory_gib]}
                  type="number"
                  label="Memory, GiB"
                  min="1"
                  max="512"
                />
                <p :if={@vm_errors[:memory_gib]} class="mt-1 text-[11px] text-bad">
                  {@vm_errors[:memory_gib]}
                </p>
              </div>
              <div>
                <.input
                  field={@vm_form[:disk_gib]}
                  type="number"
                  label="Root disk, GiB"
                  min="4"
                  max="4096"
                />
                <p :if={@vm_errors[:disk_gib]} class="mt-1 text-[11px] text-bad">
                  {@vm_errors[:disk_gib]}
                </p>
              </div>
              <div>
                <.input
                  field={@vm_form[:write_budget_gib]}
                  type="number"
                  label="Folder writes, GiB"
                  min="1"
                  max="4096"
                />
                <p :if={@vm_errors[:write_budget_gib]} class="mt-1 text-[11px] text-bad">
                  {@vm_errors[:write_budget_gib]}
                </p>
              </div>
              <div>
                <.input
                  field={@vm_form[:hold_seconds]}
                  type="number"
                  label="Hold, s"
                  min="30"
                  max="600"
                />
                <p :if={@vm_errors[:hold_seconds]} class="mt-1 text-[11px] text-bad">
                  {@vm_errors[:hold_seconds]}
                </p>
              </div>
              <div>
                <.input
                  field={@vm_form[:proxy_port]}
                  type="number"
                  label="Proxy port"
                  min="1024"
                  max="65535"
                />
                <p :if={@vm_errors[:proxy_port]} class="mt-1 text-[11px] text-bad">
                  {@vm_errors[:proxy_port]}
                </p>
              </div>
            </div>
            <p class="text-[10px] leading-4 text-faint">
              The root disk holds what the image and the VM write outside its folders (apt packages, /tmp, /var); it takes space on this machine only as it fills, and starts empty when the VM is recreated. Folder writes is how much the VM may add to each read-write folder (Home, Cache, its memory, your shares) per boot, so a runaway agent can't fill your disk. Both need the VM recreated.
            </p>
            <p class="text-[10px] leading-4 text-faint">
              Hold is how long a request waits for your decision before it gives up; the image sets HEX_HTTP_TIMEOUT above it, since Hex otherwise gives up after 15 seconds. A new proxy port needs the VM recreated, since microsandbox pins it at creation.
            </p>
            <div class="flex items-center gap-2">
              <span class="flex-1 text-[11px] text-muted">
                <%= if @tools.msb do %>
                  <.icon name="hero-check-circle-micro" class="size-3.5 text-ok" /> MDT's msb at
                  <span class="font-mono">{@tools.msb}</span>
                <% else %>
                  <.icon name="hero-exclamation-triangle-micro" class="size-3.5 text-warn" />
                  MDT's microsandbox runtime is missing
                <% end %>
              </span>
              <.button type="submit" id="vm-save" variant="primary">Save</.button>
            </div>
          </.form>
        </.card>
      </div>

      <div class="space-y-5">
        <.card
          id="settings-network"
          title="Network"
          subtitle="All of the VM's TCP goes through MDT. If MDT isn't running, the VM has no internet."
        >
          <dl class="space-y-3 text-xs">
            <div>
              <dt class="text-muted">Private ranges</dt>
              <dd class="mt-1 text-[11px] leading-4 text-ink">
                Refused unless a network grant that lists them is on.
              </dd>
            </div>
            <div>
              <dt class="text-muted">Always refused</dt>
              <dd id="refused-addresses" class="mt-1.5 flex flex-wrap gap-1">
                <span
                  :for={address <- @refused}
                  class="rounded border border-bad/25 bg-bad-soft/20 px-1.5 py-0.5 font-mono text-[10px] text-ink"
                >
                  {address}
                </span>
              </dd>
              <p class="mt-1.5 text-[10px] leading-4 text-faint">
                Loopback and every address of this machine, read from its network interfaces, so the VM can't reach MDT or anything else listening here. A network grant naming one exact address and port opens it, for a tunnel.
              </p>
            </div>
            <div class="rounded-lg border border-line-soft bg-deep/50 p-2.5">
              <p class="text-[11px] leading-4 text-muted">
                <span class="font-medium text-ink">Not covered:</span>
                DNS. Microsandbox answers it outside MDT, so query names can carry data out.
              </p>
            </div>
          </dl>
        </.card>

        <.card
          id="settings-host"
          title="This machine, as agents see it"
          subtitle="What mdt host prints and /mnt/mdt/host.md holds, so agents can write commands that run here. They never probe it themselves."
        >
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

        <.card
          id="settings-folders"
          title="What the VM keeps"
          subtitle="Folders of MDT's, mounted into the VM besides yours. They survive recreating it."
        >
          <dl class="space-y-2.5 text-xs">
            <.kept
              label="Home, read-write"
              path={@folders.home}
              guest="/root"
              text="Logins, shell history, Zed's server, agent settings."
            />
            <.kept
              label="Cache, read-write"
              path={@folders.cache}
              guest="/cache"
              text="Tool versions installed in the VM and package caches."
            />
            <.kept
              label="The VM's memory, read-write"
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
          <p class="mt-3 text-[10px] leading-4 text-faint">
            Written by the VM, so MDT treats them as data and never runs anything from them. Whatever in Home runs code (agent hooks, MCP servers, shell files) survives a recreate unless you start it empty.
          </p>
        </.card>

        <.card
          id="settings-vm-memory"
          title="The VM's memory"
          subtitle="Its own OptMem. It can start from a copy of yours, and what it learns comes back only through your review."
        >
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
            <p class="mt-3 text-[10px] leading-4 text-faint">
              Copying replaces what the VM remembers (moved aside, not deleted) with every memory you have, work ones included; only while the VM is stopped. Nothing it notes reaches yours unless you tick it in the review.
            </p>
          <% else %>
            <p class="text-xs leading-5 text-muted">
              OptMem isn't installed on this machine (~/.optmem/memo), so the VM's memory can't be set up or compared with yours.
            </p>
          <% end %>
        </.card>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :path, :string, required: true
  attr :guest, :string, required: true
  attr :text, :string, required: true

  defp kept(assigns) do
    ~H"""
    <div>
      <dt class="text-muted">{@label}</dt>
      <dd class="mt-0.5 break-all font-mono text-[11px] text-ink">{@path} → {@guest}</dd>
      <dd class="text-[10px] leading-4 text-faint">{@text}</dd>
    </div>
    """
  end

  defp gigabytes(bytes), do: "#{Float.round(bytes / 1_000_000_000, 2)} GB"
end
