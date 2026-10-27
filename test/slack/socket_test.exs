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
    id: "bot-123-ABC",
    module: TestBot,
    token: "bot-123-ABC",
    team_id: "team-123-ABC",
    user_id: "user-123-ABC"
  }

  @state %{bot: @bot, app_token: "xapp-test", alive?: true, ping_interval: 10}

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
    stub(Slack.API)

    assert {:reply, {:text, ~S({"envelope_id":"eid-567"})}, @state} =
             Slack.Socket.handle_frame({:text, @slash_command}, @state)
  end

  @tag capture_log: true
  test "socket verifies TLS certificates and the server name" do
    url = URI.to_string(%URI{scheme: "wss", host: @bot.team_id, path: "/socket"})
    cacerts = :public_key.cacerts_get()

    expect(Slack.API, :post, fn "apps.connections.open", "xapp-test" ->
      {:ok, %{"url" => url}}
    end)

    expect(WebSockex, :start_link, fn ^url, Slack.Socket, state, options ->
      assert state.bot == @bot
      assert state.app_token == "xapp-test"
      assert options[:insecure] == false
      assert options[:cacerts] == cacerts
      assert options[:ssl_options][:verify] == :verify_peer
      assert options[:ssl_options][:cacerts] == cacerts
      assert options[:ssl_options][:server_name_indication] == String.to_charlist(@bot.team_id)

      assert options[:ssl_options][:customize_hostname_check][:match_fun] ==
               :public_key.pkix_verify_hostname_match_fun(:https)

      {:ok, self()}
    end)

    assert {:ok, pid} = Slack.Socket.start_link({"xapp-test", @bot})
    assert pid == self()
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
end
