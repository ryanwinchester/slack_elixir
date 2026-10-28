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

  @doc """
  Handle an interaction from Slack, such as a button click (`"block_actions"`),
  a modal submission (`"view_submission"`), an external select menu search
  (`"block_suggestion"`), or a shortcut (`"shortcut"`, `"message_action"`).

  `type` is the payload's `"type"`, and every interaction type is passed on.
  `payload` is the full interaction payload. Its `"user"` is a map rather than
  an ID, and so is `"channel"` when there is one (modal submissions and global
  shortcuts have none).

  Most interactions are acknowledged right away and the return value is
  ignored. When Slack accepts a response (as for `"view_submission"` and
  `"block_suggestion"`), the acknowledgment waits for this callback, for up to
  2.5 seconds after the interaction arrived. Return `{:reply, response}` to
  send `response` with it, such as modal validation errors or the menu options,
  or anything else to send none. If the callback raises or takes longer, the
  interaction isn't acknowledged and Slack shows the user an error. A slow
  callback is left to finish, but its reply is dropped, so do slow work in a
  separate process.

  `use Slack.Bot` defines a default that acknowledges interactions and ignores
  them. Defining `handle_interaction/3` replaces it, so include a catch-all
  clause, which can call `super/3`.
  """
  @callback handle_interaction(type :: String.t(), payload :: map(), t()) ::
              {:reply, response :: map()} | any()

  defmacro __using__(_opts) do
    quote do
      import Slack.Bot
      @behaviour Slack.Bot

      @impl Slack.Bot
      def handle_interaction(_type, _payload, _bot), do: :ok

      defoverridable handle_interaction: 3
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
