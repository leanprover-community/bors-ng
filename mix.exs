defmodule BorsNg.Mixfile do
  use Mix.Project

  def project do
    [
      name: "Bors-NG",
      app: :bors,
      version: "0.1.0",
      source_url: "https://github.com/bors-ng/bors-ng",
      homepage_url: "https://bors.tech/",
      docs: [
        main: "hacking",
        extras: ["HACKING.md", "CONTRIBUTING.md", "README.md"]
      ],
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: [
        flags: [
          "-Wno_unused",
          "-Werror_handling"
        ],
        plt_add_apps: [:mix]
      ]
    ]
  end

  # Configuration for the OTP application.
  def application do
    [mod: {BorsNG.Application, []}, extra_applications: [:logger]]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run ecto setup before running tests.
  defp aliases do
    [
      test: ["ecto.create --quiet", "ecto.migrate", "test"]
    ]
  end

  # Dependencies can be Hex packages:
  #
  #   {:my_dep, "~> 0.3.0"}
  #
  # Or git/path repositories:
  #
  #   {:my_dep, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
  #
  # Type "mix help deps" for more examples and options.
  #
  # Dependencies listed here are available only for this project
  # and cannot be accessed from applications inside the apps folder
  defp deps do
    [
      {:phoenix, "~> 1.7"},
      {:phoenix_ecto, "~> 4.7"},
      {:phoenix_html, "~> 3.3"},
      {:phoenix_live_reload, "~> 1.5", only: :dev},
      {:phoenix_live_dashboard, "~> 0.8"},
      {:phoenix_view, "~> 2.0"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.1"},
      {:phoenix_pubsub, "~> 2.1"},
      {:jason, "~> 1.4"},
      {:gettext, "~> 0.26"},
      {:cowboy, "~> 2.12"},
      {:plug_cowboy, "~> 2.7"},
      {:tesla, "~> 1.12"},
      {:toml, "~> 0.7"},
      {:hackney, "~> 1.20"},
      {:oauth2, "~> 2.1"},
      {:joken, "~> 2.6"},
      {:jose, "== 1.11.10", override: true},
      {:dialyxir, "~> 1.4", runtime: false, only: [:dev]},
      {:ex_doc, "~> 0.36", only: :dev},
      {:confex, "~> 3.5"},
      {:postgrex, "~> 0.19"},
      {:myxql, "~> 0.7"},
      {:ecto, "~> 3.13"},
      {:ecto_sql, "~> 3.13"},
      {:ex_parameterized, "~> 1.3", only: [:dev, :test]},
      {:glob, git: "https://github.com/bors-ng/glob.git", commit: "7befe06"}
    ]
  end
end
