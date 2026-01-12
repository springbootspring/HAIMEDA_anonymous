defmodule RIM.ResourceAgent do
  use Agent
  require Logger

  @files [
    "Auftraggeber",
    "Geräteart",
    "Gerätetyp",
    "Hersteller",
    "Makler",
    "Schaden",
    "Versicherungsnehmer"
  ]

  def startup_resource_agent(mdb_files_path) do
    # Stop the agent if it's already running
    case Process.whereis(__MODULE__) do
      nil ->
        :ok

      _pid ->
        Logger.info("ResourceAgent already running, restarting...")
        Agent.stop(__MODULE__)
    end

    # Start the agent with an empty map
    {:ok, _pid} = Agent.start_link(fn -> %{} end, name: __MODULE__)

    # Read each file and store its data in the agent
    Enum.each(@files, fn file ->
      json_path = Path.join(mdb_files_path, "#{file}.json")
      IO.inspect(json_path, label: "Loading JSON file")

      case File.read(json_path) do
        {:ok, json_string} ->
          case Jason.decode(json_string) do
            {:ok, data} ->
              Agent.update(__MODULE__, fn state -> Map.put(state, file, data) end)
              Logger.info("Loaded #{file}.json into ResourceAgent")

            {:error, reason} ->
              Logger.error("Error parsing #{file}.json: #{inspect(reason)}")
          end

        {:error, reason} ->
          Logger.error("Error reading #{file}.json: #{inspect(reason)}")
      end
    end)

    :ok
  end

  @doc """
  Get all data from the agent
  """
  def get_all_data do
    Agent.get(__MODULE__, fn state -> state end)
  end

  @doc """
  Get data for a specific file from the agent
  """
  def get_file_data(file) do
    Agent.get(__MODULE__, fn state -> Map.get(state, file) end)
  end

  @doc """
  Get records for a specific table from the agent
  """
  def get_records(table) do
    case get_file_data(table) do
      %{"records" => records} -> records
      _ -> []
    end
  end

  @doc """
  Get columns for a specific table from the agent
  """
  def get_columns(table) do
    case get_file_data(table) do
      %{"columns" => columns} -> columns
      _ -> []
    end
  end

  @doc """
  Check if the agent is running
  """
  def is_running? do
    case Process.whereis(__MODULE__) do
      nil -> false
      _pid -> true
    end
  end
end
