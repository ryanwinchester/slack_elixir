defmodule Slack.SocketTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Slack.TestBot

  @foo_event """
  {
    "envelope_id": "eid-234",
    "type": "foo",
    "payload": {
      "event": {
        "type": "foo",
        "channel": "channel-foo"
      }
    }
  }
  """

  @slash_command """
  {
    "envelope_id": "eid-567",
    "type": "slash_commands",
    "payload": {
      "channel_name": "directmessage",
      "command": "/mycmd",
      "text": "run this"
    }
  }
  """

  @bot %Slack.Bot{
    bot_id: "bot-123-ABC",
    bot_module: TestBot,
    team_id: "team-123-ABC",
    user_id: "user-123-ABC"
  }

  setup :set_mimic_global

  setup do
    stub(Slack.API)
    start_supervised!({Registry, keys: :unique, name: Slack.MessageServerRegistry})

    start_supervised!(
      {PartitionSupervisor, child_spec: Task.Supervisor, name: Slack.TaskSupervisors}
    )

    :ok
  end

  test "bot can noop" do
    stub(Slack.API)

    state = %{bot: @bot}

    assert {:reply, ack_frame, _state} = Slack.Socket.handle_frame({:text, @foo_event}, state)
    assert {:text, ~S({"envelope_id":"eid-234"})} = ack_frame
  end

  test "socket can noop" do
    stub(Slack.API)

    assert {:ok, %{}} == Slack.Socket.handle_frame({:text, ""}, %{})
  end

  test "socket can handle a slash command" do
    stub(Slack.API)

    assert {:reply, {:text, ~S({"envelope_id":"eid-567"})}, %{}} =
             Slack.Socket.handle_frame({:text, @slash_command}, %{})
  end
end
