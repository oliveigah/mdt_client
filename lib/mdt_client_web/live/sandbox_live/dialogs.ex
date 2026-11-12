defmodule MDTClientWeb.SandboxLive.Dialogs do
  @moduledoc """
  The two dialogs about what the VM keeps:

    * `create/1` - before the VM is created or recreated: what happens to
      its Home and Cache, and whether its memory starts from yours;
    * `memory_review/1` - the VM's new memories, to pick which join yours.
  """
  use MDTClientWeb, :html

  attr :mode, :atom, required: true, doc: ":create or :recreate"
  attr :vm, :any, required: true
  attr :image, :map, required: true
  attr :snapshots, :list, required: true
  attr :memory, :map, required: true
  attr :created_ref, :string, default: nil

  def create(assigns) do
    assigns =
      assign(assigns,
        target_tag: tag(assigns.image.tag),
        running_tag: tag(assigns.created_ref)
      )

    ~H"""
    <div
      id="create-dialog"
      class="fixed inset-0 z-50 flex items-center justify-center p-6"
      role="dialog"
      aria-modal="true"
      aria-labelledby="create-dialog-title"
      phx-window-keydown="close_create"
      phx-key="Escape"
    >
      <div class="absolute inset-0 bg-black/50" phx-click="close_create"></div>
      <.form
        for={%{}}
        as={:create}
        id="create-form"
        phx-submit="confirm_create"
        class="relative flex max-h-full w-full max-w-lg flex-col overflow-hidden rounded-xl border border-line bg-panel shadow-2xl shadow-black/30 dark:shadow-black/60"
      >
        <div class="border-b border-line-soft px-5 py-4">
          <p id="create-dialog-title" class="text-[15px] font-semibold text-ink">
            {if @mode == :recreate, do: "Recreate the VM", else: "Create the VM"}
          </p>
          <p class="mt-1 text-xs leading-5 text-muted">
            A fresh root filesystem from
            <span class="font-mono text-ink">{@image.tag}</span><span :if={
              @mode == :recreate and not is_nil(@running_tag) and @running_tag != @target_tag
            }> (it runs {@running_tag} now)</span>. Your shared folders and the VM's memory stay; choose what happens to the rest.
          </p>
        </div>

        <div class="min-h-0 flex-1 space-y-5 overflow-y-auto px-5 py-4">
          <fieldset id="create-home">
            <legend class="text-xs font-semibold text-ink">Home, /root</legend>
            <p class="mt-0.5 text-[11px] leading-4 text-muted">
              Logins, shell history, Zed's server and agent settings.
              <span :if={@mode == :recreate}>A copy is taken first, whatever you pick.</span>
            </p>
            <div class="mt-2 space-y-1.5">
              <.choice
                id="create-home-keep"
                name="create[home]"
                value="keep"
                checked
                title="Keep it"
                text="Logged-in agents stay logged in."
              />
              <.choice
                :for={snapshot <- @snapshots}
                id={"create-home-#{snapshot.id}"}
                name="create[home]"
                value={"snapshot:" <> snapshot.id}
                title={"Go back to the copy from #{Calendar.strftime(snapshot.taken_at, "%b %-d, %H:%M")} UTC"}
                text={
                  if snapshot.tag,
                    do:
                      "Taken while the VM ran #{snapshot.tag}#{if snapshot.tag == @target_tag, do: ", the tag you're recreating from", else: ""}.",
                    else: "Taken before an earlier recreate."
                }
                badge={snapshot.tag == @target_tag && "matches"}
              />
              <.choice
                id="create-home-empty"
                name="create[home]"
                value="empty"
                title="Start empty"
                text="The real reset: anything an agent left in Home that runs code (hooks, MCP servers, shell files) is gone. You log the agents in again."
                tone="warn"
              />
            </div>
          </fieldset>

          <fieldset id="create-cache">
            <legend class="text-xs font-semibold text-ink">Cache, /cache</legend>
            <p class="mt-0.5 text-[11px] leading-4 text-muted">
              Tool versions installed in the VM and package caches. Only speed is lost by clearing it.
            </p>
            <div class="mt-2 grid grid-cols-2 gap-1.5">
              <.choice
                id="create-cache-keep"
                name="create[cache]"
                value="keep"
                checked
                title="Keep it"
              />
              <.choice
                id="create-cache-clear"
                name="create[cache]"
                value="clear"
                title="Clear it"
                tone="warn"
              />
            </div>
          </fieldset>

          <fieldset id="create-memory">
            <legend class="text-xs font-semibold text-ink">The VM's memory</legend>
            <%= if @memory.host? do %>
              <label
                for="create-seed-memory"
                class="mt-2 flex cursor-pointer items-start gap-2.5 rounded-lg border border-line-soft bg-deep/30 px-3 py-2.5 transition-colors hover:border-line"
              >
                <input type="hidden" name="create[seed_memory]" value="false" />
                <input
                  type="checkbox"
                  id="create-seed-memory"
                  name="create[seed_memory]"
                  value="true"
                  class="mt-0.5 size-3.5 accent-[var(--color-accent)]"
                />
                <span>
                  <span class="block text-xs font-medium text-ink">Start it from a copy of mine</span>
                  <span class="mt-0.5 block text-[11px] leading-4 text-muted">
                    Replaces what the VM remembers (it is moved aside, not deleted). Copies every memory you have, work ones included, into a VM whose traffic is open by default.
                  </span>
                </span>
              </label>
            <% else %>
              <p class="mt-1 text-[11px] leading-4 text-muted">
                It stays as it is. OptMem isn't installed on this machine, so there is no memory of yours to copy.
              </p>
            <% end %>
          </fieldset>
        </div>

        <div class="flex items-center justify-end gap-2 border-t border-line-soft px-5 py-3">
          <.button type="button" id="create-cancel" phx-click="close_create">Cancel</.button>
          <.button type="submit" id="create-confirm" variant="primary">
            {if @mode == :recreate, do: "Recreate", else: "Create and start"}
          </.button>
        </div>
      </.form>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :value, :string, required: true
  attr :title, :string, required: true
  attr :text, :string, default: nil
  attr :checked, :boolean, default: false
  attr :tone, :string, default: nil
  attr :badge, :any, default: nil

  defp choice(assigns) do
    ~H"""
    <label
      for={@id}
      class={[
        "flex cursor-pointer items-start gap-2.5 rounded-lg border px-3 py-2 transition-colors",
        "border-line-soft hover:border-line has-[:checked]:bg-active",
        if(@tone == "warn",
          do: "has-[:checked]:border-warn/50",
          else: "has-[:checked]:border-accent/50"
        )
      ]}
    >
      <input
        type="radio"
        id={@id}
        name={@name}
        value={@value}
        checked={@checked}
        class="mt-0.5 size-3.5 accent-[var(--color-accent)]"
      />
      <span class="min-w-0 flex-1">
        <span class="flex items-center gap-2 text-xs font-medium text-ink">
          {@title}
          <span
            :if={@badge}
            class="rounded-full border border-accent/30 bg-accent/10 px-1.5 text-[9px] font-semibold uppercase tracking-wide text-accent"
          >
            {@badge}
          </span>
        </span>
        <span :if={@text} class="mt-0.5 block text-[11px] leading-4 text-muted">{@text}</span>
      </span>
    </label>
    """
  end

  attr :review, :map, required: true

  def memory_review(assigns) do
    ~H"""
    <div
      id="memory-review"
      class="fixed inset-0 z-50 flex items-center justify-center p-6"
      role="dialog"
      aria-modal="true"
      aria-labelledby="memory-review-title"
      phx-window-keydown="close_review"
      phx-key="Escape"
    >
      <div class="absolute inset-0 bg-black/50" phx-click="close_review"></div>
      <.form
        for={%{}}
        as={:review}
        id="memory-review-form"
        phx-submit="bring_back"
        class="relative flex max-h-full w-full max-w-2xl flex-col overflow-hidden rounded-xl border border-line bg-panel shadow-2xl shadow-black/30 dark:shadow-black/60"
      >
        <div class="border-b border-line-soft px-5 py-4">
          <p id="memory-review-title" class="text-[15px] font-semibold text-ink">
            What the VM remembered
          </p>
          <p class="mt-1 text-xs leading-5 text-muted">
            Tick what should join your own memory; each goes in as a new note, marked [vm]. Your agents act on what they remember, so read each as something a VM agent wants them to believe.
          </p>
        </div>

        <%= if @review.entries == [] do %>
          <div class="px-5 py-10 text-center text-xs text-muted" id="memory-review-empty">
            Nothing new since the last review.
          </div>
        <% else %>
          <ul class="min-h-0 flex-1 divide-y divide-line-soft overflow-y-auto">
            <li
              :for={entry <- @review.entries}
              id={"memory-entry-#{entry.index}"}
              class="flex gap-3 px-5 py-3"
            >
              <input
                type="checkbox"
                id={"memory-pick-#{entry.index}"}
                name="review[pick][]"
                value={entry.index}
                checked={Map.has_key?(@review.errors, entry.index)}
                class="mt-1 size-3.5 shrink-0 accent-[var(--color-accent)]"
              />
              <div class="min-w-0 flex-1">
                <p class="font-mono text-[10px] text-faint">#{entry.id} · {entry.date}</p>
                <textarea
                  id={"memory-text-#{entry.index}"}
                  name={"review[text][#{entry.index}]"}
                  rows="2"
                  class="mt-1 w-full resize-y rounded-md border border-line-soft bg-deep/40 px-2 py-1.5 text-xs leading-5 text-ink outline-none focus:border-accent/60"
                >{@review.texts[entry.index] || "[vm] " <> entry.text}</textarea>
                <p
                  :if={@review.errors[entry.index]}
                  id={"memory-error-#{entry.index}"}
                  class="mt-1 text-[11px] leading-4 text-bad"
                >
                  {@review.errors[entry.index]}
                </p>
              </div>
            </li>
          </ul>
        <% end %>

        <div class="flex items-center gap-2 border-t border-line-soft px-5 py-3">
          <button
            :if={@review.entries != []}
            type="button"
            id="memory-dismiss"
            phx-click="dismiss_memories"
            class="cursor-pointer rounded px-2 py-1 text-[11px] text-muted transition-colors hover:bg-hover hover:text-ink"
          >
            Mark all reviewed
          </button>
          <span class="flex-1"></span>
          <.button type="button" id="memory-close" phx-click="close_review">Close</.button>
          <.button :if={@review.entries != []} type="submit" id="memory-bring-back" variant="primary">
            Add ticked to my memory
          </.button>
        </div>
      </.form>
    </div>
    """
  end

  defp tag(nil), do: nil
  defp tag(ref), do: ref |> String.split(":", parts: 2) |> List.last()
end
