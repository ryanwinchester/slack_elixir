defmodule Slack.ChannelServer do
  @moduledoc false
  use GenServer

  require Logger

  # By default the bot will join all conversations that it has access to.
  # For type options, see: [api](https://api.slack.com/methods/users.conversations).
  # Note, these require the following scopes:
  #   `channels:read`, `groups:read`, `im:read`, `mpim:read`
  @default_channel_types "public_channel,private_channel,mpim,im"

  # ----------------------------------------------------------------------------
  # Public API
  # ----------------------------------------------------------------------------

  def start_link({bot, config}) do
    Logger.info("[Slack.ChannelServer] starting for #{bot.module}...")

    # This should be a comma-separated string.
    channel_types =
      case Keyword.get(config, :types) do
        nil -> @default_channel_types
        types when is_binary(types) -> types
        types when is_list(types) -> Enum.join(types, ",")
      end

    channels = fetch_channels(bot.token, channel_types)

    GenServer.start_link(__MODULE__, {bot, channels}, name: via_tuple(bot))
  end

  def join(bot, channel) do
    GenServer.cast(via_tuple(bot), {:join, channel})
  end

  def part(bot, channel) do
    GenServer.cast(via_tuple(bot), {:part, channel})
  end

  # Joins the channel if the bot hasn't yet, and returns its message server.
  # A join that's already on its way from the same process is handled first.
  def message_server(bot, channel) do
    GenServer.call(via_tuple(bot), {:join, channel})
  catch
    :exit, reason -> {:error, reason}
  end

  # ----------------------------------------------------------------------------
  # GenServer Callbacks
  # ----------------------------------------------------------------------------

  @impl true
  def init({bot, channels}) do
    state = %{
      bot: bot,
      channels: channels
    }

    {:ok, state, {:continue, :join}}
  end

  # The channels are already in the state, so only start their message servers.
  @impl true
  def handle_continue(:join, state) do
    Enum.each(state.channels, &start_message_server(state.bot, &1))
    {:noreply, state}
  end

  @impl true
  def handle_call({:join, channel}, _from, state) do
    {message_server, state} = join_channel(state, channel)
    {:reply, {:ok, message_server}, state}
  end

  @impl true
  def handle_cast({:join, channel}, state) do
    {_message_server, state} = join_channel(state, channel)
    {:noreply, state}
  end

  def handle_cast({:part, channel}, state) do
    Logger.info("[Slack.ChannelServer] #{state.bot.module} leaving #{channel}...")
    :ok = Slack.MessageServer.stop(state.bot, channel)
    {:noreply, Map.update!(state, :channels, &List.delete(&1, channel))}
  end

  defp join_channel(state, channel) do
    message_server = start_message_server(state.bot, channel)

    if channel in state.channels do
      {message_server, state}
    else
      {message_server, Map.update!(state, :channels, &[channel | &1])}
    end
  end

  # The message server can already be running, for example when this server
  # restarted, or the channel got a message before the join arrived.
  defp start_message_server(bot, channel) do
    case Slack.MessageServer.start_supervised(bot, channel) do
      {:ok, message_server} ->
        Logger.info("[Slack.ChannelServer] #{bot.module} joined #{channel}")
        message_server

      {:error, {:already_started, message_server}} ->
        message_server
    end
  end

  defp via_tuple(%Slack.Bot{module: bot}), do: via_tuple(bot)
  defp via_tuple(bot), do: {:via, Registry, {Slack.ChannelServerRegistry, bot}}

  defp fetch_channels(token, types) when is_binary(types) do
    "users.conversations"
    |> Slack.API.stream(token, "channels", types: types)
    |> Enum.map(& &1["id"])
    |> Enum.uniq()
  end
end
