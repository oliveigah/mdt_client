# Git also reads the machine's own config, which differs from one machine to
# the next: MDT's VM rewrites GitHub SSH URLs to HTTPS in /etc/gitconfig, and
# a developer's ~/.gitconfig may rewrite the other way or sign every commit.
# Tests see neither, so they behave the same everywhere. Every repository a
# test makes sets its own user.name and user.email.
System.put_env(%{"GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_NOSYSTEM" => "1"})

# The benchmarks in test/bench take minutes; `mix test --only bench` runs them.
ExUnit.start(exclude: [:bench])

ExUnit.after_suite(fn _result -> File.rm_rf!(MDTClient.Accounts.root()) end)
