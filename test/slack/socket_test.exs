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
    cert_options = [digest: :sha256, key: {:namedCurve, {1, 2, 840, 10045, 3, 1, 7}}]

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
end
