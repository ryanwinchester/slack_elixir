defmodule Slack.SupervisorTest do
  use ExUnit.Case, async: false
  use Mimic

  @moduletag capture_log: true

  @config [app_token: "xapp-test", bot_token: "xbot-test", bot: Slack.TestBot]
  @identity %{"bot_id" => "bot-123", "team_id" => "team-123", "user_id" => "user-123"}

  setup :set_mimic_global
  setup :verify_on_exit!

  setup do
    stub(Slack.API, :get, fn "auth.test", "xbot-test" ->
      {:ok, Map.put(@identity, "ok", true)}
    end)

    stub(Slack.API, :post, fn "apps.connections.open", "xapp-test" ->
      {:ok, %{"url" => "socket-url"}}
    end)

    stub(WebSockex, :start_link, fn "socket-url", Slack.Socket, state, _options ->
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
    assert_no_message_queues()
  end

  test "send_message doesn't raise when Slack.Supervisor isn't running" do
    assert_no_message_queues()
  end

  test "channel discovery and message queues remain enabled by default" do
    expect(Slack.API, :stream, fn "users.conversations", "xbot-test", "channels", options ->
      assert options == [types: "public_channel,private_channel,mpim,im"]
      [%{"id" => "channel-123"}]
    end)

    supervisor = start_supervised!({Slack.Supervisor, @config})
    [{channel_server, _}] = Registry.lookup(Slack.ChannelServerRegistry, Slack.TestBot)

    assert :sys.get_state(channel_server).channels == ["channel-123"]
    assert [{_, _}] = Registry.lookup(Slack.MessageServerRegistry, {Slack.TestBot, "channel-123"})
    assert Process.whereis(Slack.DynamicSupervisor)
    assert socket_state(supervisor).channels? == true
  end

  for channels <- [true, nil] do
    test "channels: #{inspect(channels)} keeps the default behavior" do
      expect(Slack.API, :stream, fn "users.conversations", "xbot-test", "channels", options ->
        assert options == [types: "public_channel,private_channel,mpim,im"]
        []
      end)

      supervisor = start_supervised!({Slack.Supervisor, @config ++ [channels: unquote(channels)]})

      assert [{_, _}] = Registry.lookup(Slack.ChannelServerRegistry, Slack.TestBot)
      assert socket_state(supervisor).channels? == true
    end
  end

  test "channels must be a keyword list or a boolean" do
    for channels <- ["im", ["channel-123"]] do
      assert_raise ArgumentError, ~r/expected :channels to be a keyword list or a boolean/, fn ->
        Slack.Supervisor.init(@config ++ [channels: channels])
      end
    end
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

  describe "message queues" do
    setup do
      stub(Slack.API, :stream, fn "users.conversations", "xbot-test", "channels", _options ->
        [%{"id" => "channel-123"}]
      end)

      stub(Slack.API, :post, fn "chat.postMessage", "xbot-test", _args -> {:ok, %{}} end)

      supervisor = start_supervised!({Slack.Supervisor, @config})
      [{channel_server, _}] = Registry.lookup(Slack.ChannelServerRegistry, Slack.TestBot)

      %{supervisor: supervisor, channel_server: channel_server, bot: socket_state(supervisor).bot}
    end

    test "leaving a channel stops its queue for good", context do
      Slack.ChannelServer.part(context.bot, "channel-123")

      assert :sys.get_state(context.channel_server).channels == []
      assert DynamicSupervisor.which_children(Slack.DynamicSupervisor) == []
    end

    test "the bot can rejoin a channel, and leave one it has no queue for", context do
      Slack.ChannelServer.part(context.bot, "channel-123")
      Slack.ChannelServer.join(context.bot, "channel-123")
      Slack.ChannelServer.part(context.bot, "channel-456")

      assert :sys.get_state(context.channel_server).channels == ["channel-123"]
      assert queued("channel-123") == []
    end

    test "a restarted channel server keeps the running queues", context do
      queue = GenServer.whereis(message_server("channel-123"))

      :ok = Supervisor.terminate_child(context.supervisor, Slack.ChannelServer)
      {:ok, channel_server} = Supervisor.restart_child(context.supervisor, Slack.ChannelServer)

      assert :sys.get_state(channel_server).channels == ["channel-123"]
      assert GenServer.whereis(message_server("channel-123")) == queue
    end

    test "send_message starts a queue for a channel the bot hasn't joined" do
      assert :ok = Slack.MessageServer.send(Slack.TestBot, "channel-456", "hi")
      assert queued("channel-456") == ["hi"]
    end

    test "send_message right after the bot joins a channel waits for the join", context do
      Slack.ChannelServer.join(context.bot, "channel-456")

      assert :ok = Slack.MessageServer.send(Slack.TestBot, "channel-456", "hi")
      assert queued("channel-456") == ["hi"]
      assert :sys.get_state(context.channel_server).channels == ["channel-456", "channel-123"]
    end
  end

  defp assert_no_message_queues do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :no_message_queues} =
                 Slack.MessageServer.send(Slack.TestBot, "channel-123", "hi")
      end)

    assert log =~ "message to channel-123 not sent"
  end

  defp message_server(channel) do
    {:via, Registry, {Slack.MessageServerRegistry, {Slack.TestBot, channel}}}
  end

  defp queued(channel) do
    :queue.to_list(:sys.get_state(message_server(channel)).queue)
  end

  defp socket_state(supervisor) do
    {Slack.Socket, socket, _, _} =
      Enum.find(Supervisor.which_children(supervisor), &(elem(&1, 0) == Slack.Socket))

    Agent.get(socket, & &1)
  end
end
