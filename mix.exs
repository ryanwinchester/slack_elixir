defmodule Slack.MixProject do
  use Mix.Project

  @version "1.0.0"
  @source_url "https://github.com/ryanwinchester/slack_elixir"

  def project do
    [
      app: :slack_elixir,
      version: @version,
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: [plt_file: {:no_warn, "priv/plts/project.plt"}],
      description: description(),
      docs: docs(),
      package: package(),
      name: "Slack Elixir",
      source_url: @source_url
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

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
      maintainers: ["Ryan Winchester"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}",
      api_reference: false,
      extras: [
        "README.md"
      ]
    ]
  end
end
