defmodule Slack.Socket do
  @moduledoc false
  # Slack websocket connection for "Socket Mode."
  use WebSockex

  require Logger

  @ping_interval :timer.seconds(30)

  # Slack wants an acknowledgment within 3 seconds, so this is how long an
  # interaction handler gets to build a response payload.
  @response_timeout 2_500

  # ----------------------------------------------------------------------------
  # Public API
  # ----------------------------------------------------------------------------

  def start_link({app_token, bot}) do
    state = %{
      app_token: app_token,
      bot: bot,
      alive?: true,
      ping_interval: @ping_interval,
      response_timeout: @response_timeout
    }

    {:ok, %{"url" => url}} = Slack.API.post("apps.connections.open", state.app_token)

    Logger.info("[Slack.Socket] connecting...")

    WebSockex.start_link(url, __MODULE__, state)
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
  def handle_cast({:send, {type, msg} = frame}, state) do
    Logger.debug("[Slack.Socket] sending #{type} frame with payload: #{msg}")
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

    cond do
      not handles_interactions?(bot.module) -> {:reply, ack_frame(envelope), state}
      envelope["accepts_response_payload"] -> respond(envelope, state, handle_interaction)
      true -> dispatch(envelope, state, handle_interaction)
    end
  end

  defp handle_envelope(envelope, state), do: {:reply, ack_frame(envelope), state}

  defp handles_interactions?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :handle_interaction, 3)
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
  defp respond(%{"envelope_id" => envelope_id} = envelope, state, fun) do
    socket = self()
    type = envelope["payload"]["type"]

    await_response = fn ->
      task = Task.Supervisor.async_nolink(task_supervisor(envelope), fun)

      case Task.yield(task, state.response_timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:reply, response}} ->
          WebSockex.cast(socket, {:send, ack_frame(envelope, response)})

        {:ok, _} ->
          WebSockex.cast(socket, {:send, ack_frame(envelope)})

        {:exit, _reason} ->
          Logger.error("[Slack.Socket] #{type} #{envelope_id} not acknowledged: handler crashed")

        nil ->
          Logger.error(
            "[Slack.Socket] #{type} #{envelope_id} not acknowledged: " <>
              "handler took longer than #{state.response_timeout}ms"
          )
      end
    end

    _ = start_task(envelope, await_response)
    {:ok, state}
  end

  defp start_task(envelope, fun) do
    case Task.Supervisor.start_child(task_supervisor(envelope), fun) do
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
  defp handle_slack_event("message", %{"bot_id" => bot_id}, %{id: bot_id}), do: :ok

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

  defp ack_frame(envelope, response) do
    ack =
      envelope
      |> Map.take(["envelope_id"])
      |> Map.put("payload", response)
      |> Jason.encode!()

    {:text, ack}
  end
end
