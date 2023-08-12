defmodule Slack.Supervisor do
  @moduledoc """
  Supervisor that starts the Socket.
  (And potentially an API genserver, if we need to rate-limit ourselves).
  """
  use Supervisor

  def start_link(config) do
    Supervisor.start_link(__MODULE__, config, name: __MODULE__)
  end

  @impl true
  def init(config) do
    children = [
      {Slack.Socket, config}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
