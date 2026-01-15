defmodule Slack.Supervisor do
  @moduledoc """
  Supervisor that starts the stuff that needs to run.
  """
  use Supervisor

  require Logger

  @doc """
  Start the Slack bot supervisor.
  See `README` for instructions.
  """
  @spec start_link(config :: keyword()) :: Supervisor.on_start()
  def start_link(bot_config) do
    Supervisor.start_link(__MODULE__, bot_config)
  end

  @impl true
  def init(bot_config) do
    app_token = Keyword.fetch!(bot_config, :app_token)
    bot = case Keyword.fetch(bot_config, :bot_config) do
      {:ok, bot} -> bot
      _ ->
        bot_token = Keyword.fetch!(bot_config, :bot_token)
        bot_module = Keyword.fetch!(bot_config, :bot)
        {:ok, bot} = fetch_identity(bot_module, bot_token)
        bot
    end

    {channel_config, bot_config} = Keyword.pop(bot_config, :channels, [])

    children = [
      {Registry, keys: :unique, name: Slack.ChannelServerRegistry},
      {Registry, keys: :unique, name: Slack.MessageServerRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: Slack.DynamicSupervisor},
      {PartitionSupervisor, child_spec: Task.Supervisor, name: Slack.TaskSupervisors},
      {Slack.ChannelServer, {bot, channel_config}},
      {Slack.Socket, bot_config}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def fetch_identity(bot_module, bot_token) do
    case Slack.API.get("auth.test", bot_token) do
      {:ok, %{"ok" => true, "bot_id" => _} = body} ->
        {:ok, Slack.Bot.from_string_params(bot_module, bot_token, body)}

      {_, result} ->
        Logger.error("[Slack.Supervisor] Error fetching user ID: #{inspect(result)}")
        {:error, "Error fetching Slack user ID: #{inspect(result)}"}
    end
  end
end
