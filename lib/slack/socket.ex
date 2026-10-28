defmodule Slack.Socket do
  @moduledoc false
  # Slack websocket connection for "Socket Mode."
  use WebSockex

  require Logger

  # CAStore is an optional dependency and `cacerts_get/0` needs OTP 25+.
  @compile {:no_warn_undefined, [CAStore, {:public_key, :cacerts_get, 0}]}

  @ping_interval :timer.seconds(30)

  # ----------------------------------------------------------------------------
  # Public API
  # ----------------------------------------------------------------------------

  def start_link({app_token, bot, ssl_options}) do
    state = %{
      app_token: app_token,
      bot: bot,
      alive?: true,
      ping_interval: @ping_interval
    }

    {:ok, %{"url" => url}} = Slack.API.post("apps.connections.open", state.app_token)

    Logger.info("[Slack.Socket] connecting...")

    # WebSockex ignores its top-level TLS options when ssl_options is given.
    WebSockex.start_link(url, __MODULE__, state, ssl_options: ssl_options(ssl_options))
  end

  @doc false
  # Verify the server certificate and hostname by default. The bot config's
  # `:ssl_options` override these key by key.
  def ssl_options(overrides) do
    [
      verify: :verify_peer,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
    |> Keyword.merge(overrides)
    |> put_default_cacerts()
  end

  # ----------------------------------------------------------------------------
  # Callbacks
  # ----------------------------------------------------------------------------

  @impl WebSockex
  def handle_connect(_conn, state) do
    schedule_ping(state)
    {:ok, state}
  end

  @impl WebSockex
  def handle_frame({:text, msg}, state) do
    state = mark_alive(state)

    case Jason.decode(msg) do
      {:ok, %{"type" => "hello"} = hello} ->
        Logger.info("[Slack.Socket] hello: #{inspect(hello)}")
        {:ok, state}

      {:ok, %{"payload" => %{"event" => event}} = msg} ->
        Logger.debug("[Slack.Socket] message: #{inspect(msg)}")

        Task.Supervisor.start_child(
          {:via, PartitionSupervisor, {Slack.TaskSupervisors, self()}},
          fn -> handle_slack_event(event["type"], event, state.bot) end
        )

        {:reply, ack_frame(msg), state}

      {:ok, %{"type" => "slash_commands", "payload" => payload} = msg} ->
        Logger.debug("[Slack.Socket] message: #{inspect(msg)}")

        Task.Supervisor.start_child(
          {:via, PartitionSupervisor, {Slack.TaskSupervisors, self()}},
          fn -> handle_slack_event(msg["type"], payload, state.bot) end
        )

        {:reply, ack_frame(msg), state}

      _ ->
        Logger.debug("[Slack.Socket] Unhandled payload: #{msg}")
        {:ok, state}
    end
  end

  @impl WebSockex
  def handle_frame({type, msg}, state) do
    Logger.debug("[Slack.Socket] unhandled message type: #{inspect(type)}, msg: #{inspect(msg)}")
    {:ok, mark_alive(state)}
  end

  @impl WebSockex
  def handle_ping(:ping, state), do: {:reply, :pong, mark_alive(state)}
  def handle_ping({:ping, msg}, state), do: {:reply, {:pong, msg}, mark_alive(state)}

  @impl WebSockex
  def handle_pong(_pong, state), do: {:ok, mark_alive(state)}

  @impl WebSockex
  def handle_info(:ping_tick, %{alive?: false} = state) do
    Logger.warning(
      "[Slack.Socket] nothing received for #{state.ping_interval}ms, closing to reconnect"
    )

    {:close, state}
  end

  def handle_info(:ping_tick, state) do
    schedule_ping(state)
    {:reply, :ping, %{state | alive?: false}}
  end

  @impl WebSockex
  def handle_cast({:send, {type, msg} = frame}, state) do
    Logger.debug("[Slack.Socket] sending #{type} frame with payload: #{msg}")
    {:reply, frame, state}
  end

  # ----------------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------------

  # Liveness: Slack normally retires a Socket Mode connection with a close
  # frame, which ends this process and lets the supervisor open a fresh one.
  # A connection that dies silently (no close frame, no TCP reset) would leave
  # this process waiting forever, so every `ping_interval` we send a ping and
  # close the connection if nothing at all arrived since the previous tick.
  defp schedule_ping(%{ping_interval: interval}) do
    Process.send_after(self(), :ping_tick, interval)
  end

  defp mark_alive(state), do: %{state | alive?: true}

  # Like Mint, trust the OS certificate store unless the user brought their own
  # CAs or turned verification off, and fall back to CAStore when the OS store
  # can't be loaded (no CA bundle installed, or OTP 24).
  defp put_default_cacerts(opts) do
    if opts[:verify] == :verify_none or Keyword.has_key?(opts, :cacerts) or
         Keyword.has_key?(opts, :cacertfile) do
      opts
    else
      Keyword.merge(opts, default_cacerts())
    end
  end

  # Only the DER binaries: they are shared between processes, whereas the
  # decoded certificates would be copied into the socket process on every
  # connect.
  defp default_cacerts do
    [cacerts: for({:cert, der, _otp} <- :public_key.cacerts_get(), do: der)]
  rescue
    error ->
      if Code.ensure_loaded?(CAStore) do
        [cacertfile: CAStore.file_path()]
      else
        raise """
        [Slack.Socket] could not load the OS CA certificates: #{Exception.message(error)}

        Add `:castore` to your dependencies, or set `ssl_options: [cacertfile: path]` \
        in your Slack bot config.
        """
      end
  end

  # In the case the bot user has JOINED a channel, we need to handle this as a
  # special case.
  defp handle_slack_event(
         "member_joined_channel" = type,
         %{"user" => user} = event,
         %{user_id: user} = bot
       ) do
    Logger.debug("[Slack.Socket] member_joined_channel")
    handle_bot_joined(event, bot)
    bot.module.handle_event(type, event, bot)
  end

  # In the case the bot user has PARTED a channel, we need to handle this as a
  # special case.
  defp handle_slack_event("channel_left" = type, event, bot) do
    Logger.debug("[Slack.Socket] channel_left")
    handle_parted(event, bot)
    bot.module.handle_event(type, event, bot)
  end

  # Ignore messages from yourself...
  defp handle_slack_event("message", %{"user" => user}, %{user_id: user}), do: :ok
  defp handle_slack_event("message", %{"bot_id" => bot_id}, %{bot_id: bot_id}), do: :ok

  # Catch-all case, fall through to bot handler only.
  defp handle_slack_event(type, event, bot) do
    Logger.debug("[Slack.Socket] Sending #{type} event to #{bot.module}")
    bot.module.handle_event(type, event, bot)
  end

  defp handle_bot_joined(%{"channel" => channel} = _event, bot) do
    Slack.ChannelServer.join(bot, channel)
  end

  defp handle_parted(%{"channel" => channel} = _event, bot) do
    Slack.ChannelServer.part(bot, channel)
  end

  defp ack_frame(payload) do
    ack =
      payload
      |> Map.take(["envelope_id"])
      |> Jason.encode!()

    {:text, ack}
  end
end
