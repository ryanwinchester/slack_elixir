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
    {app_token, bot_config} = Keyword.pop!(bot_config, :app_token)
    {bot_token, bot_config} = Keyword.pop!(bot_config, :bot_token)
    {bot_module, bot_config} = Keyword.pop!(bot_config, :bot)
    {channel_config, _bot_config} = Keyword.pop(bot_config, :channels, [])

    bot = fetch_identity!(bot_token, bot_module)

    children = [
      {Registry, keys: :unique, name: Slack.ChannelServerRegistry},
      {Registry, keys: :unique, name: Slack.MessageServerRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: Slack.DynamicSupervisor},
      {PartitionSupervisor, child_spec: Task.Supervisor, name: Slack.TaskSupervisors},
      {Slack.ChannelServer, {bot_token, bot, channel_config}},
      {Slack.Socket, {app_token, bot_token, bot}}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp fetch_identity!(token, bot_module) do
    case Slack.API.get("auth.test", token) do
      {:ok, %{"ok" => true, "bot_id" => _} = body} ->
        Slack.Bot.from_string_params(bot_module, body)

      {_, result} ->
        Logger.error("[Slack.Supervisor] Error fetching user ID: #{inspect(result)}")
        raise "Unable to fetch bot user ID"
    end
  end
end
