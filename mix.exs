defmodule OpenChat.MixProject do
  use Mix.Project

  def project do
    [
      app: :open_chat,
      version: "0.1.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      preferred_cli_env: [test: :test],
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :public_key, :ssl, :inets, :mime],
      mod: {OpenChat.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:plug_cowboy, "~> 2.7"},
      {:jason, "~> 1.4"},
      {:redix, "~> 1.5"},
      {:mime, "~> 2.0"},
      {:castore, "~> 1.0"}
    ]
  end

  defp aliases do
    [
      test: ["test --trace"],
      "test.load": ["test --only load --trace"]
    ]
  end
end
