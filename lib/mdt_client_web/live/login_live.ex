defmodule MDTClientWeb.LoginLive do
  @moduledoc """
  The screen the app boots to.

  Credentials are not verified yet: any email and password unlock the tool
  picker, so the rest of the interface can be explored.
  """
  use MDTClientWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Sign in")
     |> assign(:error, nil)
     |> assign_form(%{"email" => "dev@mdt.local", "password" => ""})}
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
              phx-submit="sign_in"
              phx-change="validate"
              class="space-y-3"
            >
              <.input
                field={@form[:email]}
                type="email"
                label="Email"
                placeholder="you@example.com"
                autocomplete="username"
                phx-mounted={JS.focus()}
              />
              <.input
                field={@form[:password]}
                type="password"
                label="Password"
                placeholder="••••••••"
                autocomplete="current-password"
              />

              <p :if={@error} id="login-error" class="flex items-center gap-1.5 text-xs text-bad">
                <.icon name="hero-exclamation-circle" class="size-4" />
                {@error}
              </p>

              <div class="flex items-center justify-between pt-1">
                <.input field={@form[:remember_me]} type="checkbox" label="Keep me signed in" />
                <button
                  type="button"
                  class="cursor-pointer text-xs text-muted transition-colors hover:text-accent"
                >
                  Forgot password?
                </button>
              </div>

              <.button id="sign-in" type="submit" variant="primary" class="mt-2 w-full py-2">
                Sign in <.icon name="hero-arrow-right" class="size-4" />
              </.button>
            </.form>
          </div>

          <p class="mt-5 text-center text-[11px] text-faint">
            v{Application.spec(:mdt_client, :vsn)} · authentication is mocked while the backend is built
          </p>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    {:noreply, socket |> assign(:error, nil) |> assign_form(params)}
  end

  @impl true
  def handle_event("sign_in", %{"user" => params}, socket) do
    email = String.trim(params["email"] || "")
    password = params["password"] || ""

    cond do
      email == "" ->
        {:noreply, socket |> assign(:error, "Enter your email") |> assign_form(params)}

      password == "" ->
        {:noreply, socket |> assign(:error, "Enter your password") |> assign_form(params)}

      true ->
        {:noreply, push_navigate(socket, to: ~p"/tools")}
    end
  end

  defp assign_form(socket, params) do
    assign(socket, :form, to_form(params, as: :user))
  end
end
