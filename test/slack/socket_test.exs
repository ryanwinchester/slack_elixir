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

  test "socket acknowledges envelopes it doesn't handle, with a warning" do
    for type <- ["something_new", "interactive"] do
      envelope = Jason.encode!(%{"envelope_id" => "eid-1", "type" => type, "payload" => %{}})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:reply, {:text, ~S({"envelope_id":"eid-1"})}, @state} =
                   Slack.Socket.handle_frame({:text, envelope}, @state)
        end)

      assert log =~ "acknowledged and ignored unhandled #{type} envelope: eid-1"
    end
  end

  test "socket doesn't acknowledge envelopes when it can't start a handler" do
    stop_supervised!(Slack.TaskSupervisors)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, @state} = Slack.Socket.handle_frame({:text, @foo_event}, @state)
      end)

    assert log =~ "could not handle events_api eid-234"
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
      assert log =~ "view_submission eid-890 not acknowledged: handler exited: boom"
    end

    test "are not acknowledged when the handler takes too long, but it isn't killed" do
      parent = self()

      expect(TestBot, :handle_interaction, fn _type, _payload, _bot ->
        Process.sleep(200)
        send(parent, :handler_finished)
        {:reply, %{}}
      end)

      log = refute_ack(interactive(%{"type" => "view_submission"}, true))
      assert log =~ "view_submission eid-890 not acknowledged: handler took longer than 100ms"
      assert_received :handler_finished
    end

    test "are not acknowledged when the reply can't be encoded" do
      expect(TestBot, :handle_interaction, fn _type, _payload, _bot ->
        {:reply, %{options: [{"not", "json"}]}}
      end)

      log = refute_ack(interactive(%{"type" => "block_suggestion"}, true))

      assert log =~
               "block_suggestion eid-890 not acknowledged: the reply can't be encoded as JSON"
    end

    test "are acknowledged with no reply by the default handle_interaction/3" do
      parent = self()
      state = %{@state | bot: %{@bot | module: EventBot}}
      expect(WebSockex, :cast, fn ^parent, {:send, frame} -> send(parent, {:ack, frame}) end)

      assert {:reply, {:text, ~S({"envelope_id":"eid-890"})}, ^state} =
               Slack.Socket.handle_frame(
                 {:text, interactive(%{"type" => "block_actions"})},
                 state
               )

      assert {:ok, ^state} =
               Slack.Socket.handle_frame(
                 {:text, interactive(%{"type" => "view_submission"}, true)},
                 state
               )

      assert_receive {:ack, {:text, ~S({"envelope_id":"eid-890"})}}
    end
  end

  @tag capture_log: true
  test "socket connects with the TLS options from the bot config" do
    url = "wss://wss-primary.slack.com/link"

    expect(Slack.API, :post, fn "apps.connections.open", "xapp-test" ->
      {:ok, %{"url" => url}}
    end)

    expect(WebSockex, :start_link, fn ^url, Slack.Socket, state, options ->
      assert state.bot == @bot
      assert state.app_token == "xapp-test"
      assert options == [ssl_options: Slack.Socket.ssl_options(crl_check: :peer)]
      {:ok, self()}
    end)

    assert {:ok, pid} = Slack.Socket.start_link({"xapp-test", @bot, [crl_check: :peer]})
    assert pid == self()
  end

  describe "ssl_options/1" do
    test "verifies the server certificate and hostname by default" do
      options = Slack.Socket.ssl_options([])

      assert options[:verify] == :verify_peer
      assert [_ | _] = options[:cacerts]
      assert Enum.all?(options[:cacerts], &is_binary/1)

      assert options[:customize_hostname_check][:match_fun] ==
               :public_key.pkix_verify_hostname_match_fun(:https)
    end

    test "falls back to CAStore when the OS certificate store can't be loaded" do
      stub(:public_key, :cacerts_get, fn -> :erlang.error({:failed_load_cacerts, :enoent}) end)

      options = Slack.Socket.ssl_options([])

      assert options[:cacertfile] == CAStore.file_path()
      refute Keyword.has_key?(options, :cacerts)
    end

    test "user CAs replace the OS certificate store" do
      assert Slack.Socket.ssl_options(cacerts: ["der"])[:cacerts] == ["der"]

      options = Slack.Socket.ssl_options(cacertfile: "/etc/ssl/ca.pem")
      assert options[:cacertfile] == "/etc/ssl/ca.pem"
      refute Keyword.has_key?(options, :cacerts)
    end

    test "turning verification off skips the CA certificates" do
      options = Slack.Socket.ssl_options(verify: :verify_none)

      assert options[:verify] == :verify_none
      refute Keyword.has_key?(options, :cacerts)
    end

    test "other options are passed through" do
      assert Slack.Socket.ssl_options(crl_check: :peer)[:crl_check] == :peer
    end
  end

  describe "TLS handshake" do
    test "rejects a certificate from an unknown CA" do
      {port, _cacerts} = start_tls_server("localhost")

      assert {:error, %WebSockex.ConnError{original: {:tls_alert, {:unknown_ca, _}}}} =
               open_tls_socket(port, [])
    end

    test "accepts a certificate from a configured CA" do
      {port, cacerts} = start_tls_server("localhost")

      assert {:ok, _conn} = open_tls_socket(port, cacerts: cacerts)
    end

    test "rejects a certificate for another hostname" do
      {port, cacerts} = start_tls_server("example.com")

      assert {:error, %WebSockex.ConnError{original: {:tls_alert, {_alert, reason}}}} =
               open_tls_socket(port, cacerts: cacerts)

      assert to_string(reason) =~ "hostname_check_failed"
    end
  end

  # Starts a TLS server with a certificate for `hostname`, signed by a new root
  # CA. Returns the port and the root CA certificate.
  defp start_tls_server(hostname) do
    subject_alt_name =
      {:Extension, {2, 5, 29, 17}, false, [dNSName: String.to_charlist(hostname)]}

    # P-256 keys with SHA-256 signatures; TLS 1.3 refuses the default test keys.
    cert_options = [digest: :sha256, key: {:namedCurve, :secp256r1}]

    %{server_config: server_config, client_config: client_config} =
      :public_key.pkix_test_data(%{
        server_chain: %{
          root: cert_options,
          intermediates: [],
          peer: [extensions: [subject_alt_name]] ++ cert_options
        },
        client_chain: %{root: [], intermediates: [], peer: []}
      })

    {:ok, listen_socket} =
      :ssl.listen(0, [:binary, active: false] ++ Keyword.take(server_config, [:cert, :key]))

    {:ok, {_address, port}} = :ssl.sockname(listen_socket)

    accept = fn ->
      {:ok, socket} = :ssl.transport_accept(listen_socket)
      _ = :ssl.handshake(socket)
      # Hold the connection open until the test ends.
      :ssl.recv(socket, 0)
    end

    start_supervised!({Task, accept})

    {port, client_config[:cacerts]}
  end

  defp open_tls_socket(port, ssl_options) do
    "wss://localhost:#{port}/link"
    |> WebSockex.Conn.new(ssl_options: Slack.Socket.ssl_options(ssl_options))
    |> WebSockex.Conn.open_socket()
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
