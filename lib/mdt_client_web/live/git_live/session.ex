defmodule MDTClientWeb.GitLive.Session do
  @moduledoc """
  Remembers which repositories the Git tool had open.

  The list lives in `MDTClient.Preferences`, next to the theme and the SSH key
  choice, so reopening the tool brings the same tabs back in the same order.
  Only worktree paths are stored: they are not secrets, and anything that has
  since moved is dropped the first time it fails to open.
  """

  alias MDTClient.Preferences

  @repositories "git_repositories"
  @active "git_active_repository"

  @doc "The worktree paths that were open, in tab order."
  @spec repositories() :: [Path.t()]
  def repositories do
    case Preferences.get(@repositories) do
      paths when is_list(paths) -> Enum.filter(paths, &is_binary/1)
      _missing -> []
    end
  end

  @doc "The worktree path of the tab that was in front, if any."
  @spec active_repository() :: Path.t() | nil
  def active_repository do
    case Preferences.get(@active) do
      path when is_binary(path) -> path
      _missing -> nil
    end
  end

  @doc "Stores the open paths and which of them was in front."
  @spec remember([Path.t()], Path.t() | nil) :: :ok
  def remember(paths, active) when is_list(paths) do
    :ok = Preferences.put(@repositories, Enum.uniq(paths))
    :ok = Preferences.put(@active, active)
  end

  @doc "Drops one path from the remembered list, leaving the rest alone."
  @spec forget(Path.t()) :: :ok
  def forget(path) do
    remaining = Enum.reject(repositories(), &(&1 == path))
    active = if active_repository() == path, do: nil, else: active_repository()

    remember(remaining, active)
  end
end
