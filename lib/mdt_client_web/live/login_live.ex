defmodule MDTClientWeb.LoginLive do
  @moduledoc """
  The screen the app boots to.

  A username and password unlock that identity's encrypted directory. An
  unknown username creates a profile, so the form says so before submit —
  otherwise a typo silently produces an empty history and looks like data loss.

  The form posts to `MDTClientWeb.SessionController`: only a plain request can
  write the session cookie.
  """
  use MDTClientWeb, :live_view

  alias MDTClient.Accounts
  alias MDTClient.Preferences

  @impl true
  def mount(params, _session, socket) do
    username = params["username"] || Preferences.get("last_username") || ""

    {:ok,
     socket
     |> assign(:page_title, "Sign in")
     |> assign(:error, error_message(params["error"]))
     |> assign_username(username)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} chrome={false}>
      <div class="absolute right-3 top-3">
        <Layouts.theme_toggle />
      </div>

      <div class="flex min-h-0 flex-1 items-center justify-center p-6">
        <div class="w-full max-w-sm">
          <div class="mb-7 flex flex-col items-center gap-3 text-center">
            <div class="flex size-12 items-center justify-center rounded-xl border border-line bg-panel text-accent shadow-lg shadow-black/10 dark:shadow-black/30">
              <Layouts.logo class="size-7" />
            </div>
            <div>
              <h1 class="text-xl font-semibold tracking-tight">MDT</h1>
              <p class="text-[13px] text-muted">My Dev Tools</p>
            </div>
          </div>

          <div class="rounded-xl border border-line bg-panel p-5 shadow-2xl shadow-black/10 dark:shadow-black/40">
            <.form
              for={@form}
              id="login-form"
              action={~p"/login"}
              phx-change="validate"
              class="space-y-3"
            >
              <.input
                field={@form[:username]}
                type="text"
                label="Username"
                placeholder="you"
                autocomplete="username"
                phx-mounted={@username == "" && JS.focus()}
              />
              <.input
                field={@form[:password]}
                type="password"
                label="Password"
                placeholder="••••••••"
                autocomplete="current-password"
                phx-mounted={@username != "" && JS.focus()}
              />

              <p :if={@error} id="login-error" class="flex items-center gap-1.5 text-xs text-bad">
                <.icon name="hero-exclamation-circle" class="size-4" />
                {@error}
              </p>

              <p
                :if={!@error and @new_profile?}
                id="new-profile-notice"
                class="flex items-center gap-1.5 text-xs text-accent"
              >
                <.icon name="hero-sparkles" class="size-4" />
                New profile — “{@username}” will be created
              </p>

              <.button id="sign-in" type="submit" variant="primary" class="mt-2 w-full py-2">
                {if @new_profile?, do: "Create and unlock", else: "Unlock"}
                <.icon name="hero-arrow-right" class="size-4" />
              </.button>
            </.form>
          </div>

          <p class="mt-5 text-center text-[11px] leading-4 text-faint">
            v{Application.spec(:mdt_client, :vsn)} · your history is encrypted with this password.
            <br />There is no way to recover it if you forget it.
          </p>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    # Editing the form clears a stale failure.
    {:noreply, socket |> assign(:error, nil) |> assign_username(params["username"] || "")}
  end

  # Only known codes are rendered, so nothing a caller puts in the query string
  # reaches the page.
  defp error_message("bad_password"), do: "Incorrect password"
  defp error_message("blank_username"), do: "Enter a username"
  defp error_message("blank_password"), do: "Enter a password"
  defp error_message("unreadable_vault"), do: "That profile's vault file could not be read"
  defp error_message(_other), do: nil

  defp assign_username(socket, username) do
    trimmed = Accounts.normalize(username)

    socket
    |> assign(:username, username)
    |> assign(:new_profile?, trimmed != "" and not Accounts.exists?(trimmed))
    |> assign(:form, to_form(%{"username" => username, "password" => ""}, as: :user))
  end
end
