defmodule Slack.Socket do
  @moduledoc """
  Slack websocket connection for "Socket Mode."
  """
  use WebSockex

  require Logger

  def start_link(config) do
    state = %{
      app_token: Keyword.fetch!(config, :app_token),
      bot_token: Keyword.fetch!(config, :bot_token),
      bot: Keyword.fetch!(config, :bot)
    }

    {:ok, %{"url" => url}} = Slack.API.post("apps.connections.open", state.app_token)

    Logger.info("[Socket] connecting...")

    WebSockex.start_link(url, __MODULE__, state)
  end

  def handle_frame({:text, msg}, state) do
    case Jason.decode(msg) do
      {:ok, %{"type" => "hello"} = hello} ->
        Logger.info("[Socket] hello: #{inspect(hello)}")
        {:ok, state}

      {:ok, %{"payload" => %{"event" => event}} = msg} ->
        Logger.debug("[Socket] message: #{inspect(msg)}")

        case state.bot.handle_event(event["type"], event) do
          {:reply, response} ->
            Slack.API.post("chat.postMessage", state.bot_token, response)

          :ok ->
            :noop
        end

        {:reply, ack_frame(msg), state}

      _ ->
        Logger.debug("[Socket] Unhandled payload: #{msg}")
        {:ok, state}
    end
  end

  def handle_frame({type, msg}, state) do
    Logger.debug("[Socket] unhandled message type: #{inspect(type)}, msg: #{inspect(msg)}")
    {:ok, state}
  end

  def handle_cast({:send, {type, msg} = frame}, state) do
    IO.puts("Sending #{type} frame with payload: #{msg}")
    {:reply, frame, state}
  end

  defp ack_frame(payload) do
    ack =
      payload
      |> Map.take(["envelope_id"])
      |> Jason.encode!()

    {:text, ack}
  end
end
