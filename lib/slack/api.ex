defmodule Slack.API do
  @moduledoc """
  Slack Web API.
  """

  require Logger

  @base_url "https://slack.com/api"

  @doc """
  Req client for Slack API.
  """
  @spec client(String.t()) :: Req.Request.t()
  def client(token) do
    headers = [
      {"authorization", "Bearer #{token}"}
    ]

    Req.new(base_url: @base_url, headers: headers)
  end

  @doc """
  POST to Slack API.
  """
  @spec post(String.t(), String.t(), map() | keyword()) :: {:ok, map()} | {:error, term()}
  def post(endpoint, token, args \\ %{}) do
    result =
      Req.post(client(token),
        url: endpoint,
        form: args
      )

    case result do
      {:ok, %{body: %{"ok" => true} = body}} ->
        {:ok, body}

      {_, error} ->
        Logger.error(inspect(error))
        {:error, error}
    end
  end
end
