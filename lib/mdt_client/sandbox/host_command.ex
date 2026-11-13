defmodule MDTClient.Sandbox.HostCommand do
  @moduledoc """
  What an agent asked to run on the host, checked and described for its
  approval card. It decides nothing and runs nothing: `MDTClient.Sandbox.HostRun`
  runs a command once you approve it.

  An ask names the script (its full text: what you read is what runs), the
  directory, the time limit and the agent's reason. `check/3`:

    * refuses an ask with no reason, no script, a script over 16 KiB, or a
      time limit outside 1 to 3600 seconds;
    * works out **where it runs**. Shared folders sit at the same path on
      both sides, so a directory inside one runs there, once its symlinks are
      resolved on the host. Any other directory, or one whose real path
      leaves its share, falls back to your home folder;
    * gathers **facts** (who it runs as, where, for how long) and **hints**:
      guesses from the script's text about what deserves a second look, such
      as running build tools in a folder the VM can write. Hints are never a
      review: a script can do anything its text allows.

  Pure apart from reading the filesystem to resolve the directory.
  """

  alias MDTClient.Sandbox.{Grant, Share, Shares}

  @max_script 16 * 1024
  @default_timeout 120
  @max_timeout 3600

  # Commands that run code from the folder they work in: build files,
  # package scripts, git hooks and the like.
  @runs_project_code ~w(make mix npm npx pnpm yarn bun cargo go python python3 pip pip3
    uv node deno ruby bundle rake gradle gradlew mvn git elixir iex rebar3 pytest tox just
    docker podman composer php perl cmake ninja bazel terraform direnv mise asdf)

  # Tools a preset's grant already covers, so the card can say so.
  @preset_tools %{
    github: ~w(gh),
    google: ~w(gcloud gsutil bq),
    hex: ["mix hex"]
  }

  @type ask :: %{
          optional(:script) => term(),
          optional(:dir) => term(),
          optional(:timeout) => term(),
          optional(:reason) => term(),
          optional(:agent) => term()
        }

  @type checked :: %{
          script: String.t(),
          dir: String.t(),
          timeout: pos_integer(),
          reason: String.t(),
          agent: String.t(),
          title: String.t(),
          pattern: String.t(),
          facts: [{String.t(), String.t()}],
          hints: [String.t()]
        }

  @type error :: :no_reason | :no_script | :script_too_long | :bad_timeout

  @doc "The longest script an ask may carry, in bytes."
  @spec max_script() :: pos_integer()
  def max_script, do: @max_script

  @doc "The time limit when an ask names none, and the longest one allowed, in seconds."
  @spec timeouts() :: {pos_integer(), pos_integer()}
  def timeouts, do: {@default_timeout, @max_timeout}

  @doc """
  Checks an ask and describes it.

  ## Options

    * `:home` - where a command runs when its directory isn't shared,
      defaults to the user's home folder
    * `:user` - who it runs as, for the card, defaults to MDT's own user
  """
  @spec check(ask(), [Share.t()], [Grant.t()], keyword()) :: {:ok, checked()} | {:error, error()}
  def check(ask, shares, grants, opts \\ []) do
    home = Keyword.get_lazy(opts, :home, &System.user_home!/0)
    user = Keyword.get_lazy(opts, :user, &MDTClient.Sandbox.HostInfo.user/0)
    reason = ask |> Map.get(:reason) |> text() |> String.trim() |> String.slice(0, 1_000)
    agent = ask |> Map.get(:agent) |> text() |> String.trim() |> String.slice(0, 60)
    script = ask |> Map.get(:script) |> text() |> String.replace("\r\n", "\n")
    timeout = Map.get(ask, :timeout) || @default_timeout

    cond do
      reason == "" ->
        {:error, :no_reason}

      String.trim(script) == "" ->
        {:error, :no_script}

      byte_size(script) > @max_script ->
        {:error, :script_too_long}

      not (is_integer(timeout) and timeout in 1..@max_timeout) ->
        {:error, :bad_timeout}

      true ->
        asked = ask |> Map.get(:dir) |> text() |> String.trim()
        place = place(asked, shares, home)
        dir = elem(place, 1)

        {:ok,
         %{
           script: script,
           dir: dir,
           timeout: timeout,
           reason: reason,
           agent: if(agent == "", do: "An agent", else: agent),
           title: title(script),
           pattern: "run " <> Integer.to_string(:erlang.phash2({script, dir, timeout}), 36),
           facts: [
             {"Runs as", "#{user}, on this machine, outside the VM"},
             {"In", dir},
             {"Where that is", where(place, asked)},
             {"Time limit", seconds_words(timeout)}
           ],
           hints: hints(script, place, shares, grants)
         }}
    end
  end

  @doc """
  Where a command asked to run in `asked` runs: `{:share, dir, share}` when
  the directory's real path is inside a shared folder and exists, otherwise
  `{:home, home}`.
  """
  @spec place(String.t(), [Share.t()], String.t()) ::
          {:share, String.t(), Share.t()} | {:home, String.t()}
  def place(asked, shares, home) do
    with "/" <> _ <- asked,
         {:ok, real} <- Shares.realpath(Path.expand(asked)),
         %Share{} = share <- Enum.find(shares, &Shares.within?(real, &1.path)),
         true <- File.dir?(real) do
      {:share, real, share}
    else
      _ -> {:home, home}
    end
  end

  @doc """
  What deserves a second look in `script`, run at `place`, worked out from
  its text alone.
  """
  @spec hints(String.t(), {:share, String.t(), Share.t()} | {:home, String.t()}, [Share.t()], [
          Grant.t()
        ]) :: [String.t()]
  def hints(script, place, shares, grants) do
    writable = for %Share{mode: :rw} = share <- shares, do: share.path
    named = Enum.filter(writable, &String.contains?(script, &1))

    in_writable =
      case place do
        {:share, _dir, %Share{mode: :rw, path: path}} -> [path]
        _ -> []
      end

    commands = commands(script)
    tools = commands |> Enum.map(&hd/1) |> Enum.filter(&(&1 in @runs_project_code)) |> Enum.uniq()
    where = Enum.uniq(in_writable ++ named)

    [
      (tools != [] and where != []) &&
        "Runs #{Enum.join(tools, ", ")} with files the VM can write " <>
          "(#{Enum.join(where, ", ")}): their build files, scripts and git hooks run as you.",
      named != [] &&
        "Names files in #{Enum.join(named, ", ")}, which the VM can change before it runs.",
      Enum.any?(commands, &script_file?/1) &&
        "Runs a script file. What runs is the file as it is then, which this card doesn't show.",
      Regex.match?(
        ~r/\b(curl|wget)\b[^\n|]*\|\s*(sudo\s+)?(bash|sh|zsh|dash|python3?|node|perl|ruby)\b/,
        script
      ) && "Downloads code and runs it.",
      Enum.any?(commands, &(hd(&1) == "sudo")) && "Asks for root with sudo.",
      Enum.any?(commands, &rm_rf?/1) && "Deletes files recursively without asking (rm -rf)."
    ]
    |> Enum.concat(covered(commands, script, grants))
    |> Enum.filter(&is_binary/1)
  end

  @doc """
  The commands a script runs, roughly: each one's words, split at newlines,
  `;`, `&&`, `||`, pipes and subshells, without leading variable assignments
  or wrappers such as `env`, `exec` or `time`. The first word is the
  command's name without its directory, unless it is a path to a script
  (`./x.sh`). Quotes are not parsed: this is for hints, not for deciding.
  """
  @spec commands(String.t()) :: [[String.t(), ...]]
  def commands(script) do
    script
    |> String.split(~r/\n|;|&&|\|\||\||\$\(|`|\(|\)/)
    |> Enum.map(&String.split/1)
    |> Enum.map(&drop_prefixes/1)
    |> Enum.reject(&(&1 == []))
    |> Enum.map(fn [name | args] -> [command_name(name) | args] end)
  end

  @wrappers ~w(env exec time nohup nice xargs command builtin then do else elif if while until !)

  defp drop_prefixes([word | rest] = words) do
    cond do
      word in @wrappers -> drop_prefixes(rest)
      Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*=/, word) -> drop_prefixes(rest)
      String.starts_with?(word, "#") -> []
      true -> words
    end
  end

  defp drop_prefixes([]), do: []

  defp command_name("./" <> _ = path), do: path
  defp command_name("../" <> _ = path), do: path
  defp command_name(name), do: Path.basename(name)

  defp script_file?(["sudo" | rest]) when rest != [], do: script_file?(drop_prefixes(rest))
  defp script_file?(["." <> _ = name | _]) when name not in [".", ".."], do: true
  defp script_file?([name, file | _]) when name in ["source", "."], do: file != ""

  defp script_file?([shell | args]) when shell in ~w(sh bash zsh dash) do
    case Enum.drop_while(args, &(String.starts_with?(&1, "-") and not String.contains?(&1, "c"))) do
      [] -> false
      ["-" <> _ | _] -> false
      [_file | _] -> true
    end
  end

  defp script_file?(_command), do: false

  defp rm_rf?(["rm" | args]) do
    flags = args |> Enum.filter(&String.starts_with?(&1, "-")) |> Enum.join()
    String.contains?(flags, "r") or String.contains?(flags, "R")
  end

  defp rm_rf?(["sudo" | rest]), do: rm_rf?(drop_prefixes(rest))
  defp rm_rf?(_command), do: false

  @doc "A command's title: its first line, shortened."
  @spec title(String.t()) :: String.t()
  def title(script) do
    first =
      script
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.find("", &(&1 != "" and not String.starts_with?(&1, "#")))

    lines = script |> String.trim() |> String.split("\n") |> length()
    first = if String.length(first) > 80, do: String.slice(first, 0, 79) <> "…", else: first
    if lines > 1, do: first <> " (+#{lines - 1} lines)", else: first
  end

  @doc "A duration in seconds, in words."
  @spec seconds_words(non_neg_integer()) :: String.t()
  def seconds_words(seconds) when seconds < 60, do: "#{seconds} s"
  def seconds_words(seconds) when rem(seconds, 60) == 0, do: "#{div(seconds, 60)} min"
  def seconds_words(seconds), do: "#{div(seconds, 60)} min #{rem(seconds, 60)} s"

  defp where({:share, _dir, %Share{mode: :rw, path: path}}, _asked),
    do: "Inside #{path}, shared with the VM read-write: the VM can change what's there."

  defp where({:share, _dir, %Share{mode: :ro, path: path}}, _asked),
    do: "Inside #{path}, shared with the VM read-only."

  defp where({:home, _home}, ""), do: "Your home folder: the ask named no directory."

  defp where({:home, _home}, asked),
    do: "Your home folder: #{asked} isn't inside a shared folder on this machine."

  defp covered(commands, script, grants) do
    for %Grant{kind: :token} = grant <- grants,
        what = covered_by(commands, script, grant),
        what != [] do
      "#{grant.name} already covers this (#{Enum.join(what, ", ")}). From the VM, through the grant, you'd see each request it makes."
    end
  end

  defp covered_by(commands, script, grant) do
    hosts =
      for host <- grant.hosts,
          bare = String.replace_prefix(host, "*.", ""),
          String.contains?(script, bare),
          do: bare

    tools =
      for tool <- Map.get(@preset_tools, grant.preset, []),
          words = String.split(tool),
          Enum.any?(commands, &(Enum.take(&1, length(words)) == words)),
          do: tool

    Enum.uniq(tools ++ hosts)
  end

  defp text(value) when is_binary(value), do: value
  defp text(value) when is_number(value), do: to_string(value)
  defp text(_other), do: ""
end
