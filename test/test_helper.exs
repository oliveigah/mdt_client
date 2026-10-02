# The benchmarks in test/bench take minutes; `mix test --only bench` runs them.
ExUnit.start(exclude: [:bench])

ExUnit.after_suite(fn _result -> File.rm_rf!(MDTClient.Accounts.root()) end)
