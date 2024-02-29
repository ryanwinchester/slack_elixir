defmodule Slack.MessageServer do
  @moduledoc false
  use GenServer

  require Logger

  # Slack has a rate-limit of 1 message per second per channel.
  @message_rate_ms :timer.seconds(1)

  # ----------------------------------------------------------------------------
  # Public API
  # ----------------------------------------------------------------------------

  def start_link({token, bot, channel}) do
    Logger.info("[Slack.MessageServer] starting for #{bot.bot_module} in #{channel}...")
    GenServer.start_link(__MODULE__, {token, bot, channel}, name: via_tuple(bot, channel))
  end

  def start_supervised(token, bot, channel) do
    DynamicSupervisor.start_child(
      Slack.DynamicSupervisor,
      {Slack.MessageServer, {token, bot, channel}}
    )
  end

  def send(bot, channel, message) when is_binary(channel) do
    GenServer.cast(via_tuple(bot, channel), {:add, message})
  end

  def stop(bot, channel) do
    GenServer.stop(via_tuple(bot, channel))
  end

  # ----------------------------------------------------------------------------
  # GenServer Callbacks
  # ----------------------------------------------------------------------------

  @impl true
  def init({token, bot, channel}) do
    state = %{
      bot: bot,
      channel: channel,
      queue: :queue.new(),
      timer_ref: schedule_next(),
      token: token
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
        send_message(state.token, state.channel, message)
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

  defp schedule_next(after_ms \\ @message_rate_ms) do
    Process.send_after(self(), :send, after_ms)
  end

  defp via_tuple(%Slack.Bot{bot_module: bot}, channel) do
    via_tuple(bot, channel)
  end

  defp via_tuple(bot, channel) do
    {:via, Registry, {Slack.MessageServerRegistry, {bot, channel}}}
  end
end
