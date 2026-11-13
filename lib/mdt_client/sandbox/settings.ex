defmodule MDTClient.Sandbox.Settings do
  @moduledoc """
  How the VM is built. Changing the image, resources or shared folders of a VM
  that exists means recreating it: microsandbox cannot change mounts live.
  `image_name` only names the next build. `host_notes` is your own text
  about this machine, which agents read with the rest of `mdt host`.

  Disk comes in three kinds, all sparse images that take host space only as
  they fill. `disk_gib` sizes the VM's root disk, which starts empty on
  every recreate. `home_gib`, `cache_gib` and `work_gib` size the disks the
  VM keeps (`MDTClient.Sandbox.Disks`); making one bigger applies at the
  next start, and none is ever made smaller. `write_budget_gib` is how much
  the VM may add to each folder it mounts read-write (its memory, your
  shares) per boot; it keeps a runaway agent from filling your disk.
  microsandbox's own default is 4 GiB for the root disk and the budget.

  `desktop_notifications` puts each approval waiting for you on the
  desktop.
  """

  alias MDTClient.Sandbox.{Image, Share}

  defstruct containerfile: nil,
            image_name: "mdt_agent_sdb_image",
            cpus: 4,
            memory_gib: 8,
            disk_gib: 64,
            write_budget_gib: 64,
            home_gib: 16,
            cache_gib: 64,
            work_gib: 64,
            hold_seconds: 180,
            shares: [],
            projects: [],
            optmem_path: nil,
            host_notes: "",
            desktop_notifications: true

  @type t :: %__MODULE__{
          containerfile: String.t() | nil,
          image_name: String.t(),
          cpus: pos_integer(),
          memory_gib: pos_integer(),
          disk_gib: pos_integer(),
          write_budget_gib: pos_integer(),
          home_gib: pos_integer(),
          cache_gib: pos_integer(),
          work_gib: pos_integer(),
          hold_seconds: pos_integer(),
          shares: [Share.t()],
          projects: [MDTClient.Sandbox.Project.t()],
          optmem_path: String.t() | nil,
          host_notes: String.t(),
          desktop_notifications: boolean()
        }

  @doc """
  The settings with what a form sent, checked: `{:ok, settings}`, or
  `{:error, errors}` with a message for each field that is wrong. A field
  the form didn't send stays as it is.
  """
  @spec cast(t(), map()) :: {:ok, t()} | {:error, %{atom() => String.t()}}
  def cast(%__MODULE__{} = settings, attrs) do
    fields = [
      {:cpus, attrs["cpus"], &cast_int(&1, 1, 64)},
      {:memory_gib, attrs["memory_gib"], &cast_int(&1, 1, 512)},
      {:disk_gib, attrs["disk_gib"], &cast_int(&1, 4, 4096)},
      {:write_budget_gib, attrs["write_budget_gib"], &cast_int(&1, 1, 4096)},
      {:hold_seconds, attrs["hold_seconds"], &cast_int(&1, 30, 600)},
      {:home_gib, attrs["home_gib"], &cast_int(&1, 1, 4_096)},
      {:cache_gib, attrs["cache_gib"], &cast_int(&1, 1, 4_096)},
      {:work_gib, attrs["work_gib"], &cast_int(&1, 1, 4_096)},
      {:containerfile, attrs["containerfile"], &cast_containerfile/1},
      {:image_name, attrs["image_name"], &cast_image_name/1},
      {:host_notes, attrs["host_notes"], &cast_notes/1},
      {:desktop_notifications, attrs["desktop_notifications"], &cast_bool/1}
    ]

    {changes, errors} =
      Enum.reduce(fields, {%{}, %{}}, fn
        {_field, nil, _cast}, acc ->
          acc

        {field, value, cast}, {changes, errors} ->
          case cast.(value) do
            {:ok, cast_value} -> {Map.put(changes, field, cast_value), errors}
            {:error, message} -> {changes, Map.put(errors, field, message)}
          end
      end)

    if errors == %{}, do: {:ok, struct!(settings, changes)}, else: {:error, errors}
  end

  defp cast_containerfile(value) do
    if Regex.match?(~r/^\s*FROM\s+\S+/mi, value),
      do: {:ok, String.replace(value, "\r\n", "\n")},
      else: {:error, "A Containerfile needs a FROM line."}
  end

  defp cast_notes(value) do
    notes = value |> String.replace("\r\n", "\n") |> String.trim()

    if String.length(notes) <= 4_000,
      do: {:ok, notes},
      else: {:error, "Keep notes under 4,000 characters."}
  end

  defp cast_image_name(value) do
    name = String.trim(value)

    if Image.valid_name?(name),
      do: {:ok, name},
      else:
        {:error, "Lowercase letters and digits, joined by single dots, underscores or dashes."}
  end

  defp cast_bool(value) when value in [true, "true"], do: {:ok, true}

  defp cast_bool(value) when value in [false, "false"], do: {:ok, false}

  defp cast_bool(_value), do: {:error, "Either on or off."}

  defp cast_int(value, min, max) do
    case Integer.parse(String.trim(to_string(value))) do
      {int, ""} when int >= min and int <= max -> {:ok, int}
      _ -> {:error, "Enter a whole number from #{min} to #{max}."}
    end
  end
end
