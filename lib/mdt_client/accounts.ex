defmodule MDTClient.Accounts do
  @moduledoc """
  Local user profiles, each owning an encrypted directory.

  A profile is a `{username, password}` pair. Signing in with an unknown
  username creates one; signing in with a known one derives its key from the
  stored salt and proves the password by opening the verifier.

  Nothing secret is written: `vault.json` holds a salt, the KDF parameters and
  a sealed constant, all useless without the password.
  """

  alias MDTClient.Vault

  @verifier "mdt:vault:verifier:v1"
  @version 1

  @type profile :: %{username: String.t(), initials: String.t()}

  @doc "The directory holding preferences and every identity."
  @spec root() :: Path.t()
  def root do
    Application.get_env(
      :mdt_client,
      :data_dir,
      Path.join(System.user_home!(), ".mdt_client")
    )
  end

  @doc "Usernames are matched case insensitively and without surrounding space."
  @spec normalize(String.t()) :: String.t()
  def normalize(username), do: username |> String.trim() |> String.downcase()

  @doc """
  The directory name for a username.

  Hashed so that a directory listing cannot enumerate who uses the machine,
  and so any username is a safe path segment.
  """
  @spec id(String.t()) :: String.t()
  def id(username) do
    :sha256 |> :crypto.hash(normalize(username)) |> Base.encode16(case: :lower)
  end

  @doc "The directory owning one identity's encrypted files."
  @spec dir(String.t()) :: Path.t()
  def dir(username), do: Path.join([root(), "identities", id(username)])

  @doc "The path of one of an identity's encrypted stores."
  @spec store_path(String.t(), String.t()) :: Path.t()
  def store_path(username, name), do: Path.join(dir(username), name)

  @doc "Whether a profile already exists for this username."
  @spec exists?(String.t()) :: boolean()
  def exists?(username) do
    username |> vault_path() |> File.exists?()
  end

  @doc """
  Unlocks an existing profile, or creates one when the username is new.

  Returns the derived key, which the caller hands to `MDTClient.Vault.Store`
  and otherwise keeps out of sight.
  """
  @spec sign_in(String.t(), String.t()) ::
          {:ok, profile(), Vault.key()}
          | {:error, :bad_password | :blank_username | :blank_password | :unreadable_vault}
  def sign_in(username, password) do
    cond do
      normalize(username) == "" -> {:error, :blank_username}
      password in [nil, ""] -> {:error, :blank_password}
      exists?(username) -> unlock(username, password)
      true -> create(username, password)
    end
  end

  @doc "The profile shown in the app chrome."
  @spec profile(String.t()) :: profile()
  def profile(username) do
    username = normalize(username)
    %{username: username, initials: initials(username)}
  end

  defp create(username, password) do
    salt = Vault.salt()
    key = Vault.derive(password, salt)

    meta = %{
      "version" => @version,
      "username" => normalize(username),
      "kdf" => Map.put(Vault.kdf_params(), "salt", Base.encode64(salt)),
      "verifier" => Base.encode64(Vault.seal(key, @verifier)),
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    path = vault_path(username)
    :ok = File.mkdir_p(Path.dirname(path))
    :ok = File.write(path, Jason.encode!(meta, pretty: true))

    {:ok, profile(username), key}
  end

  defp unlock(username, password) do
    with {:ok, meta} <- read_vault(username),
         {:ok, salt} <- decode(meta["kdf"]["salt"]),
         {:ok, verifier} <- decode(meta["verifier"]),
         key = Vault.derive(password, salt, meta["kdf"]),
         {:ok, @verifier} <- Vault.open(key, verifier) do
      {:ok, profile(username), key}
    else
      {:error, :unreadable_vault} -> {:error, :unreadable_vault}
      :error -> {:error, :bad_password}
      _mismatch -> {:error, :bad_password}
    end
  end

  defp vault_path(username), do: Path.join(dir(username), "vault.json")

  defp read_vault(username) do
    with {:ok, body} <- File.read(vault_path(username)),
         {:ok, %{"kdf" => %{"salt" => _}, "verifier" => _} = meta} <- Jason.decode(body) do
      {:ok, meta}
    else
      _unreadable -> {:error, :unreadable_vault}
    end
  end

  defp decode(value) when is_binary(value), do: Base.decode64(value)
  defp decode(_value), do: :error

  defp initials(username) do
    username
    |> String.split(~r/[._\-\s@]+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&String.first/1)
    |> String.upcase()
    |> case do
      "" -> "?"
      initials -> initials
    end
  end
end
