defmodule MDTClient.Tools do
  @moduledoc """
  The catalog of tools shipped with MDT.

  This is static metadata used by the tool picker and by the app title bar.
  """

  @tools [
    %{
      id: :http,
      name: "HTTP Client",
      tagline: "Compose, send and inspect requests",
      description:
        "Build requests with params, headers, auth and bodies. Keep several requests open in tabs and search everything you have ever sent.",
      icon: "hero-globe-alt",
      path: "/tools/http",
      shortcut: "1",
      status: :ready
    },
    %{
      id: :git,
      name: "Git GUI",
      tagline: "Browse history, branches and changes",
      description:
        "Open any repository in a tab, walk its commit graph, manage branches and stage, stash or commit exactly the files you pick.",
      icon: "git-branch",
      path: "/tools/git",
      shortcut: "2",
      status: :ready
    },
    %{
      id: :diagrams,
      name: "Diagrams",
      tagline: "Sketch boxes, tables, arrows and notes",
      description:
        "Draw shapes and tables, connect them with arrows, down to the row, and write on any of them. Every diagram is kept, and search finds a word wherever it was written.",
      icon: "diagram",
      path: "/tools/diagrams",
      shortcut: "3",
      status: :ready
    },
    %{
      id: :notes,
      name: "Notes",
      tagline: "Keep tasks and ideas, tick them off",
      description:
        "Write down tasks and ideas in Markdown and mark them done as you go. Every note is kept, and search finds a word wherever it was written.",
      icon: "hero-clipboard-document-check",
      path: "/tools/notes",
      shortcut: "4",
      status: :ready
    }
  ]

  @doc "All tools, in display order."
  def all, do: @tools

  @doc "Fetches a tool by id, raising when it is unknown."
  def fetch!(id) do
    Enum.find(@tools, &(&1.id == id)) || raise ArgumentError, "unknown tool #{inspect(id)}"
  end
end
