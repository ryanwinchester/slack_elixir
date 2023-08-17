defmodule Slack.SocketTest do
  use ExUnit.Case, async: false
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
    use Slack.Bot

    @impl true
    def handle_event("message", _payload) do
      send_message("channel-foo", "hello world")
      :ok
    end

    def handle_event(_type, _payload) do
      :ok
    end
  end

  setup :set_mimic_global

  setup do
    # Slack.API
    # |> stub()
    # |> expect(:post, 1, fn "apps.connections.open", "a" ->
    #   {:ok, %{"url" => "wss://foo"}}
    # end)

    # WebSockex
    # |> stub()
    # |> expect(:start_link, 1, fn "wss://foo", _, _ ->
    #   {:ok, make_ref()}
    # end)

    # {:ok, pid} = start_supervised({Slack.Supervisor, app_token: "a", bot_token: "t", bot: Bot})
    start_supervised!({Registry, keys: :unique, name: Slack.MessageServerRegistry})
    pid = start_supervised!({Slack.MessageServer, {Bot, "t", "channel-foo"}})

    {:ok, message_server: pid}
  end

  test "bot can reply", %{message_server: pid} do
    Slack.API
    |> stub()
    |> expect(:post, 1, fn "chat.postMessage", "t", args ->
      assert Access.get(args, :channel) == "channel-foo"
      assert Access.get(args, :text) == "hello world"
      {:ok, %Req.Response{status: 200, body: %{"ok" => true}}}
    end)

    # state = %{bot_token: "t", bot: Bot}

    # Slack.ChannelServer.join("channel-foo")

    # [{:undefined, pid}] = DynamicSupervisor.which_children(Slack.DynamicSupervisor)
    ref = Process.monitor(pid)

    %{"payload" => %{"event" => event}} = Jason.decode!(@message_event)

    assert :ok = Bot.handle_event(event["type"], event)
    assert_receive {:DOWN, ^ref, _, _, _}, 1200
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
