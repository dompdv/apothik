defmodule Apothik.MixProject do
  use Mix.Project

  def project do
    [
      app: :apothik,
      version: "0.1.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Apothik.Application, Mix.env() == :test}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:delta_crdt, "~> 0.6.5"},
      {:libcluster, "~> 3.4"},
      {:libring, "~> 1.7"},
      {:credo, "~> 1.7"}
    ]
  end
end
