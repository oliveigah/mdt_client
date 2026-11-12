defmodule MDTClient.Sandbox.Image do
  @moduledoc """
  The VM image: your Containerfile, then MDT's layer, built with podman and
  handed to microsandbox.

  MDT's layer holds only pointers into `/mnt/mdt` and `/cache`, so nothing in
  the image belongs to one identity: the CA, the credential helper and the
  agents' instructions arrive when the VM is created, and an MDT update never
  needs a rebuild.

  Each build gets a tag of its date and number (`2026-11-12.1`) under the
  image name from the settings. MDT keeps the current build and the two
  before it (`keep/3`).

  The build runs on this machine in a rootless podman container, which
  isolates it less than the VM does: install scripts in your Containerfile
  run there. Keep what it installs to what you trust.
  """

  alias MDTClient.Sandbox.{Build, Msb}

  @default_name "mdt_agent_sdb_image"
  @kept 3

  @doc "The image name a new sandbox starts with."
  @spec default_name() :: String.t()
  def default_name, do: @default_name

  @doc "The Containerfile a new sandbox starts with."
  @spec default_containerfile() :: String.t()
  def default_containerfile, do: File.read!(priv("Containerfile"))

  @doc "The layer MDT appends to every build."
  @spec mdt_layer() :: String.t()
  def mdt_layer, do: File.read!(priv("mdt-layer.Containerfile"))

  @doc "What podman builds: your Containerfile with MDT's layer after it."
  @spec full(String.t()) :: String.t()
  def full(containerfile), do: String.trim_trailing(containerfile) <> "\n" <> mdt_layer()

  @doc """
  Whether `name` can name an image: lowercase letters and digits, joined by
  single `.`, `_`, `__` or runs of `-`, as OCI references allow.
  """
  @spec valid_name?(String.t()) :: boolean()
  def valid_name?(name) when is_binary(name),
    do: byte_size(name) <= 128 and Regex.match?(~r/^[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*$/, name)

  @doc """
  The tag the next build of `name` gets on `date`: the date, then one more
  than the highest number that day among `builds`.

      iex> MDTClient.Sandbox.Image.next_tag("box", ~D[2026-11-12], [])
      "2026-11-12.1"
  """
  @spec next_tag(String.t(), Date.t(), [Build.t()]) :: String.t()
  def next_tag(name, date, builds) do
    day = Date.to_iso8601(date)

    highest =
      builds
      |> Enum.filter(&(&1.name == name))
      |> Enum.flat_map(fn build ->
        case String.split(build.tag, ".", parts: 2) do
          [^day, number] ->
            case Integer.parse(number) do
              {n, ""} -> [n]
              _ -> []
            end

          _ ->
            []
        end
      end)
      |> Enum.max(fn -> 0 end)

    "#{day}.#{highest + 1}"
  end

  @doc """
  Splits `builds` (newest first) into those kept and those to delete: the
  newest #{@kept}, plus any whose ref is in `protected` (the VM's), which is
  never deleted while in use.
  """
  @spec keep([Build.t()], [String.t()], pos_integer()) :: {[Build.t()], [Build.t()]}
  def keep(builds, protected, count \\ @kept) do
    {newest, older} =
      builds |> Enum.sort_by(& &1.built_at, {:desc, DateTime}) |> Enum.split(count)

    {still_used, removed} = Enum.split_with(older, &(&1.ref in protected))
    {newest ++ still_used, removed}
  end

  @doc "Writes the build context into `dir`, replacing what was there."
  @spec write_context(Path.t(), String.t()) :: :ok
  def write_context(dir, containerfile) do
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "Containerfile"), full(containerfile))
  end

  @doc """
  The shell script that builds `ref` from `dir` and loads it into
  microsandbox. It leaves `versions.txt` (what mise installed) and `size` in
  `dir`, read without running anything from the image. Paths are quoted, so
  spaces in a home folder are fine.
  """
  @spec build_script(Path.t(), String.t()) :: String.t()
  def build_script(dir, ref) do
    msb = Msb.executable() || "msb"
    archive = Path.join(dir, "image.tar")
    q = &shell_quote/1

    """
    set -euo pipefail
    echo "==> podman build #{ref}"
    podman build --format docker --pull=newer --tag #{q.(ref)} --file #{q.(Path.join(dir, "Containerfile"))} #{q.(dir)}
    container=$(podman create #{q.(ref)})
    podman cp "$container:/etc/mdt/versions.txt" #{q.(Path.join(dir, "versions.txt"))} || true
    podman rm "$container" >/dev/null
    podman image inspect --format '{{.Size}}' #{q.(ref)} > #{q.(Path.join(dir, "size"))}
    echo "==> handing the image to microsandbox"
    rm -f #{q.(archive)}
    podman save --format docker-archive --output #{q.(archive)} #{q.(ref)}
    #{q.(msb)} load --input #{q.(archive)} --tag #{q.(ref)}
    rm -f #{q.(archive)}
    echo "==> ready: #{ref}"
    """
  end

  @doc "Reads what a finished build left in `dir` into a `Build`."
  @spec read_build(Path.t(), map()) :: Build.t()
  def read_build(dir, %{name: name, tag: tag, containerfile: containerfile, built_at: built_at}) do
    versions =
      case File.read(Path.join(dir, "versions.txt")) do
        {:ok, text} -> String.slice(text, 0, 20_000)
        {:error, _} -> ""
      end

    size =
      with {:ok, text} <- File.read(Path.join(dir, "size")),
           {size, _} <- Integer.parse(String.trim(text)) do
        size
      else
        _ -> nil
      end

    %Build{
      ref: "#{name}:#{tag}",
      name: name,
      tag: tag,
      built_at: built_at,
      containerfile: containerfile,
      versions: versions,
      size: size
    }
  end

  @doc """
  Deletes a build's image from microsandbox and podman. Loading a podman
  archive also names it `localhost/<ref>` in microsandbox, so both names go.
  Failures are ignored.
  """
  @spec delete(String.t()) :: :ok
  def delete(ref) do
    _ = Msb.run(["image", "remove", ref, "localhost/" <> ref], 60)

    if podman?() do
      System.cmd("podman", ["rmi", "--ignore", ref], stderr_to_stdout: true)
    end

    :ok
  end

  @doc "Whether podman, which builds the image, is installed."
  @spec podman?() :: boolean()
  def podman?, do: System.find_executable("podman") != nil

  defp shell_quote(text), do: "'" <> String.replace(text, "'", "'\\''") <> "'"

  defp priv(name), do: Path.join([:code.priv_dir(:mdt_client), "sandbox", name])
end
