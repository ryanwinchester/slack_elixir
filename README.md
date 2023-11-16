# Slack

[![Tests](https://github.com/ryanwinchester/slack_elixir/actions/workflows/ci.yml/badge.svg)](https://github.com/ryanwinchester/slack_elixir/actions/workflows/ci.yml)
 [![Hex.pm](https://img.shields.io/hexpm/v/slack_elixir)](https://hex.pm/packages/slack_elixir)
 [![Hex.pm](https://img.shields.io/hexpm/dt/slack_elixir)](https://hex.pm/packages/slack_elixir)
 [![Hex.pm](https://img.shields.io/hexpm/l/slack_elixir)](https://github.com/ryanwinchester/slack_elixir/blob/main/LICENSE)

This is for creating Slack applications or bots in Elixir.

### Why?

The existing libraries I was looking at use the deprecated RTM API, and no longer work with
new apps or bots.

### What?

To listen for subscribed events, it uses [**Socket Mode**](https://api.slack.com/apis/connections/socket) to connect to Slack.
It has some pros and cons, so please [read up on it](https://api.slack.com/apis/connections/socket) (and pay attention to the info blocks).

It's a relatively thin wrapper, which keeps it flexible and easy to maintain.

### How

 - connects to Slack using a websocket connection to listen for your event subscriptions.
 - uses the [Web API](https://api.slack.com/web) to send messages, etc.
 - uses dynamically supervised gen servers to handle each channel's message rate-limiting with a message queue
   per channel.

## Installation

Add `slack_elixir` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:slack_elixir, "~> 1.1.0"}
  ]
end
```

## Setup

You will need to:

  - Create a Slack app for your workspace
  - Add permissions (scopes)
  - Connect it to your workspace
  - Get an OAuth Bot Token (will have the scopes you defined)
  - Enable Socket Mode
  - Get an app-level token with `connections:write` scope
  - Add Event Subscriptions

See below for some minimum required scopes and event subscriptions. You will
need to add more scopes and subscriptions depending on what you want to do.

#### Required Bot Token scopes:
 - `channels:history`
 - `channels:read`
 - `groups:read`
 - `im:read`
 - `mpim:read`

#### Required Bot Event Subscriptions
 - `message.channels`
 - `member_joined_channel`
 - `channel_left`

## Usage

Write the Bot module:

```elixir
defmodule MyApp.Slackbot do
  use Slack.Bot

  require Logger

  @impl true
  # A silly example of old-school style bot commands.
  def handle_event("message", %{"text" => "!" <> cmd, "channel" => channel, "user" => user}) do
    case cmd do
      "roll" ->
        send_message(channel, "<@#{user}> rolled a #{Enum.random(1..6)}")

      "echo " <> text ->
        send_message(channel, text)

      _ ->
        send_message(channel, "Unknown command: #{cmd}")
    end
  end

  def handle_event("message", %{"channel" => channel, "text" => text, "user" => user}) do
    if String.match?(text, ~r/hello/i) do
      send_message(channel, "Hello! <@#{user}>")
    end
  end

  def handle_event(type, payload) do
    Logger.debug("Unhandled #{type} event: #{inspect(payload)}")
    :ok
  end
end
```

Then you start the Slack Supervisor in your application's supervision tree.

For example:

```elixir
  def start(_type, _args) do
    children = [
      # ...
      {Slack.Supervisor, Application.fetch_env!(:my_app, MyApp.SlackBot)}
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
```

```elixir
# config/runtime.exs

config :my_app, MyApp.SlackBot,
  app_token: "MY_SLACK_APP_TOKEN",
  bot_token: "MY_SLACK_BOT_TOKEN",
  bot: MyApp.SlackBot,
  # Add this if you want to customize the channel types to join.
  # By default we join all channel types: public_channel, private_channel, im, mpim.
  channels: [
    types: ["public_channel", "im", "private_channel"]
  ]
```

## Journey to v1.0 (Things that may or may not be added)

PRs welcome!

- [x] **Socket Mode** for events
- [x] Web API POST requests
- [x] Web API GET requests
- [x] Message Server per channel (rate-limited to 1 message per second per channel).
