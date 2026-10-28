defmodule Slack.SupervisorTest do
  use ExUnit.Case, async: false
  use Mimic

  import ExUnit.CaptureLog

  @config [app_token: "xapp-test", bot_token: "xbot-test", bot: Slack.TestBot]
  @identity %{
    "ok" => true,
    "bot_id" => "bot-123",
    "team_id" => "team-123",
    "user_id" => "user-123"
  }

  setup :set_mimic_global
  setup :verify_on_exit!

  setup do
    expect(Slack.API, :get, fn "auth.test", "xbot-test" -> {:ok, @identity} end)

    expect(Slack.API, :post, fn "apps.connections.open", "xapp-test" ->
      {:ok, %{"url" => "socket-url"}}
    end)

    expect(WebSockex, :start_link, fn "socket-url", Slack.Socket, _state, _options ->
      Agent.start_link(fn -> :socket end)
    end)

    # The bot no longer lists its conversations at startup.
    reject(Slack.API, :stream, 4)

    :ok
  end

  @tag capture_log: true
  test "the bot can send messages once it's started" do
    parent = self()
    start_supervised!({Slack.Supervisor, @config})

    expect(Slack.API, :post, fn "chat.postMessage", "xbot-test", args ->
      send(parent, {:posted, args})
      {:ok, %{}}
    end)

    assert :ok = Slack.MessageServer.send(Slack.TestBot, "channel-123", "hi")
    assert_receive {:posted, %{channel: "channel-123", text: "hi"}}
  end

  test "the channels option is deprecated and does nothing" do
    log =
      capture_log(fn ->
        start_supervised!({Slack.Supervisor, @config ++ [channels: [types: ["im"]]]})
      end)

    assert log =~ "the :channels option is deprecated and does nothing"
  end
end
