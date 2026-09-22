defmodule MDTClient.Git.SSHKey do
  @moduledoc "A validated private/public SSH key pair used for Git remotes."

  alias MDTClient.Git.Error

  @enforce_keys [:private_key, :public_key]
  defstruct [:private_key, :public_key]

  @type t :: %__MODULE__{private_key: Path.t(), public_key: Path.t()}

  @doc false
  @spec new(Path.t(), Path.t()) :: {:ok, t()} | {:error, Error.t()}
  def new(private_key, public_key) do
    with {:ok, private_key} <- key_path(private_key, "Private key"),
         {:ok, public_key} <- key_path(public_key, "Public key"),
         :ok <- different_files(private_key, public_key),
         {:ok, private_fingerprint} <- fingerprint(private_key, "private"),
         {:ok, public_fingerprint} <- fingerprint(public_key, "public"),
         :ok <- matching_pair(private_fingerprint, public_fingerprint) do
      {:ok, %__MODULE__{private_key: private_key, public_key: public_key}}
    end
  end

  @doc false
  @spec command(t()) :: String.t()
  def command(%__MODULE__{private_key: private_key}) do
    Enum.join(
      [
        "ssh",
        "-i",
        shell_quote(private_key),
        "-o",
        "IdentitiesOnly=yes",
        "-o",
        "BatchMode=yes",
        "-o",
        "StrictHostKeyChecking=accept-new"
      ],
      " "
    )
  end

  defp key_path(path, label) when is_binary(path) do
    path = String.trim(path)

    cond do
      path == "" ->
        {:error, Error.new(:invalid_argument, "#{label} path cannot be empty")}

      String.contains?(path, <<0>>) ->
        {:error, Error.new(:invalid_argument, "#{label} path contains a null byte")}

      true ->
        expanded = Path.expand(path)

        if File.regular?(expanded) do
          {:ok, expanded}
        else
          {:error, Error.new(:invalid_argument, "#{label} file does not exist")}
        end
    end
  end

  defp key_path(_path, label),
    do: {:error, Error.new(:invalid_argument, "#{label} path must be a string")}

  defp different_files(path, path),
    do: {:error, Error.new(:invalid_argument, "Private and public keys must be different files")}

  defp different_files(_private_key, _public_key), do: :ok

  defp fingerprint(path, kind) do
    case System.find_executable("ssh-keygen") do
      nil ->
        {:error,
         Error.new(:command_failed, "OpenSSH ssh-keygen is required to validate SSH keys")}

      executable ->
        case System.cmd(executable, ["-lf", path], stderr_to_stdout: true) do
          {output, 0} -> parse_fingerprint(output, kind)
          {output, _status} -> {:error, invalid_key(kind, output)}
        end
    end
  rescue
    error in [ArgumentError, ErlangError] ->
      {:error,
       Error.new(:command_failed, "Could not validate SSH key: #{Exception.message(error)}")}
  end

  defp parse_fingerprint(output, kind) do
    case Regex.run(~r/(SHA256:[^\s]+)/, output, capture: :all_but_first) do
      [fingerprint] -> {:ok, fingerprint}
      _invalid -> {:error, invalid_key(kind, output)}
    end
  end

  defp invalid_key(kind, output) do
    detail = String.trim(output)

    message =
      if detail == "" do
        "The selected #{kind} key is not a readable SSH key"
      else
        "The selected #{kind} key is not valid: #{detail}"
      end

    Error.new(:invalid_argument, message)
  end

  defp matching_pair(fingerprint, fingerprint), do: :ok

  defp matching_pair(_private, _public) do
    {:error, Error.new(:invalid_argument, "The private and public keys do not form a pair")}
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
