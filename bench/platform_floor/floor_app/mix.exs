defmodule PlatformFloor.MixProject do
  use Mix.Project

  def project do
    [
      app: :platform_floor,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: true,
      deps: deps()
    ]
  end

  def application do
    [mod: {PlatformFloor.Application, []}, extra_applications: [:logger]]
  end

  defp deps do
    [
      {:cors_plug, "3.0.3"},
      {:finch, "0.23.0"},
      {:phoenix, "1.8.11"},
      {:plug_cowboy, "2.9.0"}
    ]
  end
end
