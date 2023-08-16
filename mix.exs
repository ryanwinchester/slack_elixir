defmodule Slack.MixProject do
  use Mix.Project

  def project do
    [
      app: :slack_elixir,
      version: "0.1.1",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: [plt_file: {:no_warn, "priv/plts/project.plt"}],
      description: description(),
      package: package(),
      name: "Slack Elixir",
      source_url: "https://github.com/ryanwinchester/slack_elixir"
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:req, "~> 0.3.0"},
      {:websockex, "~> 0.4.3"},
      {:ex_doc, "~> 0.27", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.3", only: [:dev], runtime: false},
      {:mimic, "~> 1.7", only: :test}
    ]
  end

  defp description do
    "Slack for Elixir using Socket Mode and Web API"
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/ryanwinchester/slack_elixir"}
    ]
  end
end
