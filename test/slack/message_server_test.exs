defmodule Slack.MessageServerTest do
  use ExUnit.Case, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias Slack.MessageServer
  alias Slack.TestBot

  @bot %Slack.Bot{
    id: "bot-123",
    module: TestBot,
    token: "xoxb-test",
    team_id: "team-123",
    user_id: "user-123"
  }

  setup :set_mimic_global

  setup do
    start_supervised!(
      {Registry, keys: :unique, name: Slack.MessageServerRegistry, meta: [{TestBot, @bot}]}
    )

    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: Slack.DynamicSupervisor})
    :ok
  end

  test "the first message to a channel starts its queue and is sent right away" do
    parent = self()

    expect(Slack.API, :post, fn "chat.postMessage", "xoxb-test", args ->
      send(parent, {:posted, args})
      {:ok, %{}}
    end)

    assert :ok = MessageServer.send(TestBot, "user-456", "hi")
    assert_receive {:posted, %{channel: "user-456", text: "hi"}}, 500

    assert [{_message_server, _}] =
             Registry.lookup(Slack.MessageServerRegistry, {TestBot, "user-456"})
  end

  test "messages to a channel share its queue, even when sent at the same time" do
    stub(Slack.API, :post, fn "chat.postMessage", "xoxb-test", _args -> {:ok, %{}} end)

    results =
      1..20
      |> Task.async_stream(&MessageServer.send(TestBot, "channel-123", "message #{&1}"))
      |> Enum.to_list()

    assert Enum.all?(results, &(&1 == {:ok, :ok}))
    assert %{active: 1} = DynamicSupervisor.count_children(Slack.DynamicSupervisor)
  end

  test "messages from a module that isn't the bot aren't sent" do
    log =
      capture_log(fn ->
        assert {:error, :unknown_bot} = MessageServer.send(NotTheBot, "channel-123", "hi")
      end)

    assert log =~ "message to channel-123 not sent: NotTheBot isn't the bot"
    assert %{active: 0} = DynamicSupervisor.count_children(Slack.DynamicSupervisor)
  end

  test "messages aren't sent when Slack.Supervisor isn't running" do
    stop_supervised!(Slack.MessageServerRegistry)

    log =
      capture_log(fn ->
        assert {:error, :not_started} = MessageServer.send(TestBot, "channel-123", "hi")
      end)

    assert log =~ "message to channel-123 not sent: Slack.Supervisor isn't running"
  end
end
