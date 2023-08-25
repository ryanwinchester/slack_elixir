defmodule ReadmeTest do
  use ExUnit.Case, async: true

  test "versions match" do
    readme = Path.join(__DIR__, "../README.md") |> File.read!()
    version = Mix.Project.config()[:version]
    assert readme =~ ~s({:slack_elixir, "~> #{version}"})
  end
end
