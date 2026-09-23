defmodule MDTClient.LogFileTest do
  use ExUnit.Case, async: false

  require Logger

  alias MDTClient.LogFile

  test "writes tagged Logger events to a rotating file alongside the console handler" do
    path = LogFile.path()
    marker = "log-file-test-#{System.unique_integer([:positive])}"
    default_marker = "log-file-default-#{System.unique_integer([:positive])}"

    assert {:ok, %{module: :logger_std_h, config: config}} =
             :logger.get_handler_config(:mdt_file)

    assert config.file == String.to_charlist(path)
    assert config.max_no_bytes == 10_000_000
    assert config.max_no_files == 5
    assert {:ok, _console} = :logger.get_handler_config(:default)

    Logger.warning(marker, user: "tester", system: :http_client)
    Logger.warning(default_marker)
    assert :ok = :logger_std_h.filesync(:mdt_file)

    contents = File.read!(path)
    assert contents =~ ~r/\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}/
    assert contents =~ "user=tester system=http_client [warning] #{marker}"
    assert contents =~ "system=app [warning] #{default_marker}"
  end
end
