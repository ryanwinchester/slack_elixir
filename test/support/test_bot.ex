defmodule Slack.TestBot do
  @moduledoc """
  Test bot implementation.
  """
  use Slack.Bot

  @impl Slack.Bot
  def handle_event("message", %{"text" => text}) do
    if String.contains?(text, "hello") do
      send_message("channel-foo", "hello back!")
    end
  end

  def handle_event(_type, _payload), do: :noop
end
