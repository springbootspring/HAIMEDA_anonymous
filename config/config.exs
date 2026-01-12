# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :haimeda_core,
  generators: [timestamp_type: :utc_datetime]

# Configure MongoDB
config :haimeda_core, HaimedaCore.Repo,
  url: "mongodb://localhost:27017/haimeda_db",
  pool_size: 10

# Configures the endpoint
config :haimeda_core, HaimedaCoreWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: HaimedaCoreWeb.ErrorHTML, json: HaimedaCoreWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: HaimedaCore.PubSub,
  live_view: [signing_salt: "3ECTZrY5"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.17.11",
  haimeda_core: [
    args:
      ~w(js/app.js --bundle --target=es2020 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "3.4.3",
  haimeda_core: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
