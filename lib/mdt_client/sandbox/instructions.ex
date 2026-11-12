defmodule MDTClient.Sandbox.Instructions do
  @moduledoc """
  What agents in the VM are told: access comes only from MDT's grants, what
  MDT's answers mean, how to use mise and their own memory
  (`priv/sandbox/agents.md`), and which grants exist right now (`grants/2`).

  The instructions reach Claude Code and Codex through their global files in
  the VM's Home, `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`, as a block
  MDT rewrites before every start (`put_block/2`). The rest of each file is
  left alone. Agents may edit the block meanwhile; the next start undoes it.
  """

  alias MDTClient.Sandbox.{Grant, Recipes}

  @begin "<!-- mdt:begin · MDT rewrites this block before every start; write below it -->"
  @finish "<!-- mdt:end -->"
  @home_files [".claude/CLAUDE.md", ".codex/AGENTS.md"]

  @doc "The standing instructions, as Markdown."
  @spec text() :: String.t()
  def text, do: File.read!(Path.join([:code.priv_dir(:mdt_client), "sandbox", "agents.md"]))

  @doc "The files in Home that carry the block, relative to Home."
  @spec home_files() :: [String.t()]
  def home_files, do: @home_files

  @doc "Writes the block into each of `home_files/0` under `home`."
  @spec write_home!(Path.t(), String.t()) :: :ok
  def write_home!(home, text) do
    for relative <- @home_files do
      path = Path.join(home, relative)
      File.mkdir_p!(Path.dirname(path))

      existing =
        case File.read(path) do
          {:ok, content} -> content
          {:error, _} -> ""
        end

      updated = put_block(existing, text)
      if updated != existing, do: File.write!(path, updated)
    end

    :ok
  end

  @doc """
  `content` with MDT's block holding `text`: replaced where it was, or put at
  the top.

      iex> MDTClient.Sandbox.Instructions.put_block("mine\\n", "theirs") =~ ~r/^<!-- mdt:begin.*theirs\\n<!-- mdt:end -->\\n\\nmine\\n$/s
      true
  """
  @spec put_block(String.t(), String.t()) :: String.t()
  def put_block(content, text) do
    block = @begin <> "\n" <> String.trim(text) <> "\n" <> @finish <> "\n"

    case :binary.match(content, @begin) do
      {start, _} ->
        rest = binary_part(content, start, byte_size(content) - start)

        case :binary.match(rest, @finish) do
          {stop, length} ->
            after_block =
              binary_part(rest, stop + length, byte_size(rest) - stop - length)
              |> String.replace_prefix("\n", "")

            binary_part(content, 0, start) <> block <> after_block

          :nomatch ->
            binary_part(content, 0, start) <> block
        end

      :nomatch ->
        if String.trim(content) == "", do: block, else: block <> "\n" <> content
    end
  end

  @doc "`/mnt/mdt/grants.md`: every grant and its state at `now`, for agents."
  @spec grants([Grant.t()], DateTime.t()) :: String.t()
  def grants(grants, now) do
    kinds = Enum.map_join(Recipes.all(), ", ", & &1.name)

    rows =
      for grant <- grants do
        "| #{cell(grant.name)} | #{kind(grant)} | #{state(grant)} | #{cell(reach(grant))} | " <>
          "#{cell(holds(grant))} | #{cell(rules(grant))} |"
      end

    table =
      if rows == [] do
        "No grants yet."
      else
        Enum.join(
          [
            "| Grant | Kind | State | For | In the VM | Requests |",
            "|---|---|---|---|---|---|" | rows
          ],
          "\n"
        )
      end

    """
    # Grants, as of #{Calendar.strftime(now, "%Y-%m-%d %H:%M")} UTC

    Written by MDT whenever a grant changes. Ask the user to add or turn on
    what you need in MDT, under Agent Sandbox, Grants.

    #{table}

    Kinds the user can add: #{kinds}.
    """
  end

  defp kind(%Grant{recipe: recipe}) do
    case Recipes.find(to_string(recipe)) do
      {:ok, found} -> found.name
      :error -> to_string(recipe)
    end
  end

  defp state(%Grant{state: :on, expires_at: %DateTime{} = at}),
    do: "on until #{Calendar.strftime(at, "%H:%M")} UTC"

  defp state(%Grant{state: :on}), do: "on"
  defp state(%Grant{}), do: "off"

  defp reach(%Grant{kind: :network, destinations: destinations}),
    do: Enum.join(destinations, ", ")

  defp reach(%Grant{kind: :file, path: path}), do: path || ""
  defp reach(%Grant{hosts: hosts}), do: Enum.join(hosts, ", ")

  defp holds(%Grant{kind: :http, env: env}) when env != [],
    do: Enum.map_join(env, ", ", &"`#{&1}`") <> " (placeholders)"

  defp holds(%Grant{kind: :file, state: :on}), do: "the file itself"
  defp holds(%Grant{kind: :file}), do: "nothing while off"
  defp holds(%Grant{}), do: "nothing"

  defp rules(%Grant{kind: :network, per_connection: :ask}),
    do: "each connection waits for the user"

  defp rules(%Grant{kind: :network}), do: "connections go through"

  defp rules(%Grant{rules: rules, default_action: default}) do
    listed = Enum.map(rules, &"#{&1.label}: #{word(&1.action)}")
    Enum.join(listed ++ ["anything else: #{word(default)}"], "; ")
  end

  defp word(:allow), do: "go through"
  defp word(:ask), do: "wait for the user"
  defp word(:deny), do: "refused"

  defp cell(text),
    do: text |> to_string() |> String.replace("|", "\\|") |> String.replace("\n", " ")
end
