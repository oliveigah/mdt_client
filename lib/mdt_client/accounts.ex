defmodule MDTClient.Accounts do
  @moduledoc """
  Users of the app.

  Authentication is not implemented yet: the UI is wired against a single
  hardcoded user so the shell can render a session while the backend is built.
  """

  @doc "The placeholder signed in user."
  def mock_user(email \\ "dev@mdt.local") do
    name =
      email
      |> String.split("@")
      |> List.first()
      |> String.split(~r/[._-]/, trim: true)
      |> Enum.map_join(" ", &String.capitalize/1)

    %{
      email: email,
      name: name,
      initials: initials(name)
    }
  end

  defp initials(name) do
    name
    |> String.split(" ", trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&String.first(&1))
    |> String.upcase()
  end
end
