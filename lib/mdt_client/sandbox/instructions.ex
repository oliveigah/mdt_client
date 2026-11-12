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

  alias MDTClient.Sandbox.{Grant, Presets}

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

  @doc """
  Every grant and its state at `now`, for agents: `/mnt/mdt/grants.md`, and
  what `mdt grants` prints. Each says what it is for, in the user's words,
  and how to use it. Never a value.
  """
  @spec grants([Grant.t()], DateTime.t()) :: String.t()
  def grants(grants, now) do
    body =
      if grants == [],
        do: "No grants yet.",
        else: Enum.map_join(grants, "\n\n", &grant_block(&1, now))

    """
    # Grants, as of #{Calendar.strftime(now, "%Y-%m-%d %H:%M")} UTC

    Written by MDT whenever a grant changes. To use one that is off, ask the
    user with: mdt request GRANT_ID --reason "what you are about to do"
    For access no grant gives: mdt request --need "what, and for which host" --reason "why"

    #{body}
    """
  end

  defp grant_block(grant, now) do
    Enum.join(
      [
        "## #{grant.name}",
        "- id: `#{grant.id}` · #{Presets.kind_name(grant.kind)} · #{state(grant, now)}",
        "- for: #{one_line(grant.purpose)}",
        "- " <> usage(grant),
        "- " <> approval(grant)
      ],
      "\n"
    )
  end

  @doc "How an agent uses a grant, in one line."
  @spec usage(Grant.t()) :: String.t()
  def usage(%Grant{kind: :token} = grant) do
    holders =
      Enum.map(grant.env, &"$#{&1}") ++
        Enum.map(grant.file_env, &"the file $#{&1} names") ++
        ["#{Grant.token_file(grant)}"]

    git =
      case Grant.git_hosts(grant) do
        [] ->
          ""

        hosts ->
          " git over HTTPS to #{Enum.join(hosts, ", ")} gets it from MDT's credential helper."
      end

    "use: a placeholder is in #{Enum.join(holders, ", ")}. Send it as the tool normally sends " <>
      "this token, only to #{Enum.join(grant.hosts, ", ")}; MDT swaps in the real value there." <>
      git
  end

  def usage(%Grant{kind: :network} = grant),
    do: "use: connect directly to #{Enum.join(grant.destinations, ", ")}. Nothing to hold."

  def usage(%Grant{kind: :file} = grant),
    do: "use: the real value is the file #{grant.path} while the grant is on."

  defp approval(%Grant{kind: :file}), do: "uses: the file is readable while on"

  defp approval(%Grant{} = grant) do
    what = if grant.kind == :network, do: "connection", else: "request"

    cond do
      not Grant.on?(grant) ->
        "uses: each #{what} waits for the user's approval once on"

      Enum.any?(grant.allowances, &(&1.pattern == :all)) ->
        "uses: every #{what} goes through for now"

      true ->
        "uses: each #{what} waits for the user's approval (it can hang for minutes)"
    end
  end

  defp state(%Grant{state: :on, expires_at: %DateTime{} = at}, now) do
    minutes = max(div(DateTime.diff(at, now), 60), 0)
    "on until #{Calendar.strftime(at, "%H:%M")} UTC (#{minutes} min left)"
  end

  defp state(%Grant{state: :on}, _now), do: "on until the user turns it off"
  defp state(%Grant{}, _now), do: "off"

  defp one_line(text), do: text |> to_string() |> String.replace(~r/\s+/, " ") |> String.trim()
end
