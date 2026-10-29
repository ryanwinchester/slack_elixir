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
    {ssl_options, bot_config} = Keyword.pop(bot_config, :ssl_options, [])

    if Keyword.has_key?(bot_config, :channels) do
      Logger.warning(
        "[Slack.Supervisor] the :channels option is deprecated and does nothing: " <>
          "a channel's message queue now starts the first time the bot sends to it"
      )
    end

    bot = fetch_identity!(bot_token, bot_module)

    children = [
      # The bot is kept in the metadata, for the message servers to start with.
      {Registry, keys: :unique, name: Slack.MessageServerRegistry, meta: [{bot_module, bot}]},
      {DynamicSupervisor, strategy: :one_for_one, name: Slack.DynamicSupervisor},
      {PartitionSupervisor, child_spec: Task.Supervisor, name: Slack.TaskSupervisors},
      {Slack.Socket, {app_token, bot, ssl_options}}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp fetch_identity!(bot_token, bot_module) do
    case Slack.API.get("auth.test", bot_token) do
      {:ok, %{"ok" => true, "bot_id" => _} = body} ->
        Slack.Bot.from_string_params(bot_module, bot_token, body)

      {_, result} ->
        Logger.error("[Slack.Supervisor] Error fetching user ID: #{inspect(result)}")
        raise "Unable to fetch bot user ID"
    end
  end
end
