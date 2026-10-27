defmodule Slack.SupervisorTest do
  use ExUnit.Case, async: false
  use Mimic

  @moduletag capture_log: true

  @config [app_token: "xapp-test", bot_token: "xbot-test", bot: Slack.TestBot]
  @identity %{"bot_id" => "bot-123", "team_id" => "team-123", "user_id" => "user-123"}

  setup :set_mimic_global

  setup do
    expect(Slack.API, :get, fn "auth.test", "xbot-test" ->
      {:ok, Map.put(@identity, "ok", true)}
    end)

    expect(Slack.API, :post, fn "apps.connections.open", "xapp-test" ->
      {:ok, %{"url" => "socket-url"}}
    end)

    expect(WebSockex, :start_link, fn "socket-url", Slack.Socket, state, _options ->
      Agent.start_link(fn -> state end)
    end)

    stub(Slack.API, :stream, fn _, _, _, _ ->
      flunk("channel discovery should be disabled")
    end)

    :ok
  end

  test "channels: false starts only the socket and task supervisors" do
    supervisor = start_supervised!({Slack.Supervisor, @config ++ [channels: false]})
    children = Supervisor.which_children(supervisor)

    assert Enum.sort(Enum.map(children, &elem(&1, 0))) ==
             Enum.sort([Slack.Socket, Slack.TaskSupervisors])

    refute Process.whereis(Slack.ChannelServerRegistry)
    refute Process.whereis(Slack.MessageServerRegistry)
    refute Process.whereis(Slack.DynamicSupervisor)
    assert socket_state(supervisor).channels? == false
  end

  test "channel discovery and message queues remain enabled by default" do
    expect(Slack.API, :stream, fn "users.conversations", "xbot-test", "channels", options ->
      assert options == [types: "public_channel,private_channel,mpim,im"]
      [%{"id" => "channel-123"}]
    end)

    supervisor = start_supervised!({Slack.Supervisor, @config})
    [{channel_server, _}] = Registry.lookup(Slack.ChannelServerRegistry, Slack.TestBot)

    assert "channel-123" in :sys.get_state(channel_server).channels
    assert [{_, _}] = Registry.lookup(Slack.MessageServerRegistry, {Slack.TestBot, "channel-123"})
    assert Process.whereis(Slack.DynamicSupervisor)
    assert socket_state(supervisor).channels? == true
  end

  test "custom channel types are still passed to channel discovery" do
    expect(Slack.API, :stream, fn "users.conversations", "xbot-test", "channels", options ->
      assert options == [types: "im"]
      []
    end)

    supervisor =
      start_supervised!({Slack.Supervisor, @config ++ [channels: [types: ["im"]]]})

    assert [{_, _}] = Registry.lookup(Slack.ChannelServerRegistry, Slack.TestBot)
    assert socket_state(supervisor).channels? == true
  end

  for type <- ~w(member_joined_channel channel_left) do
    test "channel management still handles #{type} by default" do
      type = unquote(type)

      expect(Slack.API, :stream, fn "users.conversations", "xbot-test", "channels", _ ->
        []
      end)

      supervisor = start_supervised!({Slack.Supervisor, @config})
      state = socket_state(supervisor)
      parent = self()
      event = %{"type" => type, "channel" => "channel-123", "user" => state.bot.user_id}
      bot = state.bot

      operation = if type == "member_joined_channel", do: :join, else: :part

      expect(Slack.ChannelServer, operation, fn ^bot, "channel-123" ->
        send(parent, :channel_event_dispatched)
      end)

      expect(Slack.TestBot, :handle_event, fn ^type, ^event, ^bot ->
        send(parent, :event_dispatched)
      end)

      envelope = %{
        "envelope_id" => "eid-123",
        "type" => "events_api",
        "payload" => %{"event" => event}
      }

      assert {:reply, _, ^state} =
               Slack.Socket.handle_frame({:text, Jason.encode!(envelope)}, state)

      assert_receive :event_dispatched
      assert_receive :channel_event_dispatched
    end

    test "channels: false still acknowledges and dispatches #{type}" do
      supervisor = start_supervised!({Slack.Supervisor, @config ++ [channels: false]})
      state = socket_state(supervisor)
      parent = self()
      type = unquote(type)
      event = %{"type" => type, "channel" => "channel-123", "user" => state.bot.user_id}
      bot = state.bot

      expect(Slack.TestBot, :handle_event, fn ^type, ^event, ^bot ->
        send(parent, :event_dispatched)
      end)

      envelope = %{
        "envelope_id" => "eid-123",
        "type" => "events_api",
        "payload" => %{"event" => event}
      }

      assert {:reply, {:text, ~S({"envelope_id":"eid-123"})}, ^state} =
               Slack.Socket.handle_frame({:text, Jason.encode!(envelope)}, state)

      assert_receive :event_dispatched
    end
  end

  defp socket_state(supervisor) do
    {Slack.Socket, socket, _, _} =
      Enum.find(Supervisor.which_children(supervisor), &(elem(&1, 0) == Slack.Socket))

    Agent.get(socket, & &1)
  end
end
