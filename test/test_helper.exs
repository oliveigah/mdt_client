# Git also reads the machine's own config, which differs from one machine to
# the next: MDT's VM rewrites GitHub SSH URLs to HTTPS in /etc/gitconfig, and
# a developer's ~/.gitconfig may rewrite the other way or sign every commit.
# Tests see neither, so they behave the same everywhere. Every repository a
# test makes sets its own user.name and user.email.
System.put_env(%{"GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_NOSYSTEM" => "1"})

# The benchmarks in test/bench take minutes; `mix test --only bench` runs them.
# The D-Bus tests start a private dbus-daemon, so they need one installed.
# The `:vm` tests boot a real VM: they need KVM, bwrap, MDT's runtime in
# priv/microsandbox and the internet; `mix test --only vm` runs them.
exclude = if MDTClient.DBusDaemon.available?(), do: [:bench, :vm], else: [:bench, :vm, :dbus]
ExUnit.start(exclude: exclude)

ExUnit.after_suite(fn _result ->
  File.rm_rf!(MDTClient.Accounts.root())
  # Each test identity has a folder of sockets of its own.
  File.rm_rf!(Application.get_env(:mdt_client, MDTClient.Sandbox.Server)[:channel_dir])
end)
