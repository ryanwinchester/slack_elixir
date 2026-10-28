defmodule Slack.Socket do
  @moduledoc false
  # Slack websocket connection for "Socket Mode."
  use WebSockex

  require Logger

  # CAStore is an optional dependency and `cacerts_get/0` needs OTP 25+.
  @compile {:no_warn_undefined, [CAStore, {:public_key, :cacerts_get, 0}]}

  @ping_interval :timer.seconds(30)

  # Slack wants an acknowledgment within 3 seconds, so this is how long an
  # interaction handler gets to build a response payload.
  @response_timeout 2_500

  # ----------------------------------------------------------------------------
  # Public API
  # ----------------------------------------------------------------------------

  def start_link({app_token, bot, ssl_options}) do
    state = %{
      app_token: app_token,
      bot: bot,
      alive?: true,
      ping_interval: @ping_interval,
      response_timeout: @response_timeout
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

      {:ok, %{"type" => "disconnect"} = disconnect} ->
        # Slack closes the connection next, and the supervisor reconnects.
        Logger.info("[Slack.Socket] disconnect: #{disconnect["reason"]}")
        {:ok, state}

      {:ok, %{"envelope_id" => envelope_id} = envelope} ->
        # Payloads can hold user input and response URLs, so don't log them.
        Logger.debug("[Slack.Socket] #{envelope["type"]} envelope: #{envelope_id}")
        handle_envelope(envelope, state)

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
  def handle_cast({:send, {type, _msg} = frame}, state) do
    # Replies can echo user input, so don't log them.
    Logger.debug("[Slack.Socket] sending #{type} frame")
    {:reply, frame, state}
  end

  # ----------------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------------

  # Events and slash commands go to `handle_event/3`, interactions to the
  # optional `handle_interaction/3`. Envelopes we don't handle are still
  # acknowledged so Slack doesn't retry them.
  defp handle_envelope(
         %{"type" => "events_api", "payload" => %{"event" => event}} = envelope,
         state
       ) do
    dispatch(envelope, state, fn -> handle_slack_event(event["type"], event, state.bot) end)
  end

  defp handle_envelope(%{"type" => "slash_commands", "payload" => payload} = envelope, state) do
    dispatch(envelope, state, fn -> handle_slack_event("slash_commands", payload, state.bot) end)
  end

  defp handle_envelope(
         %{"type" => "interactive", "payload" => %{"type" => type} = payload} = envelope,
         %{bot: bot} = state
       ) do
    handle_interaction = fn -> bot.module.handle_interaction(type, payload, bot) end

    if envelope["accepts_response_payload"] do
      respond(envelope, type, state, handle_interaction)
    else
      dispatch(envelope, state, handle_interaction)
    end
  end

  defp handle_envelope(envelope, state) do
    Logger.warning(
      "[Slack.Socket] acknowledged and ignored unhandled " <>
        "#{envelope["type"]} envelope: #{envelope["envelope_id"]}"
    )

    {:reply, ack_frame(envelope), state}
  end

  # Acknowledge once the handler is running. If it can't be started, don't, so
  # Slack retries the envelope or shows the user an error.
  defp dispatch(envelope, state, fun) do
    case start_task(envelope, fun) do
      :ok -> {:reply, ack_frame(envelope), state}
      :error -> {:ok, state}
    end
  end

  # Slack accepts a response payload with this acknowledgment, so wait for the
  # handler and send `{:reply, response}` with it. If the handler crashes or
  # runs out of time, don't acknowledge, so Slack shows the user an error
  # instead of the interaction being silently dropped.
  defp respond(%{"envelope_id" => envelope_id} = envelope, type, state, fun) do
    socket = self()
    response_timeout = state.response_timeout
    # Slack's clock started when the envelope arrived, not when the handler starts.
    deadline = System.monotonic_time(:millisecond) + response_timeout
    not_acknowledged = "[Slack.Socket] #{type} #{envelope_id} not acknowledged"

    await_response = fn ->
      task = Task.Supervisor.async_nolink(task_supervisor(envelope), fun)
      timeout = max(deadline - System.monotonic_time(:millisecond), 0)

      # A handler that runs out of time is left to finish, not killed halfway.
      case Task.yield(task, timeout) || Task.ignore(task) do
        {:ok, {:reply, response}} ->
          send_ack(socket, envelope, response, not_acknowledged)

        {:ok, _} ->
          send_ack(socket, envelope, nil, not_acknowledged)

        {:exit, reason} ->
          Logger.error("#{not_acknowledged}: handler exited: #{exit_reason(reason)}")

        nil ->
          Logger.error("#{not_acknowledged}: handler took longer than #{response_timeout}ms")
      end
    end

    _ = start_task(envelope, await_response)
    {:ok, state}
  end

  defp send_ack(socket, envelope, response, not_acknowledged) do
    WebSockex.cast(socket, {:send, ack_frame(envelope, response)})
  rescue
    error in [Jason.EncodeError, Protocol.UndefinedError] ->
      Logger.error(
        "#{not_acknowledged}: the reply can't be encoded as JSON (#{inspect(error.__struct__)})"
      )
  end

  defp exit_reason({exception, _stacktrace}) when is_exception(exception) do
    Exception.message(exception)
  end

  defp exit_reason(reason), do: inspect(reason)

  defp start_task(envelope, fun) do
    result =
      try do
        Task.Supervisor.start_child(task_supervisor(envelope), fun)
      catch
        # The task supervisor isn't running, for example while restarting.
        :exit, reason -> {:exit, reason}
      end

    case result do
      {:ok, _pid} ->
        :ok

      error ->
        Logger.error(
          "[Slack.Socket] could not handle #{envelope["type"]} #{envelope["envelope_id"]}: " <>
            inspect(error)
        )

        :error
    end
  end

  # Key by envelope so handlers spread over all the task supervisor partitions.
  defp task_supervisor(%{"envelope_id" => envelope_id}) do
    {:via, PartitionSupervisor, {Slack.TaskSupervisors, envelope_id}}
  end

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
        reraise RuntimeError,
                [
                  message: """
                  [Slack.Socket] could not load the OS CA certificates: #{Exception.message(error)}

                  Add `:castore` to your dependencies, or set `ssl_options: [cacertfile: path]` \
                  in your Slack bot config.
                  """
                ],
                __STACKTRACE__
      end
  end

  # Ignore messages from yourself...
  defp handle_slack_event("message", %{"user" => user}, %{user_id: user}), do: :ok
  defp handle_slack_event("message", %{"bot_id" => bot_id}, %{id: bot_id}), do: :ok

  # Catch-all case, fall through to bot handler only.
  defp handle_slack_event(type, event, bot) do
    Logger.debug("[Slack.Socket] Sending #{type} event to #{bot.module}")
    bot.module.handle_event(type, event, bot)
  end

  defp ack_frame(envelope, response \\ nil) do
    ack = Map.take(envelope, ["envelope_id"])
    ack = if response, do: Map.put(ack, "payload", response), else: ack

    {:text, Jason.encode!(ack)}
  end
end
