defmodule HaimedaCore.Repo do
  @moduledoc """
  MongoDB connection for HAIMEDA.
  """

  @pool_name :mongo_pool

  @doc """
  Gets the MongoDB connection pool name.
  """
  def get_conn, do: @pool_name

  @doc """
  Starts the MongoDB connection.
  This is called by the application supervisor.
  """
  def child_spec(_opts) do
    # Get configuration from config.exs
    config = Application.get_env(:haimeda_core, __MODULE__)

    # Extract MongoDB connection options
    url = Keyword.get(config, :url, "mongodb://localhost:27017/haimeda_db")
    pool_size = Keyword.get(config, :pool_size, 10)

    # Parse connection URL
    uri = URI.parse(url)
    db_name = String.trim_leading(uri.path || "/haimeda_db", "/")
    host = uri.host || "localhost"
    port = uri.port || 27017

    # Start MongoDB connection pool
    %{
      id: __MODULE__,
      start:
        {Mongo, :start_link,
         [
           [
             name: @pool_name,
             hostname: host,
             port: port,
             database: db_name,
             pool_size: pool_size
           ]
         ]}
    }
  end

  @doc """
  Find a single document matching the given filter criteria
  """
  def find_one(collection, filter) do
    Mongo.find_one(@pool_name, collection, filter)
  end

  @doc """
  Insert a document into a collection
  """
  def insert_one(collection, document) do
    Mongo.insert_one(@pool_name, collection, document)
  end

  @doc """
  Update a single document matching the given filter
  """
  def update_one(collection, filter, update) do
    Mongo.update_one(@pool_name, collection, filter, update)
  end

  @doc """
  Delete a single document matching the given filter
  """
  def delete_one(collection, filter) do
    Mongo.delete_one(@pool_name, collection, filter)
  end

  @doc """
  Delete multiple documents matching the given filter
  """
  def delete_many(collection, filter) do
    Mongo.delete_many(@pool_name, collection, filter)
  end
end
