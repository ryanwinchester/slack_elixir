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

    assert_raise RuntimeError, ~r/disabled with `channels: false`/, fn ->
      Slack.MessageServer.send(Slack.TestBot, "channel-123", "hi")
    end
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
    assert_raise ArgumentError, ~r/expected :channels to be a keyword list or a boolean/, fn ->
      Slack.Supervisor.init(@config ++ [channels: "im"])
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

  defp socket_state(supervisor) do
    {Slack.Socket, socket, _, _} =
      Enum.find(Supervisor.which_children(supervisor), &(elem(&1, 0) == Slack.Socket))

    Agent.get(socket, & &1)
  end
end
