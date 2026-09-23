defmodule MDTClient.LogFile do
  @moduledoc """
  Installs a rotating file handler alongside Logger's console handler.

  The log belongs to the application, not to an encrypted identity. Keep
  credentials, request bodies and response bodies out of log messages.
  """

  @handler :mdt_file
  @max_bytes 10_000_000
  @archives 5

  @doc "The active log file, under MDT's data directory unless configured otherwise."
  @spec path() :: Path.t()
  def path do
    directory =
      Application.get_env(:mdt_client, :log_dir) ||
        Path.join(MDTClient.Accounts.root(), "logs")

    Path.join(directory, "mdt.log")
  end

  @doc "Starts the file handler before the application's supervised processes."
  @spec install() :: :ok | {:error, term()}
  def install do
    path = path()

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- private_directory(Path.dirname(path)),
         :ok <-
           :logger.add_handler(@handler, :logger_std_h, %{
             config: %{
               file: String.to_charlist(path),
               max_no_bytes: @max_bytes,
               max_no_files: @archives,
               compress_on_rotate: true
             },
             formatter:
               Logger.Formatter.new(
                 format: "$date $time $metadata[$level] $message\n",
                 metadata: [:user, :system, :request_id],
                 utc_log: true,
                 colors: [enabled: false]
               )
           }) do
      private_file(path)
    end
  end

  defp private_directory(path) do
    if match?({:unix, _}, :os.type()), do: File.chmod(path, 0o700), else: :ok
  end

  defp private_file(path) do
    if match?({:unix, _}, :os.type()), do: File.chmod(path, 0o600), else: :ok
  end
end
