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

  def start_supervised(bot, channel) do
    DynamicSupervisor.start_child(
      Slack.DynamicSupervisor,
      {Slack.MessageServer, {bot, channel}}
    )
  end

  # A channel the bot hasn't joined yet, like a new DM, gets a message server
  # first, so messages aren't dropped without a trace.
  def send(bot, channel, message) when is_binary(channel) do
    case message_server(bot, channel) do
      {:ok, message_server} ->
        GenServer.cast(message_server, {:add, message})

      {:error, :no_message_queues} = error ->
        Logger.error("""
        [Slack.MessageServer] message to #{channel} not sent: there are no message \
        queues, because channel management is disabled with `channels: false` (use \
        post_message/3 instead), or Slack.Supervisor isn't running.
        """)

        error

      {:error, reason} = error ->
        Logger.error("[Slack.MessageServer] message to #{channel} not sent: #{inspect(reason)}")
        error
    end
  end

  # Stop it through the supervisor, which would otherwise restart it.
  def stop(bot, channel) do
    case GenServer.whereis(via_tuple(bot, channel)) do
      nil ->
        :ok

      message_server ->
        _ = DynamicSupervisor.terminate_child(Slack.DynamicSupervisor, message_server)
        :ok
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
      timer_ref: schedule_next()
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
        send_message(state.bot, state.channel, message)
        %{state | queue: rest, timer_ref: schedule_next()}
    end
  end

  defp send_message(bot, channel, message) do
    case Slack.Bot.post_message(bot, channel, message) do
      {:ok, _} ->
        Logger.debug("[Slack.MessageServer] SENT: #{inspect(message)}")

      {:error, error} ->
        Logger.error("[Slack.MessageServer] error sending message #{inspect(error)}")
    end
  end

  defp message_server(bot, channel) do
    if Process.whereis(Slack.MessageServerRegistry) do
      case GenServer.whereis(via_tuple(bot, channel)) do
        nil -> Slack.ChannelServer.message_server(bot, channel)
        message_server -> {:ok, message_server}
      end
    else
      {:error, :no_message_queues}
    end
  end

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
