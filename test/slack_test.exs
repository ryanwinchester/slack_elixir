defmodule SlackTest do
  use ExUnit.Case
  doctest Slack

  test "greets the world" do
    assert Slack.hello() == :world
  end
end
