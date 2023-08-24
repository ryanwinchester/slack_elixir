defmodule Slack.BotTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Slack.TestBot

  setup do
    stub(Slack.MessageServer)
    :ok
  end

  defp message_event(text) do
    %{
      "type" => "message",
      "channel" => "channel-foo",
      "text" => text
    }
  end

  test "handles messages" do
    Slack.MessageServer
    |> expect(:send, 1, fn TestBot, "channel-foo", message ->
      assert message == "hello back!"
      :ok
    end)

    TestBot.handle_event("message", message_event("hello there."))
    TestBot.handle_event("message", message_event("No way, José!"))
  end

  test "fallbacks" do
    Slack.MessageServer
    |> stub(:send, fn _, _, _ ->
      raise "failed test"
    end)

    assert :noop = TestBot.handle_event("foo", message_event("No way, José!"))
  end
end
