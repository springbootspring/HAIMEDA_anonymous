defmodule PreProcessing.UniverseState do
  use GenServer

  # Client API
  def start_link(initial_state \\ %{}) do
    case GenServer.start_link(__MODULE__, initial_state, name: __MODULE__) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        # If already started, reset state and return existing pid
        GenServer.cast(__MODULE__, {:reset_state, initial_state})
        {:ok, pid}

      error ->
        error
    end
  end

  # Accept non-binary keys by converting to string
  def get_set(key) when not is_binary(key) do
    get_set(to_string(key))
  end

  def get_set(key) when is_binary(key) do
    GenServer.call(__MODULE__, {:get_set, key})
  end

  def get_all_sets() do
    GenServer.call(__MODULE__, :get_all_sets)
  end

  # Ensure set names are stored as strings
  def update_set(set_name, set) do
    GenServer.cast(__MODULE__, {:update_set, to_string(set_name), set})
  end

  def update_sets(sets) do
    # Convert keys to strings before merging into state
    sets = Enum.into(sets, %{}, fn {k, v} -> {to_string(k), v} end)
    GenServer.cast(__MODULE__, {:update_sets, sets})
  end

  def reset() do
    GenServer.cast(__MODULE__, {:reset_state, %{}})
  end

  # Server callbacks
  @impl true
  def init(initial_state) do
    {:ok, initial_state}
  end

  @impl true
  def handle_call({:get_set, set_name}, _from, state) do
    {:reply, Map.get(state, set_name), state}
  end

  @impl true
  def handle_call(:get_all_sets, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_cast({:update_set, set_name, set}, state) do
    {:noreply, Map.put(state, set_name, set)}
  end

  @impl true
  def handle_cast({:update_sets, sets}, state) do
    {:noreply, Map.merge(state, sets)}
  end

  @impl true
  def handle_cast({:reset_state, new_state}, _state) do
    {:noreply, new_state}
  end
end
