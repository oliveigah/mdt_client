defmodule MDTClient.Sandbox.Server.Grants do
  @moduledoc """
  The grants in the sandbox server's state: building one from a form and
  saying what is wrong with it, turning one on, adding an allowance, and
  turning off the ones whose time ran out.

  Runs in the server's process (`MDTClient.Sandbox.Server.State`).
  """

  alias MDTClient.Sandbox.{Allowance, Approval, Destinations, Grant, HostCommand, Presets, Shown}
  alias MDTClient.Sandbox.Server.{Approvals, State}

  @doc """
  Adds an allowance to an on grant, and lets through every use waiting on
  it that the allowance covers.
  """
  def allow(state, grant, pattern, duration) do
    allowance = %Allowance{
      id: "allowance-" <> State.unique(),
      pattern: pattern,
      until:
        if(duration == :grant, do: nil, else: DateTime.add(State.now(), duration * 60, :second))
    }

    if allowance.until,
      do: State.timer({:expire_allowance, grant.id, allowance.id}, allowance.until)

    state =
      state.approvals
      |> Enum.filter(fn other ->
        other.status == :waiting and other.grant_id == grant.id and Approval.use?(other) and
          Allowance.covers?(allowance, other.pattern)
      end)
      |> Enum.reduce(state, fn other, acc ->
        how = if pattern == :all, do: "every use", else: "similar"

        acc
        |> Approvals.settle(
          other,
          :allowed,
          {:allow, if(pattern == :all, do: :all, else: :similar), duration}
        )
        |> Approvals.answer_waiters(other, :allow)
        |> State.log(
          Approvals.event_for(
            other,
            :allowed,
            "you allowed #{how} #{State.duration_words(duration)}"
          )
        )
      end)

    grant = Enum.find(state.grants, &(&1.id == grant.id))

    state
    |> State.replace_grant(%{grant | allowances: grant.allowances ++ [allowance]})
    |> State.changed()
  end

  @doc """
  Turns a grant on for `minutes` (or `:until_off`); `:all` also lets every
  use through for as long as it stays on.
  """
  def turn_on(state, nil, _minutes, _uses, _why), do: state

  def turn_on(state, grant, minutes, uses, why) do
    # No allowance ever covers a command: each run waits for you.
    uses = if grant.kind == :command, do: :ask, else: uses

    expires_at =
      if minutes == :until_off, do: nil, else: DateTime.add(State.now(), minutes * 60, :second)

    grant = %{grant | state: :on, expires_at: expires_at}
    State.schedule_expiry(grant)

    state =
      state
      |> State.replace_grant(grant)
      |> State.log(%{
        outcome: :grant,
        summary:
          "#{grant.name} turned on #{State.duration_words(minutes)}" <>
            if(uses == :all, do: ", every use allowed", else: "") <> why,
        grant_id: grant.id
      })
      |> State.write_inbox()
      |> State.changed()

    if uses == :all, do: allow(state, grant, :all, :grant), else: state
  end

  @doc """
  Applies `fun` to the grant with this id and answers the caller with the result; turning it off this way denies what waited on it.
  """
  def with_grant(state, id, fun) do
    case Enum.find(state.grants, &(&1.id == id)) do
      nil ->
        {:reply, {:error, :not_found}, state}

      grant ->
        {updated, summary} = fun.(grant)

        state =
          if grant.state == :on and updated.state == :off,
            do: Approvals.settle_waiting(state, id, :grant_off),
            else: state

        state = State.replace_grant(state, updated)

        state =
          if summary,
            do: State.log(state, %{outcome: :grant, summary: summary, grant_id: id}),
            else: state

        {:reply, {:ok, updated}, state |> State.write_inbox() |> State.changed()}
    end
  end

  @doc """
  A grant from a form's fields, with its real value when the form carried one, or the errors by field.
  """
  def build_grant(attrs, existing) do
    kind = Enum.find(Grant.kinds(), &(Atom.to_string(&1) == attrs["kind"]))

    preset =
      case Presets.find(attrs["preset"] || "") do
        {:ok, %{id: id}} when id not in [:token, :network, :file, :command] -> id
        _none -> nil
      end

    if is_nil(kind) do
      {:error, %{kind: "Pick what kind of access this is."}}
    else
      name = String.trim(attrs["name"] || "")
      purpose = String.trim(attrs["purpose"] || "")
      minted? = kind == :token and attrs["source"] == "minted"
      {destinations, destination_error} = destinations(attrs["destinations"], kind)

      grant = %Grant{
        id: grant_id(name, existing),
        name: name,
        kind: kind,
        preset: preset,
        purpose: purpose,
        placeholder: if(kind == :token, do: placeholder(attrs["prefix"])),
        env: if(kind == :token, do: list(attrs["env"]), else: []),
        file_env: if(kind == :token, do: list(attrs["file_env"]), else: []),
        git: kind == :token and attrs["git"] in ["true", "on"],
        hosts:
          if(kind == :token, do: Enum.map(list(attrs["hosts"]), &String.downcase/1), else: []),
        destinations: destinations,
        path: if(kind == :file, do: "/mnt/mdt/files/" <> String.trim(attrs["path"] || "")),
        script: if(kind == :command, do: command_script(attrs["script"])),
        dir: if(kind == :command, do: command_dir(attrs["dir"])),
        source: if(minted?, do: {:minted, String.trim(attrs["mint"] || "")}, else: :stored)
      }

      case grant_errors(grant, attrs, destination_error) do
        errors when errors == %{} ->
          {:ok, grant,
           if(minted? or kind in [:network, :command],
             do: nil,
             else: blank_to_nil(State.opened(attrs["value"]))
           )}

        errors ->
          {:error, errors}
      end
    end
  end

  # A command grant's own script: nil when agents write the text.
  defp command_script(text) do
    case text |> State.to_text() |> String.replace("\r\n", "\n") |> String.trim() do
      "" -> nil
      script -> script
    end
  end

  # The folder a script of yours runs in, as a real path; your home folder
  # when you named none.
  defp command_dir(text) do
    case text |> State.to_text() |> String.trim() do
      "" -> nil
      dir -> Path.expand(dir)
    end
  end

  @variable ~r/^[A-Za-z_][A-Za-z0-9_]*$/
  @host ~r/^(\*\.)?[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$/
  @prefix ~r/^[A-Za-z0-9_.\-]{0,24}$/

  defp grant_errors(%Grant{} = grant, attrs, destination_error) do
    token? = grant.kind == :token
    variables = grant.env ++ grant.file_env

    [
      {:name, grant.name == "", "Give it a name you'll recognise on an approval."},
      {:purpose, grant.purpose == "",
       "Say what it's for. Agents in the VM read this to find the grant they need."},
      {:hosts, token? and grant.hosts == [], "List at least one host the value may go to."},
      {:hosts, token? and not Enum.all?(grant.hosts, &Regex.match?(@host, &1)),
       "Hosts are names like api.example.com, or *.example.com for its subdomains."},
      {:env, token? and not Enum.all?(variables, &Regex.match?(@variable, &1)),
       "Variable names are letters, digits and underscores, not starting with a digit."},
      {:prefix, token? and not Regex.match?(@prefix, String.trim(attrs["prefix"] || "")),
       "Up to 24 letters, digits, dots, dashes or underscores."},
      {:destinations, grant.kind == :network and destination_error != nil, destination_error},
      {:path, grant.kind == :file and not valid_file_name?(attrs["path"]),
       "Name the file, such as kubeconfig. It appears under /mnt/mdt/files/."},
      {:mint, match?({:minted, ""}, grant.source),
       "Enter the command that prints a short-lived token."},
      {:script,
       grant.kind == :command and byte_size(grant.script || "") > HostCommand.max_script(),
       "The script is over #{div(HostCommand.max_script(), 1024)} KiB."},
      {:script, grant.kind == :command and Shown.hidden(grant.script || "") != [],
       "The script has characters that don't show " <>
         "(#{Enum.join(Shown.hidden(grant.script || ""), ", ")}). Paste it without them."},
      {:dir, grant.kind == :command and grant.script != nil and is_nil(grant.dir),
       "Say which folder your script runs in."},
      {:dir, grant.kind == :command and grant.dir != nil and not File.dir?(grant.dir),
       "That folder does not exist on this machine."},
      {:value,
       grant.kind in [:token, :file] and grant.source == :stored and
         blank_to_nil(State.opened(attrs["value"])) == nil,
       "Paste the value. It is kept in your vault, never in the VM."}
    ]
    |> Enum.filter(fn {_field, failed?, _message} -> failed? end)
    |> Enum.reverse()
    |> Map.new(fn {field, _failed?, message} -> {field, message} end)
  end

  defp destinations(text, kind) do
    entries = list(text)

    cond do
      kind != :network ->
        {[], nil}

      entries == [] ->
        {[], "List at least one host, address or range."}

      true ->
        case Destinations.parse_all(entries) do
          {:ok, _specs} -> {entries, nil}
          {:error, message} -> {entries, message}
        end
    end
  end

  defp valid_file_name?(name) do
    name = String.trim(name || "")
    name != "" and Path.basename(name) == name and name not in [".", ".."]
  end

  # Placeholders look like the real thing where a client checks the format
  # (`ghp_` for GitHub), and are long and random, so finding one in a header
  # is unambiguous.
  defp placeholder(prefix) do
    prefix = String.trim(prefix || "")
    prefix = if prefix == "", do: "mdt_", else: prefix
    alphabet = ~c"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    bytes = :crypto.strong_rand_bytes(40)
    prefix <> for(<<byte <- bytes>>, into: "", do: <<Enum.at(alphabet, rem(byte, 62))>>)
  end

  defp list(nil), do: []

  defp list(value) do
    value
    |> String.split([",", "\n"])
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    case String.trim(value) do
      "" -> nil
      _ -> value
    end
  end

  defp grant_id(name, existing) do
    base =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> case do
        "" -> "grant"
        slug -> slug
      end

    if Enum.any?(existing, &(&1.id == base)), do: base <> "-" <> State.unique(), else: base
  end

  @doc """
  Turns off every grant whose time ran out and drops every allowance past
  its end, by the clock.
  """
  def sweep(state) do
    at = DateTime.utc_now()

    Enum.reduce(state.grants, state, fn grant, state ->
      ended = Enum.filter(grant.allowances, &Allowance.ended?(&1, at))

      cond do
        grant.state == :on and not Grant.on?(grant, at) ->
          state
          |> Approvals.settle_waiting(grant.id, :grant_off)
          |> State.replace_grant(%{grant | state: :off, expires_at: nil, allowances: []})
          |> State.log(%{
            outcome: :grant,
            summary: "#{grant.name} turned off: its time ran out",
            grant_id: grant.id
          })
          |> State.write_inbox()
          |> State.changed()

        ended != [] ->
          state
          |> State.replace_grant(%{grant | allowances: grant.allowances -- ended})
          |> State.changed()

        true ->
          state
      end
    end)
  end
end
