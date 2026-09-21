defmodule MDTClientWeb.Plugs.LoopbackHost do
  @moduledoc """
  Rejects requests whose `Host` is not a loopback name.

  Binding to 127.0.0.1 keeps the network out, but it does not stop DNS
  rebinding: a page the user visits can point its own domain at 127.0.0.1, and
  the browser will then treat this app as same origin. `check_origin` cannot
  catch that, because the attacker controls the `Origin` *and* the `Host`, so
  the two agree. Pinning the accepted host names does catch it.

  Disabled when the endpoint is deliberately bound to a public interface.
  """

  import Plug.Conn

  @loopback ~w(127.0.0.1 localhost ::1)

  def init(opts), do: opts

  def call(conn, _opts) do
    if enforce?() and conn.host not in @loopback do
      conn |> send_resp(403, "Forbidden") |> halt()
    else
      conn
    end
  end

  defp enforce?, do: Application.get_env(:mdt_client, :require_loopback_host, true)
end
