defmodule MDTClient.SaveTimerTest do
  use ExUnit.Case, async: true

  alias MDTClient.SaveTimer

  test "sets a timer when none waits, and keeps the one that does" do
    timer = SaveTimer.ensure(nil, 10)
    assert SaveTimer.ensure(timer, 10) == timer
    refute SaveTimer.lost?(timer)
    refute SaveTimer.lost?(nil)
    assert_receive :flush
  end

  test "one gone without its :flush handled is lost, and gets replaced" do
    timer = SaveTimer.ensure(nil, 60_000)
    # As gone as one whose :flush gen_server skipped while code reloaded.
    Process.cancel_timer(timer)
    assert SaveTimer.lost?(timer)

    replaced = SaveTimer.ensure(timer, 0)
    assert replaced != timer
    assert_receive :flush
  end
end
