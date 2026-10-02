defmodule MDTClientWeb.AgentAccessLive do
  @moduledoc "Connects local agents to the current identity's MDT tools."
  use MDTClientWeb, :live_view

  alias MDTClient.MCP.Access

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Access.subscribe(socket.assigns.current_scope.user.username)

    {:ok,
     socket
     |> assign(:page_title, "Agent access")
     |> assign(:token, nil)
     |> assign(:enabled?, Access.enabled?(socket.assigns.current_scope.user.username))}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    uri = URI.parse(uri)
    url = URI.to_string(%{uri | path: "/mcp", query: nil, fragment: nil})
    {:noreply, assign(socket, :mcp_url, url)}
  end

  @impl true
  def handle_event("issue_token", _params, socket) do
    case Access.issue(socket.assigns.current_scope.user.username) do
      {:ok, token} ->
        {:noreply, assign(socket, token: token, enabled?: true)}

      {:error, :locked} ->
        {:noreply, push_navigate(socket, to: ~p"/")}

      {:error, :storage} ->
        {:noreply, put_flash(socket, :error, "Could not save the agent token. Try again.")}
    end
  end

  def handle_event("revoke_token", _params, socket) do
    case Access.revoke(socket.assigns.current_scope.user.username) do
      :ok ->
        {:noreply, assign(socket, token: nil, enabled?: false)}

      {:error, :locked} ->
        {:noreply, push_navigate(socket, to: ~p"/")}

      {:error, :storage} ->
        {:noreply, put_flash(socket, :error, "Could not disable agent access. Try again.")}
    end
  end

  @impl true
  def handle_info(:mcp_access_changed, socket) do
    {:noreply,
     assign(socket,
       token: nil,
       enabled?: Access.enabled?(socket.assigns.current_scope.user.username)
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} notices={@notices} update={@update}>
      <div class="flex min-h-0 flex-1 overflow-y-auto px-6 py-8 sm:px-10">
        <div class="mx-auto w-full max-w-3xl">
          <.link
            navigate={~p"/tools"}
            id="agents-back"
            class="inline-flex items-center gap-1.5 text-xs text-muted transition-colors hover:text-accent"
          >
            <.icon name="hero-arrow-left" class="size-3.5" /> All tools
          </.link>
          <header class="mb-7 mt-5">
            <span class="mb-3 flex size-11 items-center justify-center rounded-xl border border-accent/20 bg-accent-soft text-accent">
              <.icon name="hero-command-line" class="size-6" />
            </span>
            <h1 class="text-xl font-semibold tracking-tight">
              Give your agent a place to put its work.
            </h1>
            <p class="mt-2 max-w-xl text-[13px] leading-6 text-muted">
              Connect an MCP client to MDT. Your agent can create and update diagrams and Markdown
              notes, and add HTTP request samples in {@current_scope.user.username}'s vault.
            </p>
          </header>

          <div class="mb-6 grid gap-3 sm:grid-cols-3">
            <div
              :for={
                {icon, label, example} <- [
                  {"hero-square-3-stack-3d", "Diagrams",
                   "Make a diagram of our checkout flow on MDT."},
                  {"hero-paper-airplane", "HTTP samples", "Store this HTTP request sample in MDT."},
                  {"hero-document-text", "Notes", "Store this idea in a note in MDT."}
                ]
              }
              class="rounded-xl border border-line bg-panel p-4"
            >
              <.icon name={icon} class="mb-3 size-5 text-accent" />
              <h2 class="text-xs font-semibold">{label}</h2>
              <p class="mt-2 text-xs leading-5 text-muted">“{example}”</p>
            </div>
          </div>

          <section id="mcp-connection" class="overflow-hidden rounded-xl border border-line bg-panel">
            <div class="flex flex-wrap items-center justify-between gap-3 border-b border-line-soft px-5 py-4">
              <div>
                <h2 class="text-sm font-semibold">Local MCP connection</h2>
                <p class="mt-1 text-xs text-muted">Streamable HTTP · This machine only</p>
              </div>
              <span
                id="mcp-status"
                class={[
                  "rounded-full border px-2.5 py-1 text-[11px] font-medium",
                  if(@enabled?, do: "border-ok/30 bg-ok/10 text-ok", else: "border-line text-muted")
                ]}
              >
                {if(@enabled?, do: "Access enabled", else: "Access disabled")}
              </span>
            </div>
            <div class="space-y-4 p-5">
              <div>
                <p class="mb-1.5 text-[11px] font-medium text-muted">Server URL</p>
                <code
                  id="mcp-url"
                  class="block select-all break-all rounded-lg border border-line-soft bg-deep px-3 py-2.5 font-mono text-xs"
                >{@mcp_url}</code>
              </div>
              <div :if={@token} id="mcp-credentials" class="space-y-3">
                <div>
                  <p class="mb-1.5 text-[11px] font-medium text-muted">Bearer token</p>
                  <code
                    id="mcp-token"
                    class="block select-all break-all rounded-lg border border-line-soft bg-deep px-3 py-2.5 font-mono text-xs"
                  >{@token}</code>
                </div>
                <p class="text-xs leading-5 text-muted">
                  Copy this token now. It is shown only when generated and stays valid across restarts.
                </p>
                <div class="rounded-lg border border-line-soft bg-deep">
                  <div class="flex items-center justify-between border-b border-line-soft px-3 py-2">
                    <p class="text-[11px] font-medium text-muted">Client configuration</p>
                    <button
                      id="copy-mcp-config"
                      type="button"
                      phx-hook="CopyText"
                      phx-update="ignore"
                      data-copy-target="mcp-config"
                      class="cursor-pointer rounded px-2 py-1 text-[11px] text-accent transition-colors hover:bg-accent-soft"
                    >Copy</button>
                  </div>
                  <pre
                    id="mcp-config"
                    class="overflow-x-auto p-3 font-mono text-[11px] leading-5 text-ink"
                  >{client_config(@mcp_url, @token)}</pre>
                </div>
              </div>
              <p
                :if={@enabled? && !@token}
                id="mcp-existing-token"
                class="text-xs leading-5 text-muted"
              >
                An agent token is active. Generate a new token if you need to copy it again; the previous token will stop working.
              </p>
              <div class="flex flex-wrap gap-2">
                <button
                  id="issue-mcp-token"
                  type="button"
                  phx-click="issue_token"
                  class="cursor-pointer rounded-lg bg-accent px-3.5 py-2 text-xs font-semibold text-white transition-colors hover:bg-accent/85 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent"
                >
                  {if(@enabled?, do: "Generate new token", else: "Enable agent access")}
                </button>
                <button
                  :if={@enabled?}
                  id="revoke-mcp-token"
                  type="button"
                  phx-click="revoke_token"
                  class="cursor-pointer rounded-lg border border-line px-3.5 py-2 text-xs font-medium text-muted transition-colors hover:border-bad/40 hover:bg-bad/10 hover:text-bad"
                >Disable access</button>
              </div>
            </div>
          </section>
          <p class="mt-4 text-xs leading-6 text-muted">
            In your agent's MCP settings, add the server URL and an Authorization header with <code class="font-mono text-ink">Bearer &lt;token&gt;</code>. The connected agent can create,
            search, and read saved items, and update diagrams and notes. HTTP requests are append-only;
            new samples are saved for you to review and send in MDT.
          </p>
          <p id="mcp-token-lifetime" class="mt-2 text-xs leading-6 text-muted">
            Configure your agent once. Its token keeps working whenever this vault is unlocked.
            Locking or closing MDT pauses access; only generating a new token or disabling access revokes it.
          </p>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp client_config(url, token) do
    Jason.encode!(
      %{
        "mcpServers" => %{
          "mdt" => %{
            "type" => "http",
            "url" => url,
            "headers" => %{"Authorization" => "Bearer " <> token}
          }
        }
      },
      pretty: true
    )
  end
end
