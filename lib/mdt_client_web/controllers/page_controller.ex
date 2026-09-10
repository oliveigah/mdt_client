defmodule MDTClientWeb.PageController do
  use MDTClientWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
