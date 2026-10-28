defmodule Slack.MessageServer do
  @moduledoc false
  use GenServer

  require Logger

  # Slack has a rate-limit of 1 message per second per channel.
  @message_rate_ms :timer.seconds(1)

  # ----------------------------------------------------------------------------
  # Public API
  # ----------------------------------------------------------------------------

  def start_link({bot, channel}) do
    Logger.info("[Slack.MessageServer] starting for #{bot.module} in #{channel}...")
    GenServer.start_link(__MODULE__, {bot, channel}, name: via_tuple(bot, channel))
  end

  # Queues the message on the channel's message server, which starts the first
  # time the bot sends to the channel.
  def send(bot_module, channel, message) when is_atom(bot_module) and is_binary(channel) do
    case message_server(bot_module, channel) do
      {:ok, message_server} ->
        GenServer.cast(message_server, {:add, message})

      {:error, reason} = error ->
        Logger.error(
          "[Slack.MessageServer] message to #{channel} not sent: " <>
            error_message(reason, bot_module)
        )

        error
    end
  end

  # ----------------------------------------------------------------------------
  # GenServer Callbacks
  # ----------------------------------------------------------------------------

  @impl true
  def init({bot, channel}) do
    state = %{
      bot: bot,
      channel: channel,
      queue: :queue.new(),
      # Paused, so the first message is sent right away.
      timer_ref: nil
    }

    {:ok, state}
  end

  @impl true
  # If we are paused, we will add it to the queue and start scheduling messages.
  def handle_cast({:add, message}, %{timer_ref: nil} = state) do
    Logger.debug("[Slack.MessageServer] Adding message #{inspect(message)}")
    state = send_and_schedule_next(%{state | queue: :queue.in(message, state.queue)})
    {:noreply, state}
  end

  # It is not paused, so that means we are still scheduling messages, so we will
  # just add the message to queue.
  def handle_cast({:add, message}, state) do
    Logger.debug("[Slack.MessageServer] Adding message #{inspect(message)}")
    state = %{state | queue: :queue.in(message, state.queue)}
    {:noreply, state}
  end

  @impl true
  def handle_info(:send, state) do
    {:noreply, send_and_schedule_next(state)}
  end

  # ----------------------------------------------------------------------------
  # Private API
  # ----------------------------------------------------------------------------

  defp send_and_schedule_next(state) do
    case :queue.out(state.queue) do
      {:empty, _} ->
        Logger.debug("[Slack.MessageServer] [#{state.channel}] no more messages to send: PAUSED")
        %{state | timer_ref: nil}

      {{:value, message}, rest} ->
        Logger.debug("[Slack.MessageServer] Sending next message: #{inspect(message)}")
        send_message(state.bot.token, state.channel, message)
        %{state | queue: rest, timer_ref: schedule_next()}
    end
  end

  # Users can send a message either as string, or as a keyword/map of args.
  # When they send it as a string, we'll put it into a map, with the `:text`
  # key. The args are assumed to be any arg that is accepted by Slack's
  # `chat.postMessage` API endpoint.
  defp send_message(token, channel, message) when is_binary(message) do
    send_message(token, %{channel: channel, text: message})
  end

  defp send_message(token, channel, message) do
    send_message(token, Enum.into(message, %{channel: channel}))
  end

  defp send_message(token, %{} = args) do
    case Slack.API.post("chat.postMessage", token, args) do
      {:ok, _} ->
        Logger.debug("[Slack.MessageServer] SENT: #{inspect(args)}")

      {:error, error} ->
        Logger.error("[Slack.MessageServer] error sending message #{inspect(error)}")
    end
  end

  defp message_server(bot_module, channel) do
    case Registry.lookup(Slack.MessageServerRegistry, {bot_module, channel}) do
      [{message_server, _value}] -> {:ok, message_server}
      [] -> start_message_server(bot_module, channel)
    end
  rescue
    # Slack.Supervisor starts the registry, so it isn't running.
    ArgumentError -> {:error, :not_started}
  end

  defp start_message_server(bot_module, channel) do
    # Slack.Supervisor keeps the bot in the registry's metadata.
    with {:ok, bot} <- registered_bot(bot_module) do
      case DynamicSupervisor.start_child(Slack.DynamicSupervisor, {__MODULE__, {bot, channel}}) do
        # Another process started it first.
        {:error, {:already_started, message_server}} -> {:ok, message_server}
        result -> result
      end
    end
  end

  defp registered_bot(bot_module) do
    case Registry.meta(Slack.MessageServerRegistry, bot_module) do
      {:ok, bot} -> {:ok, bot}
      :error -> {:error, :unknown_bot}
    end
  end

  defp error_message(:not_started, _bot_module), do: "Slack.Supervisor isn't running"

  defp error_message(:unknown_bot, bot_module),
    do: "#{inspect(bot_module)} isn't the bot started by Slack.Supervisor"

  defp error_message(reason, _bot_module), do: inspect(reason)

  defp schedule_next(after_ms \\ @message_rate_ms) do
    Process.send_after(self(), :send, after_ms)
  end

  defp via_tuple(%Slack.Bot{module: bot}, channel) do
    via_tuple(bot, channel)
  end

  defp via_tuple(bot, channel) do
    {:via, Registry, {Slack.MessageServerRegistry, {bot, channel}}}
  end
end
