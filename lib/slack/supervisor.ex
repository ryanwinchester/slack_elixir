defmodule Slack.Supervisor do
  @moduledoc """
  Supervisor that starts the Socket.
  (And potentially an API genserver, if we need to rate-limit ourselves).
  """
  use Supervisor

  require Logger

  def start_link(bot_config) do
    Supervisor.start_link(__MODULE__, bot_config)
  end

  @impl true
  def init(bot_config) do
    app_token = Keyword.fetch!(bot_config, :app_token)
    bot_token = Keyword.fetch!(bot_config, :bot_token)
    bot_module = Keyword.fetch!(bot_config, :bot)
    bot = fetch_identity!(bot_token, bot_module)

    children = [
      {Registry, keys: :unique, name: Slack.ChannelServerRegistry},
      {Registry, keys: :unique, name: Slack.MessageServerRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: Slack.DynamicSupervisor},
      {PartitionSupervisor, child_spec: Task.Supervisor, name: Slack.TaskSupervisors},
      {Slack.ChannelServer, {bot_token, bot}},
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
