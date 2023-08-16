defmodule Slack.Bot do
  @moduledoc """
  The slack bot.
  """

  @doc """
  Handle the event from Slack.

  The return values will be either:

   - `:ok` - No-op, will `ack` immediately.
   - `{:reply, reply}` - where `reply` can be a `t:map/0` or `t:keyword/0` with these
    arguments: https://api.slack.com/methods/chat.postMessage#args

  """
  @callback handle_event(type :: String.t(), payload :: map()) ::
              :ok | {:reply, reply :: keyword() | map()}
end
