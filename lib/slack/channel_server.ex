defmodule Slack.ChannelServer do
  @moduledoc false
  use GenServer

  require Logger

  # This is fairly arbitrary, but we'll hibernate this process after 5 minutes
  # of waiting for any incoming messages.
  @hibernate_ms :timer.minutes(5)

  # ----------------------------------------------------------------------------
  # Public API
  # ----------------------------------------------------------------------------

  def start_link({token, bot}) do
    Logger.info("[Slack.ChannelServer] starting for #{bot.bot_module}...")

    GenServer.start_link(__MODULE__, {token, bot},
      hibernate_after: @hibernate_ms,
      name: via_tuple(bot)
    )
  end

  def join(bot, channel) do
    GenServer.cast(via_tuple(bot), {:join, channel})
  end

  def part(bot, channel) do
    GenServer.cast(via_tuple(bot), {:part, channel})
  end

  # ----------------------------------------------------------------------------
  # GenServer Callbacks
  # ----------------------------------------------------------------------------

  @impl true
  def init({token, bot}) do
    state = %{
      bot: bot,
      channels: fetch_channels(token),
      token: token
    }

    {:ok, state, {:continue, :join}}
  end

  @impl true
  def handle_continue(:join, state) do
    Enum.each(state.channels, &join(state.bot, &1))
    {:noreply, state}
  end

  @impl true
  def handle_cast({:join, channel}, state) do
    Logger.info("[Slack.ChannelServer] #{state.bot.bot_module} joining #{channel}...")
    {:ok, _} = Slack.MessageServer.start_supervised(state.token, state.bot, channel)
    {:noreply, Map.update!(state, :channels, &[channel | &1])}
  end

  def handle_cast({:part, channel}, state) do
    Logger.info("[Slack.ChannelServer] #{state.bot.bot_module} leaving #{channel}...")
    :ok = Slack.MessageServer.stop(state.bot, channel)
    {:noreply, Map.update!(state, :channels, &List.delete(&1, channel))}
  end

  defp via_tuple(%Slack.Bot{bot_module: bot}) do
    {:via, Registry, {Slack.ChannelServerRegistry, bot}}
  end

  defp fetch_channels(token) do
    "users.conversations"
    |> Slack.API.stream(token, "channels")
    |> Enum.map(& &1["id"])
  end
end
