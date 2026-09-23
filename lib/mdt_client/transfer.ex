defmodule MDTClient.Transfer do
  @moduledoc """
  Exports everything an identity keeps into one encrypted file, and imports
  such files back.

  The subsystem owns no data. Each system that does implements
  `MDTClient.Transfer.Participant` and is listed in `participants/0`; an
  export holds one section per participant, in the format
  `MDTClient.Transfer.Archive` describes.

  Importing takes two steps. `read/3` opens a file and prepares every section
  without touching anything, so a file that cannot be imported whole is
  refused before any data changes. `import/3` then hands each section to its
  participant in turn, to merge with what is there or to replace it; should
  one fail, the ones already written are put back as they were.
  `docs/transfer.md` covers the design.
  """

  require Logger

  alias MDTClient.Transfer.Archive
  alias MDTClient.Transfer.Plan
  alias MDTClient.Vault.Keyring

  @participants [MDTClient.HttpClient.Transfer]
  @extension ".mdtexport"

  @typedoc "How imported sections meet the data already there."
  @type mode :: :merge | :replace

  @type error ::
          :blank_password
          | Archive.error()
          | {:file, File.posix()}
          | {:export_failed, String.t(), term()}
          | {:newer_section, String.t()}
          | {:invalid_section, String.t(), term()}
          | {:import_failed, String.t(), term()}

  @doc "Every system whose data goes into an export, in the order they are imported."
  @spec participants() :: [module()]
  def participants, do: @participants

  @doc "The extension given to export files."
  @spec extension() :: String.t()
  def extension, do: @extension

  @doc """
  The file name an export of `username` made on `date` is offered under.

  It names the identity, since only that identity's password opens it.
  """
  @spec filename(String.t(), Date.t()) :: String.t()
  def filename(username, %Date{} = date) do
    # A username can hold anything; only characters safe in a file name stay.
    case username |> String.replace(~r/[^a-z0-9._@-]+/, "-") |> String.trim("-") do
      "" -> "mdt-export-#{date}#{@extension}"
      name -> "mdt-export-#{name}-#{date}#{@extension}"
    end
  end

  @doc """
  Writes everything `username` keeps to `path`.

  It is sealed under the identity's own key, through
  `MDTClient.Vault.Keyring`, so the identity opens it with nothing more, and
  its password opens it anywhere else.

  The file is written aside and renamed into place, so a failed export cannot
  destroy an earlier one at the same path.

  ## Options

    * `:participants` - the systems to export, `participants/0` by default
  """
  @spec export(String.t(), Path.t(), keyword()) :: :ok | {:error, error()}
  def export(username, path, opts \\ []) do
    participants = Keyword.get(opts, :participants, @participants)

    result =
      with {:ok, sections} <- export_sections(username, participants) do
        contents = %{
          created_at: DateTime.utc_now(),
          username: username,
          app_version: app_version(),
          sections: sections
        }

        archive = Archive.encode(contents, Keyring.kdf(username), &Keyring.seal(username, &1))
        write_file(path, archive)
      end

    log_result(:export, username, path, result)
    result
  end

  @doc """
  Opens the export at `path` and prepares it for `import/3`, changing nothing.

  By default it is opened with `username`'s own key, which works for a file
  that identity exported under its current password. Anything else — a file
  exported before a password change, or on another profile — needs the
  password it was made with, and without one it is refused as `:bad_password`.

  ## Options

    * `:password` - opens the file with this password instead
    * `:participants` - as for `export/3`
  """
  @spec read(String.t(), Path.t(), keyword()) :: {:ok, Plan.t()} | {:error, error()}
  def read(username, path, opts \\ []) do
    participants = Keyword.get(opts, :participants, @participants)

    result =
      with {:ok, opener} <- opener(username, Keyword.fetch(opts, :password)),
           {:ok, binary} <- read_file(path),
           {:ok, contents} <- Archive.decode(binary, opener),
           {:ok, contents} <- check_contents(contents) do
        plan(contents, participants)
      end

    log_result(:read, username, path, result)
    result
  end

  @doc """
  Writes the sections of a file `read/3` opened into what `username` keeps.

  With `:merge`, each participant combines its section with what is there,
  losing nothing; with `:replace`, the section takes the place of what is
  there. Participants the file holds no section for are left alone either way.
  """
  @spec import(String.t(), Plan.t(), mode()) :: :ok | {:error, error()}
  def import(username, %Plan{sections: sections}, mode) when mode in [:merge, :replace] do
    result = import_sections(username, sections, mode, [])
    log_result(:import, username, mode, result)
    result
  end

  defp log_result(operation, username, subject, result) do
    metadata = [user: username, system: :transfer]

    case result do
      :ok ->
        Logger.info("#{operation} completed subject=#{inspect(subject)}", metadata)

      {:ok, _plan} ->
        Logger.info("#{operation} completed subject=#{inspect(subject)}", metadata)

      {:error, reason} ->
        Logger.warning(
          "#{operation} failed subject=#{inspect(subject)} reason=#{inspect(reason)}",
          metadata
        )
    end
  end

  defp opener(username, :error), do: {:ok, {:open, &Keyring.open(username, &1)}}

  defp opener(_username, {:ok, password}) when is_binary(password) and password != "",
    do: {:ok, {:password, password}}

  defp opener(_username, {:ok, _blank}), do: {:error, :blank_password}

  defp export_sections(username, participants) do
    Enum.reduce_while(participants, {:ok, %{}}, fn participant, {:ok, sections} ->
      case call(fn -> participant.export(username) end) do
        {:ok, data} ->
          section = %{version: participant.version(), data: data}
          {:cont, {:ok, Map.put(sections, participant.key(), section)}}

        {:error, reason} ->
          {:halt, {:error, {:export_failed, participant.label(), reason}}}
      end
    end)
  end

  defp check_contents(
         %{created_at: %DateTime{}, username: username, app_version: version, sections: sections} =
           contents
       )
       when is_binary(username) and is_binary(version) and is_map(sections) do
    if Enum.all?(sections, &section?/1), do: {:ok, contents}, else: {:error, :damaged}
  end

  defp check_contents(_contents), do: {:error, :damaged}

  defp section?({key, %{version: version, data: _data}})
       when is_binary(key) and is_integer(version) and version > 0,
       do: true

  defp section?(_section), do: false

  defp plan(contents, participants) do
    prepared =
      Enum.reduce_while(participants, {:ok, []}, fn participant, {:ok, sections} ->
        case Map.fetch(contents.sections, participant.key()) do
          {:ok, section} ->
            case prepare(participant, section) do
              {:ok, section} -> {:cont, {:ok, [section | sections]}}
              {:error, reason} -> {:halt, {:error, reason}}
            end

          :error ->
            {:cont, {:ok, sections}}
        end
      end)

    with {:ok, sections} <- prepared do
      known = MapSet.new(participants, & &1.key())

      {:ok,
       %Plan{
         created_at: contents.created_at,
         username: contents.username,
         app_version: contents.app_version,
         sections: Enum.reverse(sections),
         skipped: contents.sections |> Map.keys() |> Enum.reject(&(&1 in known)) |> Enum.sort()
       }}
    end
  end

  defp prepare(participant, %{version: version, data: data}) do
    label = participant.label()

    if version > participant.version() do
      {:error, {:newer_section, label}}
    else
      case call(fn -> participant.prepare(version, data) end) do
        {:ok, prepared} ->
          {:ok,
           %{
             participant: participant,
             key: participant.key(),
             label: label,
             summary: participant.describe(prepared),
             data: prepared
           }}

        {:error, reason} ->
          {:error, {:invalid_section, label, reason}}
      end
    end
  end

  defp import_sections(_username, [], _mode, _written), do: :ok

  defp import_sections(username, [section | rest], mode, written) do
    # The last section needs no copy to go back to: nothing after it can fail.
    with {:ok, previous} <- if(rest == [], do: {:ok, nil}, else: snapshot(username, section)),
         :ok <- call(fn -> write(section, username, mode) end) do
      import_sections(username, rest, mode, [{section, previous} | written])
    else
      {:error, reason} ->
        roll_back(username, written)
        {:error, {:import_failed, section.label, reason}}
    end
  end

  defp write(%{participant: participant, data: data}, username, :merge),
    do: participant.merge(username, data)

  defp write(%{participant: participant, data: data}, username, :replace),
    do: participant.replace(username, data)

  # What a participant holds right now, in the shape `replace/2` takes, so a
  # failed import can put it back whichever way the section went in.
  defp snapshot(username, %{participant: participant}) do
    with {:ok, data} <- call(fn -> participant.export(username) end) do
      call(fn -> participant.prepare(participant.version(), data) end)
    end
  end

  # Newest first, so sections go back in the reverse of the order they came in.
  defp roll_back(username, written) do
    Enum.each(written, fn {section, previous} ->
      case call(fn -> section.participant.replace(username, previous) end) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error(
            "could not put #{section.label} back after a failed import: #{inspect(reason)}",
            system: :transfer
          )
      end
    end)
  end

  # A participant that raises or exits counts as one that returned an error.
  # Crashing out instead would skip putting back what was already written.
  defp call(fun) do
    fun.()
  rescue
    exception ->
      Logger.error(Exception.format(:error, exception, __STACKTRACE__), system: :transfer)
      {:error, exception}
  catch
    :exit, reason ->
      Logger.error("transfer participant exited: #{Exception.format_exit(reason)}",
        system: :transfer
      )

      {:error, {:exit, reason}}
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, binary} -> {:ok, binary}
      {:error, reason} -> {:error, {:file, reason}}
    end
  end

  defp write_file(path, binary) do
    partial = "#{path}.#{System.unique_integer([:positive])}.part"

    with :ok <- File.write(partial, binary),
         :ok <- File.rename(partial, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(partial)
        {:error, {:file, reason}}
    end
  end

  defp app_version, do: :mdt_client |> Application.spec(:vsn) |> to_string()
end
