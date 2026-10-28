defmodule Slack.SocketTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Slack.TestBot

  @foo_event """
  {
    "envelope_id": "eid-234",
    "type": "events_api",
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
    id: "bot-123-ABC",
    module: TestBot,
    token: "bot-123-ABC",
    team_id: "team-123-ABC",
    user_id: "user-123-ABC"
  }

  @state %{
    bot: @bot,
    app_token: "xapp-test",
    alive?: true,
    ping_interval: 10,
    response_timeout: 100
  }

  defmodule EventBot do
    @moduledoc false
    use Slack.Bot

    @impl Slack.Bot
    def handle_event(_type, _payload, _bot), do: :ok
  end

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

    assert {:reply, ack_frame, _state} = Slack.Socket.handle_frame({:text, @foo_event}, @state)
    assert {:text, ~S({"envelope_id":"eid-234"})} = ack_frame
  end

  test "socket can noop" do
    stub(Slack.API)

    assert {:ok, @state} == Slack.Socket.handle_frame({:text, ""}, @state)
  end

  test "socket can handle a slash command" do
    parent = self()
    payload = Jason.decode!(@slash_command)["payload"]

    expect(TestBot, :handle_event, fn "slash_commands", ^payload, @bot ->
      send(parent, :slash_command_dispatched)
    end)

    assert {:reply, {:text, ~S({"envelope_id":"eid-567"})}, @state} =
             Slack.Socket.handle_frame({:text, @slash_command}, @state)

    assert_receive :slash_command_dispatched
  end

  test "socket acknowledges envelopes it doesn't handle" do
    for envelope <- [
          %{"envelope_id" => "eid-1", "type" => "something_new", "payload" => %{}},
          %{"envelope_id" => "eid-1", "type" => "interactive", "payload" => %{}}
        ] do
      assert {:reply, {:text, ~S({"envelope_id":"eid-1"})}, @state} =
               Slack.Socket.handle_frame({:text, Jason.encode!(envelope)}, @state)
    end
  end

  test "socket handles a disconnect warning" do
    disconnect = ~S({"type": "disconnect", "reason": "warning"})
    assert {:ok, @state} = Slack.Socket.handle_frame({:text, disconnect}, @state)
  end

  test "bot ignores its own bot messages" do
    parent = self()
    stub(TestBot, :handle_event, fn "message", event, @bot -> send(parent, {:event, event}) end)

    own = events_api(%{"type" => "message", "bot_id" => @bot.id, "text" => "hi"})
    other = events_api(%{"type" => "message", "bot_id" => "other-bot", "text" => "hi"})

    assert {:reply, _ack, @state} = Slack.Socket.handle_frame({:text, own}, @state)
    assert {:reply, _ack, @state} = Slack.Socket.handle_frame({:text, other}, @state)

    assert_receive {:event, %{"bot_id" => "other-bot"}}
    refute_receive {:event, %{"bot_id" => "bot-123-ABC"}}
  end

  describe "interactions" do
    for type <- ~w(block_actions view_closed shortcut message_action) do
      test "#{type} is acknowledged right away and dispatched" do
        type = unquote(type)
        parent = self()
        payload = %{"type" => type, "user" => %{"id" => "user-456"}}

        expect(TestBot, :handle_interaction, fn ^type, ^payload, @bot ->
          send(parent, :interaction_dispatched)
        end)

        assert {:reply, {:text, ~S({"envelope_id":"eid-890"})}, @state} =
                 Slack.Socket.handle_frame({:text, interactive(payload)}, %{
                   @state
                   | alive?: false
                 })

        assert_receive :interaction_dispatched
      end
    end

    test "are dispatched by envelope type, not payload shape" do
      parent = self()
      payload = %{"type" => "block_actions", "event" => %{"type" => "message"}}

      expect(TestBot, :handle_interaction, fn "block_actions", ^payload, @bot ->
        send(parent, :interaction_dispatched)
      end)

      assert {:reply, _ack, @state} =
               Slack.Socket.handle_frame({:text, interactive(payload)}, @state)

      assert_receive :interaction_dispatched
    end

    test "send the handler's reply with the acknowledgment when Slack accepts one" do
      parent = self()
      payload = %{"type" => "block_suggestion", "value" => "ab"}
      options = %{"options" => [%{"text" => %{"type" => "plain_text", "text" => "abc"}}]}

      expect(TestBot, :handle_interaction, fn "block_suggestion", ^payload, @bot ->
        {:reply, options}
      end)

      expect(WebSockex, :cast, fn ^parent, {:send, {:text, ack}} ->
        send(parent, {:ack, Jason.decode!(ack)})
      end)

      assert {:ok, @state} =
               Slack.Socket.handle_frame({:text, interactive(payload, true)}, @state)

      assert_receive {:ack, %{"envelope_id" => "eid-890", "payload" => ^options}}
    end

    test "are acknowledged without a payload when the handler doesn't reply" do
      parent = self()
      expect(TestBot, :handle_interaction, fn "view_submission", _payload, @bot -> :ok end)
      expect(WebSockex, :cast, fn ^parent, {:send, frame} -> send(parent, {:ack, frame}) end)

      payload = %{"type" => "view_submission"}

      assert {:ok, @state} =
               Slack.Socket.handle_frame({:text, interactive(payload, true)}, @state)

      assert_receive {:ack, {:text, ~S({"envelope_id":"eid-890"})}}
    end

    test "are not acknowledged when the handler crashes" do
      expect(TestBot, :handle_interaction, fn _type, _payload, _bot -> raise "boom" end)

      log = refute_ack(interactive(%{"type" => "view_submission"}, true))
      assert log =~ "view_submission eid-890 not acknowledged: handler crashed"
    end

    test "are not acknowledged when the handler takes too long" do
      expect(TestBot, :handle_interaction, fn _type, _payload, _bot ->
        Process.sleep(1_000)
        {:reply, %{}}
      end)

      log = refute_ack(interactive(%{"type" => "view_submission"}, true))
      assert log =~ "view_submission eid-890 not acknowledged: handler took longer than 100ms"
    end

    test "are acknowledged and ignored when the bot doesn't handle them" do
      state = %{@state | bot: %{@bot | module: EventBot}}

      assert {:reply, {:text, ~S({"envelope_id":"eid-890"})}, ^state} =
               Slack.Socket.handle_frame(
                 {:text, interactive(%{"type" => "view_submission"}, true)},
                 state
               )
    end
  end

  describe "liveness ping" do
    test "handle_connect schedules the first ping tick" do
      assert {:ok, @state} = Slack.Socket.handle_connect(:conn, @state)
      assert_receive :ping_tick, 100
    end

    test "a tick sends a ping, arms the check, and schedules the next tick" do
      assert {:reply, :ping, %{alive?: false}} = Slack.Socket.handle_info(:ping_tick, @state)
      assert_receive :ping_tick, 100
    end

    @tag capture_log: true
    test "a tick closes the socket when nothing arrived since the last ping" do
      assert {:close, _state} = Slack.Socket.handle_info(:ping_tick, %{@state | alive?: false})
      refute_receive :ping_tick, 50
    end

    test "a pong marks the connection alive" do
      assert {:ok, %{alive?: true}} = Slack.Socket.handle_pong(:pong, %{@state | alive?: false})
    end

    test "a server ping is answered and marks the connection alive" do
      dead = %{@state | alive?: false}
      assert {:reply, :pong, %{alive?: true}} = Slack.Socket.handle_ping(:ping, dead)

      assert {:reply, {:pong, "x"}, %{alive?: true}} =
               Slack.Socket.handle_ping({:ping, "x"}, dead)
    end

    test "any received frame marks the connection alive" do
      dead = %{@state | alive?: false}
      assert {:ok, %{alive?: true}} = Slack.Socket.handle_frame({:text, ""}, dead)
      assert {:ok, %{alive?: true}} = Slack.Socket.handle_frame({:binary, ""}, dead)
    end
  end

  defp events_api(event) do
    Jason.encode!(%{
      "envelope_id" => "eid-123",
      "type" => "events_api",
      "payload" => %{"event" => event}
    })
  end

  defp interactive(payload, accepts_response_payload \\ false) do
    Jason.encode!(%{
      "envelope_id" => "eid-890",
      "type" => "interactive",
      "accepts_response_payload" => accepts_response_payload,
      "payload" => payload
    })
  end

  # Handles the envelope, asserts no acknowledgment is sent, and returns the log.
  defp refute_ack(envelope) do
    parent = self()
    stub(WebSockex, :cast, fn _socket, {:send, frame} -> send(parent, {:ack, frame}) end)

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:ok, @state} = Slack.Socket.handle_frame({:text, envelope}, @state)
      refute_receive {:ack, _frame}, 300
    end)
  end
end
