defmodule Slack.Bot do
  @moduledoc """
  The Slack Bot.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          module: module(),
          team_id: String.t(),
          token: String.t(),
          user_id: String.t()
        }

  @derive {Inspect, except: [:token]}
  @enforce_keys [:id, :module, :token, :team_id, :user_id]
  defstruct [:id, :module, :token, :team_id, :user_id]

  @doc """
  Handle the event from Slack.
  Return value is ignored.
  """
  @callback handle_event(type :: String.t(), payload :: map(), t()) :: any()

  defmacro __using__(_opts) do
    quote do
      import Slack.Bot
      @behaviour Slack.Bot
    end
  end

  # Build a Bot struct from a string-keyed map.
  @doc false
  def from_string_params(bot_module, bot_token, params) do
    %__MODULE__{
      id: Map.fetch!(params, "bot_id"),
      module: bot_module,
      team_id: Map.fetch!(params, "team_id"),
      token: bot_token,
      user_id: Map.fetch!(params, "user_id")
    }
  end

  @doc """
  Send a message to a channel.

  The `message` can be just the message text, or a `t:map/0` of properties that
  are accepted by Slack's `chat.postMessage` API endpoint.
  """
  @spec send_message(String.t(), String.t() | map()) :: Macro.t()
  defmacro send_message(channel, message) do
    quote do
      Slack.MessageServer.send(__MODULE__, unquote(channel), unquote(message))
    end
  end
end
