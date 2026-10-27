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
    {:slack_elixir, "~> 1.3.0"}
  ]
end
```

## Setup
The easiest way to get started is to [create a new Slack app](https://api.slack.com/apps) and
use the following App Manifest to configure all the permissions that are needed:

```yaml
display_information:
  name: YOURBOTNAME
features:
  bot_user:
    display_name: YOURBOTNAME
    always_online: true
oauth_config:
  scopes:
    bot:
      - channels:history
      - channels:read
      - groups:read
      - im:read
      - mpim:read
      - chat:write
settings:
  event_subscriptions:
    bot_events:
      - message.channels
      - member_joined_channel
      - channel_left
  interactivity:
    # Deliver button actions, modal events, and shortcuts through Socket Mode.
    # Shortcuts also need to be declared under `features.shortcuts`, and need
    # the `commands` bot scope.
    is_enabled: true
  org_deploy_enabled: false
  socket_mode_enabled: true
  token_rotation_enabled: false
```

## Manual setup
You will need to:

  - Create a Slack app for your workspace
  - Add permissions (scopes)
  - Connect it to your workspace
  - Get an OAuth Bot Token (will have the scopes you defined)
  - Enable Socket Mode
  - Get an app-level token with `connections:write` scope
  - Add Event Subscriptions
  - Enable Interactivity for buttons, modals, and shortcuts (shortcuts also
    have to be created there, and need the `commands` scope)

The scopes and event subscriptions below support the example bot with channel
management enabled. You can disable channel management with `channels: false`
(see below). Add scopes and subscriptions for the features your bot uses.

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
  def handle_event("message", %{"text" => "!" <> cmd, "channel" => channel, "user" => user}, _bot) do
    case cmd do
      "roll" ->
        send_message(channel, "<@#{user}> rolled a #{Enum.random(1..6)}")

      "echo " <> text ->
        send_message(channel, text)

      _ ->
        send_message(channel, "Unknown command: #{cmd}")
    end
  end

  def handle_event("message", %{"channel" => channel, "text" => text, "user" => user}, _bot) do
    if String.match?(text, ~r/hello/i) do
      send_message(channel, "Hello! <@#{user}>")
    end
  end

  def handle_event(type, payload, _bot) do
    Logger.debug("Unhandled #{type} event: #{inspect(payload)}")
    :ok
  end

  @impl true
  def handle_interaction("block_actions", %{"actions" => actions}, _bot) do
    Enum.each(actions, fn action ->
      Logger.info("Received action: #{action["action_id"]}")
    end)
  end

  def handle_interaction("view_submission", %{"view" => %{"callback_id" => "signup"} = view}, _bot) do
    if get_in(view, ["state", "values", "name", "name_input", "value"]) in [nil, ""] do
      {:reply, %{response_action: "errors", errors: %{name: "Please enter a name"}}}
    else
      :ok
    end
  end

  def handle_interaction(_type, _payload, _bot), do: :ok
end
```

Interactions, such as button clicks, modal submissions and shortcuts, go to the
optional `handle_interaction/3` callback with the payload's `"type"` (for example
`"block_actions"`, `"view_submission"`, `"block_suggestion"`, `"shortcut"` or
`"message_action"`) and the full interaction payload. Every interaction type is
passed on. In these payloads `"user"` is a map, not an ID, and so is `"channel"`
when there is one (modal submissions and global shortcuts have none). The default
`handle_interaction/3` from `use Slack.Bot` acknowledges interactions and ignores
them, so defining your own replaces it: include a catch-all clause.

Most interactions are acknowledged right away and the return value is ignored.
When Slack accepts a response, as for `"view_submission"` and `"block_suggestion"`,
the acknowledgment waits for `handle_interaction/3` for up to 2.5 seconds after the
interaction arrived. Return `{:reply, response}` to send a response with it, such as
modal validation errors or the options for an external select menu. If the callback
raises or takes longer, the interaction isn't acknowledged and Slack shows the user
an error. A slow callback is left to finish, but its reply is dropped, so do slow
work in a separate process.

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

### TLS

The Socket Mode connection verifies Slack's certificate and hostname. It trusts
your operating system's CA certificates (Erlang/OTP 25+). If those can't be
loaded, for example on Alpine without `ca-certificates` or on OTP 24, it falls
back to [CAStore](https://hex.pm/packages/castore) when that is in your
dependencies.

To change this, set `ssl_options` in your bot config. They are
[`:ssl` client options](https://www.erlang.org/doc/apps/ssl/ssl.html#t:tls_client_option/0),
merged over the defaults. Setting `cacerts` or `cacertfile` replaces the default
CA certificates, for example to trust your own CA behind a TLS-inspecting proxy:

```elixir
config :my_app, MyApp.SlackBot,
  # ...
  ssl_options: [cacertfile: "/path/to/ca.pem"]
```

To disable channel discovery and the per-channel message queues, set `channels: false`:

```elixir
config :my_app, MyApp.SlackBot,
  app_token: "MY_SLACK_APP_TOKEN",
  bot_token: "MY_SLACK_BOT_TOKEN",
  bot: MyApp.SlackBot,
  channels: false
```

This skips `users.conversations` at startup, so `channels:read`, `groups:read`,
`im:read`, and `mpim:read` are only needed if your bot uses other features that
require them. Socket Mode and event callbacks remain enabled, including channel
join and leave callbacks. Omitting `channels` keeps the default behavior.

With channel management disabled, use `Slack.API.post("chat.postMessage", bot.token,
%{channel: channel_id, text: "Hello!"})` to send messages with the appropriate scopes.
The `send_message/2` helper requires the per-channel queues and is unavailable in
this mode. Direct API calls must handle rate limits themselves.

## Journey to v1.0 (Things that may or may not be added)

PRs welcome!

- [x] **Socket Mode** for events
- [x] Web API POST requests
- [x] Web API GET requests
- [x] Message Server per channel (rate-limited to 1 message per second per channel).
