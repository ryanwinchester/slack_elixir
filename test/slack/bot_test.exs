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

    TestBot.handle_event("message", message_event("hello there."), %{})
    TestBot.handle_event("message", message_event("No way, José!"), %{})
  end

  test "post_message posts right away, with text or chat.postMessage arguments" do
    bot = %Slack.Bot{id: "B1", module: TestBot, token: "xbot", team_id: "T1", user_id: "U1"}

    for {message, args} <- [
          {"hi", %{channel: "C1", text: "hi"}},
          {%{text: "hi", thread_ts: "1.2"}, %{channel: "C1", text: "hi", thread_ts: "1.2"}},
          {[text: "hi", mrkdwn: false], %{channel: "C1", text: "hi", mrkdwn: false}}
        ] do
      expect(Slack.API, :post, fn "chat.postMessage", "xbot", ^args -> {:ok, %{"ok" => true}} end)
      assert {:ok, %{"ok" => true}} = Slack.Bot.post_message(bot, "C1", message)
    end
  end

  test "fallbacks" do
    Slack.MessageServer
    |> stub(:send, fn _, _, _ ->
      raise "failed test"
    end)

    assert :noop = TestBot.handle_event("foo", message_event("No way, José!"), %{})
  end
end
