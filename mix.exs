defmodule CloakedReq.MixProject do
  use Mix.Project

  @version "0.2.0"

  @spec project() :: keyword()
  def project do
    [
      app: :cloaked_req,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      description: description(),
      package: package(),
      docs: docs(),
      deps: deps(),
      usage_rules: usage_rules()
    ]
  end

  @spec application() :: keyword()
  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp usage_rules do
    [
      file: "AGENTS.md",
      usage_rules: :all
    ]
  end

  @spec docs() :: keyword()
  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"],
      source_url: "https://github.com/rubas/cloaked_req",
      homepage_url: "https://github.com/rubas/cloaked_req"
    ]
  end

  @spec description() :: String.t()
  defp description do
    "Req adapter around Rust wreq with browser impersonation support"
  end

  @spec package() :: keyword()
  defp package do
    [
      licenses: ["LGPL-3.0-or-later"],
      links: %{
        "GitHub" => "https://github.com/rubas/cloaked_req",
        "wreq" => "https://docs.rs/wreq/latest/wreq/"
      },
      files:
        ~w(lib native/cloaked_req_native/src native/cloaked_req_native/Cargo.toml native/cloaked_req_native/Cargo.lock checksum-*.exs mix.exs README.md CHANGELOG.md LICENSE*)
    ]
  end

  @spec deps() :: [tuple()]
  defp deps do
    [
      {:req, "~> 0.5"},
      {:rustler, "~> 0.37.0", optional: true},
      {:rustler_precompiled, "~> 0.8"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:styler, "~> 1.9", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false},
      {:usage_rules, "~> 1.2", only: [:dev], runtime: false}
    ]
  end
end
