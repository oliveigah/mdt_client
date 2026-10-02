ExUnit.start()

ExUnit.after_suite(fn _result -> File.rm_rf!(MDTClient.Accounts.root()) end)
