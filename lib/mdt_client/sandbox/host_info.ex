defmodule MDTClient.Sandbox.HostInfo do
  @moduledoc """
  What agents in the VM are told about your machine, so they can write a
  command that runs on it (`mdt run`): OS, architecture, kernel, login
  shell, home folder, the shared folders, which command-line tools your
  login shell finds, and your own notes. `mdt host` prints it, and
  `/mnt/mdt/host.md` holds it.

  `facts/0` reads what the BEAM and `/etc/os-release` already know.
  `probe_tools/0` asks your login shell where each tool of a fixed list is
  and which version it is; it runs `TOOL --version` (or the tool's own
  equivalent) for each, so MDT does it in the background when it unlocks,
  and when you ask from Settings. Agents never probe the host themselves.
  """

  alias MDTClient.Sandbox.{HostRun, Ports, Share}

  # Name, then the arguments that print its version.
  @tools [
    {"git", ["--version"]},
    {"gh", ["--version"]},
    {"ssh", ["-V"]},
    {"scp", nil},
    {"rsync", ["--version"]},
    {"curl", ["--version"]},
    {"gpg", ["--version"]},
    {"sops", ["--version"]},
    {"age", ["--version"]},
    {"op", ["--version"]},
    {"gcloud", ["--version"]},
    {"gsutil", ["version"]},
    {"bq", ["version"]},
    {"aws", ["--version"]},
    {"az", ["version", "-o", "tsv"]},
    {"kubectl", ["version", "--client"]},
    {"helm", ["version", "--short"]},
    {"terraform", ["version"]},
    {"pulumi", ["version"]},
    {"cloud-sql-proxy", ["--version"]},
    {"docker", ["--version"]},
    {"podman", ["--version"]},
    {"msb", ["--version"]},
    {"psql", ["--version"]},
    {"mysql", ["--version"]},
    {"sqlite3", ["--version"]},
    {"redis-cli", ["--version"]},
    {"mise", ["--version"]},
    {"asdf", ["--version"]},
    {"elixir", ["--short-version"]},
    {"node", ["--version"]},
    {"python3", ["--version"]},
    {"go", ["version"]},
    {"cargo", ["--version"]},
    {"java", ["-version"]},
    {"make", ["--version"]},
    {"jq", ["--version"]},
    {"openvpn3", ["version"]},
    {"tailscale", ["version"]},
    {"nmcli", ["--version"]},
    {"flatpak", ["--version"]},
    {"zed", ["--version"]}
  ]

  @type facts :: %{
          os: String.t(),
          kernel: String.t(),
          arch: String.t(),
          user: String.t(),
          home: String.t(),
          shell: String.t()
        }

  @type tool :: %{name: String.t(), path: String.t(), version: String.t() | nil}

  @doc "The names of the tools `probe_tools/0` looks for."
  @spec tool_names() :: [String.t()]
  def tool_names, do: Enum.map(@tools, &elem(&1, 0))

  @doc "What is known about this machine without running anything."
  @spec facts() :: facts()
  def facts do
    {family, name} = :os.type()

    kernel =
      case :os.version() do
        {major, minor, patch} ->
          "#{name |> to_string() |> String.capitalize()} #{major}.#{minor}.#{patch}"

        other ->
          "#{name} #{other}"
      end

    %{
      os: os_name() || "#{family}/#{name}",
      kernel: kernel,
      arch: :erlang.system_info(:system_architecture) |> to_string(),
      user: user(),
      home: System.user_home() || "unknown",
      shell: System.get_env("SHELL", "/bin/sh")
    }
  end

  @doc """
  Which tools your login shell finds, with their versions, in one `bash -lc`
  so the `PATH` is the one commands get. Each version check has 5 seconds.
  """
  @spec probe_tools() :: [tool()]
  def probe_tools do
    checks =
      Enum.map_join(@tools, "\n", fn {name, args} ->
        version =
          if args,
            do:
              "timeout 5 \"$p\" #{Enum.map_join(args, " ", &shell_quote/1)} </dev/null 2>&1 | grep -v -i 'warning' | grep -m1 -v '^[[:space:]]*$' | cut -c1-120",
            else: "true"

        "(p=$(type -P #{shell_quote(name)} 2>/dev/null) && v=$(#{version}); [ -n \"$p\" ] && printf '%s\\t%s\\t%s\\n' #{shell_quote(name)} \"$p\" \"$v\") &"
      end)

    script = checks <> "\nwait\n"

    case System.cmd("timeout", ["30", "bash", "-lc", script],
           stderr_to_stdout: false,
           env: HostRun.home_env()
         ) do
      {output, _status} ->
        found =
          for line <- String.split(output, "\n", trim: true),
              [name, path, version] <- [String.split(line, "\t", parts: 3)],
              into: %{},
              do: {name, %{name: name, path: path, version: blank_to_nil(version)}}

        for name <- tool_names(), tool = found[name], do: tool
    end
  rescue
    _ -> []
  end

  @doc """
  The description agents read, as Markdown. `tools` is `nil` until probed;
  `notes` is your own text from Settings; `address` is the VM's address on
  this machine, where its ports show up (`MDTClient.Sandbox.Ports`).
  """
  @spec text(facts(), [tool()] | nil, [Share.t()], String.t() | nil, String.t() | nil) ::
          String.t()
  def text(facts, tools, shares, notes, address \\ nil) do
    """
    # The user's machine

    Commands you run with `mdt run` run here, as #{facts.user}, after the user approves each one. Written by MDT; don't probe the machine with commands to find this out.

    - OS: #{facts.os}, #{facts.kernel}
    - Architecture: #{facts.arch}
    - User: #{facts.user}, home folder #{facts.home}
    - Login shell: #{facts.shell}. Commands run with `bash -lc`, so the user's login profile sets PATH.

    ## Shared folders

    #{shares_text(shares)}

    ## Command-line tools

    #{tools_text(tools)}
    #{ports_text(address)}
    #{notes_text(notes)}
    """
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim_trailing()
    |> Kernel.<>("\n")
  end

  defp shares_text([]),
    do:
      "None. Every command runs in the user's home folder, which the VM doesn't see. Get files back through the output."

  defp shares_text(shares) do
    lines =
      Enum.map_join(shares, "\n", fn %Share{path: path, mode: mode} ->
        "- #{path} (#{if mode == :rw, do: "read-write", else: "read-only"} in the VM)"
      end)

    "The same path on both sides. A command whose --dir is inside one runs there, so it can read your files and leave results for you; any other command runs in the home folder.\n\n" <>
      lines
  end

  defp tools_text(nil), do: "Not checked yet."

  defp tools_text(tools) do
    found =
      Enum.map_join(tools, "\n", fn tool ->
        "- #{tool.name}: #{tool.version || "found"} (#{tool.path})"
      end)

    names = MapSet.new(tools, & &1.name)
    missing = Enum.reject(tool_names(), &MapSet.member?(names, &1))

    """
    Found on the login shell's PATH:

    #{if found == "", do: "- none of those MDT looks for", else: found}

    Not found: #{if missing == [], do: "none", else: Enum.join(missing, ", ")}. MDT looks only for these; others may exist.
    """
  end

  defp ports_text(nil), do: ""

  defp ports_text(address) do
    """

    ## Servers you start

    A server you start in the VM shows up on this machine at #{address}, on the same port, within a few seconds: give the user http://#{address}:PORT. Listening on 127.0.0.1 or 0.0.0.0 both work; ports below #{Ports.unprivileged_start()} aren't forwarded. `mdt ports` lists what is forwarded now.
    """
  end

  defp notes_text(notes) do
    case String.trim(notes || "") do
      "" -> ""
      notes -> "\n## The user's notes\n\n" <> notes <> "\n"
    end
  end

  @doc "Who MDT runs as, so who host commands run as."
  @spec user() :: String.t()
  def user do
    System.get_env("USER") || System.get_env("LOGNAME") ||
      if(home = System.user_home(), do: Path.basename(home), else: "unknown")
  end

  defp os_name do
    with {:ok, text} <- File.read("/etc/os-release"),
         [_, name] <- Regex.run(~r/^PRETTY_NAME="?([^"\n]*)"?$/m, text) do
      name
    else
      _ -> nil
    end
  end

  defp shell_quote(word), do: "'" <> String.replace(word, "'", "'\\''") <> "'"

  defp blank_to_nil(text) do
    case String.trim(text) do
      "" -> nil
      text -> text
    end
  end
end
