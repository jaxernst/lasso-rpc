defmodule Livechain.MixProject do
  use Mix.Project

  def project do
    [
      app: :livechain,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Livechain.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jason, "~> 1.4"},
      {:websockex, "~> 0.4"},
      {:phoenix, "~> 1.7"},
      {:phoenix_pubsub, "~> 2.1"},
      {:phoenix_live_view, "~> 0.20"},
      {:phoenix_html, "~> 3.3"},
      {:gettext, "~> 0.20"},
      {:plug_cowboy, "~> 2.5"},
      {:broadway, "~> 1.0"},
      {:yaml_elixir, "~> 2.9"},
      {:phoenix_live_dashboard, "~> 0.8", only: :dev},
      {:telemetry_metrics, "~> 0.6"},
      {:telemetry_poller, "~> 1.0"}
    ]
  end
end
