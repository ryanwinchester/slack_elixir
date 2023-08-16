defmodule Slack.SocketTest do
  use ExUnit.Case, async: true
  use Mimic

  @message_event """
  {
    "envelope_id": "eid-123",
    "type": "message",
    "payload": {
      "event": {
        "type": "message",
        "channel": "channel-foo",
        "text": "hello"
      }
    }
  }
  """

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

  defmodule Bot do
    @behaviour Slack.Bot

    @impl true
    def handle_event("message", _payload) do
      {:reply, channel: "channel-foo", text: "hello world"}
    end

    def handle_event(_type, _payload) do
      :ok
    end
  end

  test "bot can reply" do
    Slack.API
    |> stub()
    |> expect(:post, 1, fn "chat.postMessage", "t", args ->
      assert args[:channel] == "channel-foo"
      assert args[:text] == "hello world"
      {:ok, %Req.Response{status: 200, body: %{"ok" => true}}}
    end)

    state = %{bot_token: "t", bot: Bot}

    assert {:reply, ack_frame, _state} = Slack.Socket.handle_frame({:text, @message_event}, state)
    assert {:text, ~S({"envelope_id":"eid-123"})} = ack_frame
  end

  test "bot can noop" do
    stub(Slack.API)

    state = %{bot: Bot}

    assert {:reply, ack_frame, _state} = Slack.Socket.handle_frame({:text, @foo_event}, state)
    assert {:text, ~S({"envelope_id":"eid-234"})} = ack_frame
  end

  test "socket can noop" do
    stub(Slack.API)

    assert {:ok, %{}} == Slack.Socket.handle_frame({:text, ""}, %{})
  end
end
