defmodule PostProcessing.VerificationStateManager do
  @moduledoc """
  Manages state for content verification, including:
  - Tracking retries and verification attempts
  - Caching LLM responses
  - Tracking error metrics across attempts
  - Managing symbolic verification entities between input and output content
  """

  use Supervisor
  require Logger

  @max_retry_time 15000
  @max_retries 3

  def start_link(args) do
    Logger.info("Starting VerificationStateManager with args: #{inspect(args)}")
    llm_output = Keyword.get(args, :llm_output)
    max_runs = Keyword.get(args, :max_runs, 1)

    case Supervisor.start_link(__MODULE__, [llm_output, max_runs], name: __MODULE__) do
      {:ok, pid} ->
        Logger.info("VerificationStateManager started successfully")
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        Logger.warning("VerificationStateManager already running, resetting the state ...")
        reset_state(llm_output, max_runs)
        {:ok, pid}

      error ->
        Logger.error("Failed to start VerificationStateManager: #{inspect(error)}")
        {:error, error}
    end
  end

  @doc """
  Restarts the VerificationStateManager and reinitializes all state.
  """
  def restart(llm_output, max_runs) do
    Logger.info("Attempting to restart VerificationStateManager")

    # Stop the existing supervisor and all its children
    case Supervisor.stop(__MODULE__, :normal) do
      :ok ->
        Logger.info("Successfully stopped existing VerificationStateManager")
        # Give the system a moment to clean up
        Process.sleep(100)
        # Start again with fresh state
        Supervisor.start_link(__MODULE__, [llm_output, max_runs], name: __MODULE__)

      {:error, reason} ->
        Logger.error("Failed to stop VerificationStateManager: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Resets all state managed by the VerificationStateManager without restarting the supervisor.
  """
  def reset_state(llm_output, max_runs) do
    Logger.info("Resetting VerificationStateManager state")

    # Reset each agent with its initial state
    if Process.whereis(:entity_registry_agent) do
      Agent.update(:entity_registry_agent, fn _ -> init_entity_registry() end)
    end

    if Process.whereis(:response_cache_agent) do
      Agent.update(:response_cache_agent, fn _ -> init_response_cache(llm_output) end)
    end

    if Process.whereis(:verification_stats_agent) do
      Agent.update(:verification_stats_agent, fn _ -> init_verification_stats(max_runs) end)
    end

    :ok
  end

  @impl true
  def init([llm_output, max_runs]) do
    children = [
      %{
        id: :entity_registry_agent,
        start:
          {Agent, :start_link, [fn -> init_entity_registry() end, [name: :entity_registry_agent]]}
      },
      %{
        id: :response_cache_agent,
        start:
          {Agent, :start_link,
           [fn -> init_response_cache(llm_output) end, [name: :response_cache_agent]]}
      },
      %{
        id: :verification_stats_agent,
        start:
          {Agent, :start_link,
           [fn -> init_verification_stats(max_runs) end, [name: :verification_stats_agent]]}
      },
      {Task.Supervisor, name: TimerSupervisor}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp init_entity_registry do
    %{
      input_entities: [%{run_number: 1, num_entities: 0, entities: [], combined_content: []}],
      output_entities: [%{run_number: 1, num_entities: 0, entities: [], combined_content: []}]
    }
  end

  # Response cache initialization
  defp init_response_cache(llm_output) do
    responses =
      cond do
        is_list(llm_output) ->
          # Create a map with numbered keys for each output
          llm_output
          |> Enum.with_index(1)
          |> Enum.map(fn {output, index} -> %{index => output} end)

        true ->
          # Single output case
          [%{1 => llm_output}]
      end

    %{reponses: responses}
  end

  defp init_verification_stats(max_runs) do
    %{
      runs: 1,
      max: max_runs,
      validations: 0,
      best_run: 1,
      elapsed_time: %{start_time: System.monotonic_time(:millisecond), timeout_ref: nil},
      run_stats: [
        %{
          run_number: 1,
          missing_info: %{},
          false_info: %{},
          scores: %{
            input_coverage_percentage: 0,
            output_coverage_percentage: 0,
            overall_coverage_percentage: 0,
            input_weighted_content_score: 0,
            output_weighted_content_score: 0,
            overall_weighted_content_score: 0
          }
        }
      ]
    }
  end

  # Timer functions
  def start_timer do
    # Don't actually set a timer, just record the time
    %{start_time: System.monotonic_time(:millisecond), timeout_ref: nil}
  end

  def get_elapsed_time do
    Agent.get(:verification_stats_agent, fn state ->
      now = System.monotonic_time(:millisecond)
      now - state.elapsed_time.start_time
    end)
  end

  def stop_timer do
    Agent.get_and_update(:verification_stats_agent, fn state ->
      elapsed = System.monotonic_time(:millisecond) - state.elapsed_time.start_time
      {elapsed, %{state | elapsed_time: %{state.elapsed_time | timeout_ref: nil}}}
    end)
  end

  def reset_timer do
    Agent.update(:verification_stats_agent, fn state ->
      new_time = %{start_time: System.monotonic_time(:millisecond), timeout_ref: nil}
      %{state | elapsed_time: new_time}
    end)
  end

  def update_run_stats(run_number, metrics) do
    Agent.update(:verification_stats_agent, fn state ->
      updated_run_stats = Map.put(state.run_stats, run_number, metrics)
      # Also update best run if this has better metrics
      # Assuming lower score is better, modify this logic as needed
      current_best_score =
        case Map.get(state.run_stats, state.best_run) do
          nil -> :infinity
          best_stats -> Map.get(best_stats, :score, :infinity)
        end

      current_score = Map.get(metrics, :score, :infinity)

      best_run = if current_score < current_best_score, do: run_number, else: state.best_run

      %{state | run_stats: updated_run_stats, best_run: best_run}
    end)
  end

  def prepare_next_run do
    case can_retry?() do
      true ->
        # Increment run counter and return the new run number
        increment_run_count()

      false ->
        # Return nil or current run number to indicate we cannot retry
        get_value(:verification_stats, :runs)
    end
  end

  def increment_run_count do
    Agent.get_and_update(:verification_stats_agent, fn state ->
      new_run_count = state.runs + 1
      {new_run_count, %{state | runs: new_run_count}}
    end)
  end

  # Modified can_retry? function that considers max_runs
  def can_retry? do
    Agent.get(:verification_stats_agent, fn state ->
      elapsed = System.monotonic_time(:millisecond) - state.elapsed_time.start_time
      state.runs < state.max && elapsed < @max_retry_time
    end)
  end

  def reset_run_count do
    Agent.update(:verification_stats_agent, fn state ->
      %{state | runs: 1}
    end)
  end

  # Get the entire state of an agent
  def get_state(:entity_registry), do: Agent.get(:entity_registry_agent, & &1)
  def get_state(:response_cache), do: Agent.get(:response_cache_agent, & &1)
  def get_state(:verification_stats), do: Agent.get(:verification_stats_agent, & &1)

  # Updated entity registry functions
  def get_value(:entity_registry, :input_entities) do
    Agent.get(:entity_registry_agent, fn state ->
      current_run = get_value(:verification_stats, :runs)

      Enum.find(
        state.input_entities,
        %{num_entities: 0, entities: [], combined_content: []},
        fn entry ->
          entry.run_number == current_run
        end
      )
    end)
  end

  def get_value(:entity_registry, :num_input_entities) do
    Agent.get(:entity_registry_agent, fn state ->
      current_run = get_value(:verification_stats, :runs)

      run_entry =
        Enum.find(state.input_entities, %{num_entities: 0}, fn entry ->
          entry.run_number == current_run
        end)

      run_entry.num_entities
    end)
  end

  def get_value(:entity_registry, :num_output_entities) do
    Agent.get(:entity_registry_agent, fn state ->
      current_run = get_value(:verification_stats, :runs)

      run_entry =
        Enum.find(state.output_entities, %{num_entities: 0}, fn entry ->
          entry.run_number == current_run
        end)

      run_entry.num_entities
    end)
  end

  def get_value(:entity_registry, :output_entities),
    do: Agent.get(:entity_registry_agent, & &1.output_entities)

  def get_value(:entity_registry, :current_run_entities) do
    Agent.get(:entity_registry_agent, fn state ->
      current_run = get_value(:verification_stats, :runs)

      Enum.find(state.output_entities, %{entities: []}, fn entry ->
        entry.run_number == current_run
      end)
    end)
  end

  # New getter for input_entities combined_content for current run
  def get_value(:entity_registry, :input_combined_content) do
    Agent.get(:entity_registry_agent, fn state ->
      current_run = get_value(:verification_stats, :runs)

      run_entry =
        Enum.find(state.input_entities, %{combined_content: []}, fn entry ->
          entry.run_number == current_run
        end)

      run_entry.combined_content
    end)
  end

  # New getter for current run's output_entities combined_content
  def get_value(:entity_registry, :current_run_output_combined_content) do
    Agent.get(:entity_registry_agent, fn state ->
      current_run = get_value(:verification_stats, :runs)

      run_entry =
        Enum.find(state.output_entities, %{combined_content: []}, fn entry ->
          entry.run_number == current_run
        end)

      run_entry.combined_content
    end)
  end

  # Response cache accessors
  def get_value(:response_cache, :responses),
    do: Agent.get(:response_cache_agent, & &1.reponses)

  def get_value(:response_cache, :last_response) do
    Agent.get(:response_cache_agent, fn state ->
      # Find the response with the highest run number
      state.reponses
      |> Enum.flat_map(fn response_map -> Map.to_list(response_map) end)
      |> Enum.sort_by(fn {run_number, _} -> run_number end, :desc)
      |> List.first()
      |> case do
        nil -> nil
        {_run_number, response} -> response
      end
    end)
  end

  # Update response cache field
  def update_response_cache(key, value) when key in [:reponses] do
    Agent.update(:response_cache_agent, &Map.put(&1, key, value))
  end

  # Add a response to the cache, keeping unique run keys
  def add_response(key, response) do
    Agent.update(:response_cache_agent, fn state ->
      updated_responses =
        [%{key => response} | state.reponses]
        |> Enum.uniq_by(fn map -> hd(Map.keys(map)) end)

      %{state | reponses: updated_responses}
    end)
  end

  # Updated verification stats functions
  def get_value(:verification_stats, :runs),
    do: Agent.get(:verification_stats_agent, & &1.runs)

  def get_value(:verification_stats, :validations),
    do: Agent.get(:verification_stats_agent, & &1.validations)

  def get_value(:verification_stats, :best_run),
    do: Agent.get(:verification_stats_agent, & &1.best_run)

  def get_value(:verification_stats, :elapsed_time),
    do: Agent.get(:verification_stats_agent, & &1.elapsed_time)

  def get_value(:verification_stats, :run_stats),
    do: Agent.get(:verification_stats_agent, & &1.run_stats)

  # New getter functions for verification scores

  @doc """
  Gets all scores for the current run.
  """
  def get_current_run_scores do
    current_run = get_value(:verification_stats, :runs)
    get_run_scores(current_run)
  end

  @doc """
  Gets all scores for a specific run.
  """
  def get_run_scores(run_number) do
    Agent.get(:verification_stats_agent, fn state ->
      run_entry =
        Enum.find(state.run_stats, %{scores: %{}}, fn entry ->
          entry.run_number == run_number
        end)

      Map.get(run_entry, :scores, %{})
    end)
  end

  @doc """
  Gets a specific score for the current run.
  """
  def get_current_run_score(score_key) do
    current_run_scores = get_current_run_scores()
    Map.get(current_run_scores, score_key)
  end

  @doc """
  Gets a specific score for a given run.
  """
  def get_run_score(run_number, score_key) do
    run_scores = get_run_scores(run_number)
    Map.get(run_scores, score_key)
  end

  @doc """
  Replaces all scores for the current run.
  """
  def replace_current_run_scores(scores) when is_map(scores) do
    current_run = get_value(:verification_stats, :runs)

    Agent.update(:verification_stats_agent, fn state ->
      # Find the index of the current run stats
      {run_entry, remaining_entries} =
        Enum.split_with(state.run_stats, fn entry ->
          entry.run_number == current_run
        end)

      updated_entry =
        case run_entry do
          [entry] -> Map.put(entry, :scores, scores)
          _ -> %{run_number: current_run, missing_info: %{}, false_info: %{}, scores: scores}
        end

      # Reconstruct run_stats with updated entry
      updated_run_stats =
        if run_entry == [] do
          [updated_entry | state.run_stats]
        else
          [updated_entry | remaining_entries]
        end

      %{state | run_stats: updated_run_stats}
    end)
  end

  @doc """
  Updates a single score value for the current run.
  """
  def update_current_run_score(score_key, value) do
    current_run = get_value(:verification_stats, :runs)

    Agent.update(:verification_stats_agent, fn state ->
      # Find the current run entry
      {run_entry, remaining_entries} =
        Enum.split_with(state.run_stats, fn entry ->
          entry.run_number == current_run
        end)

      updated_entry =
        case run_entry do
          [entry] ->
            current_scores = Map.get(entry, :scores, %{})
            updated_scores = Map.put(current_scores, score_key, value)
            Map.put(entry, :scores, updated_scores)

          _ ->
            %{
              run_number: current_run,
              missing_info: %{},
              false_info: %{},
              scores: %{score_key => value}
            }
        end

      # Reconstruct run_stats with updated entry
      updated_run_stats =
        if run_entry == [] do
          [updated_entry | state.run_stats]
        else
          [updated_entry | remaining_entries]
        end

      %{state | run_stats: updated_run_stats}
    end)
  end

  @doc """
  Gets both missing_info and false_info maps for the current run.
  Returns a tuple with {missing_info, false_info}
  """
  def get_current_run_missing_and_false_entities do
    current_run = get_value(:verification_stats, :runs)

    Agent.get(:verification_stats_agent, fn state ->
      run_entry =
        Enum.find(state.run_stats, %{missing_info: %{}, false_info: %{}}, fn entry ->
          entry.run_number == current_run
        end)

      {Map.get(run_entry, :missing_info, %{}), Map.get(run_entry, :false_info, %{})}
    end)
  end

  @doc """
  Sets both missing_info and false_info maps for the current run.
  """
  def set_current_run_missing_and_false_entities(missing_info, false_info)
      when is_map(missing_info) and is_map(false_info) do
    current_run = get_value(:verification_stats, :runs)

    Agent.update(:verification_stats_agent, fn state ->
      # Find the current run entry
      {run_entry, remaining_entries} =
        Enum.split_with(state.run_stats, fn entry ->
          entry.run_number == current_run
        end)

      # Calculate a score based on the errors (lower is better)
      score = map_size(missing_info) + map_size(false_info) * 2

      updated_entry =
        case run_entry do
          [entry] ->
            entry
            |> Map.put(:missing_info, missing_info)
            |> Map.put(:false_info, false_info)
            |> Map.put(:score, score)

          _ ->
            %{
              run_number: current_run,
              missing_info: missing_info,
              false_info: false_info,
              score: score,
              scores: %{}
            }
        end

      # Reconstruct run_stats with updated entry
      updated_run_stats =
        if run_entry == [] do
          [updated_entry | state.run_stats]
        else
          [updated_entry | remaining_entries]
        end

      # Determine best run based on score
      best_run =
        Enum.reduce(updated_run_stats, {1, :infinity}, fn
          %{run_number: run, score: s}, {_, min_score} when s < min_score ->
            {run, s}

          _, acc ->
            acc
        end)
        |> elem(0)

      %{state | run_stats: updated_run_stats, best_run: best_run}
    end)
  end

  # Helper function to add multiple input entities at once
  def add_input_entities(entities) when is_list(entities) do
    current_run = get_value(:verification_stats, :runs)

    Agent.update(:entity_registry_agent, fn state ->
      # Find the entry for the current run
      {found_entry, remaining_entries} =
        Enum.split_with(state.input_entities, fn entry ->
          entry.run_number == current_run
        end)

      entry =
        case found_entry do
          [run_entry] -> run_entry
          _ -> %{run_number: current_run, num_entities: 0, entities: [], combined_content: []}
        end

      # Update the entry with all new entities
      updated_entry = %{
        entry
        | entities: entities ++ entry.entities,
          num_entities: entry.num_entities + length(entities)
      }

      # Reconstruct input_entities list with the updated entry
      updated_input_entities =
        if found_entry == [] do
          [updated_entry | state.input_entities]
        else
          [updated_entry | remaining_entries]
        end

      %{state | input_entities: updated_input_entities}
    end)
  end

  # Helper function to add content to input entities' combined_content
  def add_input_combined_content(content) when is_list(content) do
    current_run = get_value(:verification_stats, :runs)

    Agent.update(:entity_registry_agent, fn state ->
      # Find the entry for the current run
      {found_entry, remaining_entries} =
        Enum.split_with(state.input_entities, fn entry ->
          entry.run_number == current_run
        end)

      entry =
        case found_entry do
          [run_entry] -> run_entry
          _ -> %{run_number: current_run, num_entities: 0, entities: [], combined_content: []}
        end

      # Update the entry with new combined content
      updated_entry = %{
        entry
        | combined_content: content ++ (entry.combined_content || [])
      }

      # Reconstruct input_entities list with the updated entry
      updated_input_entities =
        if found_entry == [] do
          [updated_entry | state.input_entities]
        else
          [updated_entry | remaining_entries]
        end

      %{state | input_entities: updated_input_entities}
    end)
  end

  # Helper function to add multiple output entities for the current run
  def add_output_entities(entities) when is_list(entities) do
    current_run = get_value(:verification_stats, :runs)

    Agent.update(:entity_registry_agent, fn state ->
      # Find the entry for the current run
      {found_entry, remaining_entries} =
        Enum.split_with(state.output_entities, fn entry ->
          entry.run_number == current_run
        end)

      entry =
        case found_entry do
          [run_entry] -> run_entry
          _ -> %{run_number: current_run, num_entities: 0, entities: [], combined_content: []}
        end

      # Update the entry with all new entities
      updated_entry = %{
        entry
        | entities: entities ++ entry.entities,
          num_entities: entry.num_entities + length(entities)
      }

      # Reconstruct output_entities list with the updated entry
      updated_output_entities =
        if found_entry == [] do
          [updated_entry | state.output_entities]
        else
          [updated_entry | remaining_entries]
        end

      %{state | output_entities: updated_output_entities}
    end)
  end

  # Helper function to add content to output entities' combined_content for current run
  def add_output_combined_content(content) when is_list(content) do
    current_run = get_value(:verification_stats, :runs)

    Agent.update(:entity_registry_agent, fn state ->
      # Find the entry for the current run
      {found_entry, remaining_entries} =
        Enum.split_with(state.output_entities, fn entry ->
          entry.run_number == current_run
        end)

      entry =
        case found_entry do
          [run_entry] -> run_entry
          _ -> %{run_number: current_run, num_entities: 0, entities: [], combined_content: []}
        end

      # Update the entry with new combined content
      updated_entry = %{
        entry
        | combined_content: content ++ (entry.combined_content || [])
      }

      # Reconstruct output_entities list with the updated entry
      updated_output_entities =
        if found_entry == [] do
          [updated_entry | state.output_entities]
        else
          [updated_entry | remaining_entries]
        end

      %{state | output_entities: updated_output_entities}
    end)
  end

  # Helper function to replace all entities for a specific run
  def replace_output_entities(entities) when is_list(entities) do
    current_run = get_value(:verification_stats, :runs)

    Agent.update(:entity_registry_agent, fn state ->
      # Find the current run entry to preserve combined_content if it exists
      current_entry =
        Enum.find(state.output_entities, %{combined_content: []}, fn entry ->
          entry.run_number == current_run
        end)

      # Filter out the specified run's entry
      filtered_entries =
        Enum.filter(state.output_entities, fn entry ->
          entry.run_number != current_run
        end)

      # Create a new entry with the provided entities, preserving combined_content
      new_entry = %{
        run_number: current_run,
        num_entities: length(entities),
        entities: entities,
        combined_content: current_entry.combined_content
      }

      # Add the new entry to the filtered list
      %{state | output_entities: [new_entry | filtered_entries]}
    end)
  end

  def replace_input_entities(entities) when is_list(entities) do
    current_run = get_value(:verification_stats, :runs)

    Agent.update(:entity_registry_agent, fn state ->
      # Find the current run entry to preserve combined_content if it exists
      current_entry =
        Enum.find(state.input_entities, %{combined_content: []}, fn entry ->
          entry.run_number == current_run
        end)

      # Filter out the specified run's entry
      filtered_entries =
        Enum.filter(state.input_entities, fn entry ->
          entry.run_number != current_run
        end)

      # Create a new entry with the provided entities, preserving combined_content
      new_entry = %{
        run_number: current_run,
        num_entities: length(entities),
        entities: entities,
        combined_content: current_entry.combined_content
      }

      # Add the new entry to the filtered list
      %{state | input_entities: [new_entry | filtered_entries]}
    end)
  end

  # Create a new run and prepare containers
  def start_new_verification_run do
    run_number = increment_run_count()

    # Add new containers for this run in verification_stats
    Agent.update(:verification_stats_agent, fn state ->
      updated_run_stats = [
        %{run_number: run_number, missing_info: %{}, false_info: %{}}
        | state.run_stats
      ]

      %{state | run_stats: updated_run_stats}
    end)

    # Add new container for this run's entities (both input and output)
    Agent.update(:entity_registry_agent, fn state ->
      new_output_container = %{
        run_number: run_number,
        num_entities: 0,
        entities: [],
        combined_content: []
      }

      new_input_container = %{
        run_number: run_number,
        num_entities: 0,
        entities: [],
        combined_content: []
      }

      %{
        state
        | output_entities: [new_output_container | state.output_entities],
          input_entities: [new_input_container | state.input_entities]
      }
    end)

    # Reset timer for this run
    reset_timer()

    run_number
  end

  # Get all entity IDs from both input and output entities
  def get_all_entity_ids do
    Agent.get(:entity_registry_agent, fn state ->
      # Extract IDs from input entities - input_entities is a map with entities as a list
      input_ids =
        state.input_entities
        |> Enum.flat_map(fn run_entry ->
          Enum.map(run_entry.entities, fn entity ->
            Map.get(entity, :id)
          end)
        end)
        |> Enum.filter(& &1)

      # Extract IDs from output entities across all runs
      output_ids =
        state.output_entities
        |> Enum.flat_map(fn run_entry ->
          Enum.map(run_entry.entities, fn entity ->
            Map.get(entity, :id)
          end)
        end)
        |> Enum.filter(& &1)

      # Combine both lists of IDs
      input_ids ++ output_ids
    end)
  end

  # Helper function to get entities for a specific run
  def get_output_entities(run_number) do
    Agent.get(:entity_registry_agent, fn state ->
      found = Enum.find(state.output_entities, fn entry -> entry.run_number == run_number end)

      case found do
        nil -> []
        entry -> entry.entities
      end
    end)
  end

  # Get input entities for the current run
  def get_input_entities_of_current_run do
    current_run = get_value(:verification_stats, :runs)

    Agent.get(:entity_registry_agent, fn state ->
      run_entry =
        Enum.find(state.input_entities, %{entities: []}, fn entry ->
          entry.run_number == current_run
        end)

      run_entry.entities
    end)
  end

  # Get output entities for the current run
  def get_output_entities_of_current_run do
    current_run = get_value(:verification_stats, :runs)

    Agent.get(:entity_registry_agent, fn state ->
      run_entry =
        Enum.find(state.output_entities, %{entities: []}, fn entry ->
          entry.run_number == current_run
        end)

      run_entry.entities
    end)
  end

  # Helper function to add a response to the cache with timestamp
  def add_response(key, response) do
    Agent.update(:response_cache_agent, fn state ->
      updated_responses =
        [%{key => response} | state.reponses]
        |> Enum.uniq_by(fn map -> hd(Map.keys(map)) end)

      %{state | reponses: updated_responses}
    end)
  end

  # Add run statistics for the current verification run
  def add_run_statistics(missing_info, false_info) do
    current_run = get_value(:verification_stats, :runs)

    Agent.update(:verification_stats_agent, fn state ->
      # Calculate a score based on the errors (lower is better)
      score = map_size(missing_info) + map_size(false_info) * 2

      # Create run stats entry
      run_stats_entry = %{
        run_number: current_run,
        missing_info: missing_info,
        false_info: false_info,
        score: score
      }

      # Update the run_stats list
      updated_run_stats = [
        run_stats_entry
        | Enum.filter(state.run_stats, fn stat -> stat.run_number != current_run end)
      ]

      # Determine best run
      best_run =
        Enum.reduce(updated_run_stats, {1, :infinity}, fn
          %{run_number: run, score: score}, {_, min_score} when score < min_score ->
            {run, score}

          _, acc ->
            acc
        end)
        |> elem(0)

      %{state | run_stats: updated_run_stats, best_run: best_run}
    end)
  end

  # Get the best run's entities
  def get_best_run_entities do
    best_run = get_value(:verification_stats, :best_run)
    get_output_entities(best_run)
  end

  # Get statistics for the best run
  def get_best_run_stats do
    best_run = get_value(:verification_stats, :best_run)

    Agent.get(:verification_stats_agent, fn state ->
      Enum.find(state.run_stats, fn stat -> stat.run_number == best_run end)
    end)
  end

  # Generate a unique ID that doesn't exist in either input or output entities
  def create_unique_id do
    existing_ids = get_all_entity_ids()

    # Keep generating IDs until we find one that doesn't exist
    Stream.iterate(0, &(&1 + 1))
    |> Stream.map(fn _ -> String.slice(UUID.uuid4(), 0, 8) end)
    |> Enum.find(fn candidate_id -> candidate_id not in existing_ids end)
  end

  @doc """
  Gets the response for the current run.
  Returns the response text or nil if not found.
  """
  def get_current_response do
    current_run = get_value(:verification_stats, :runs)

    Agent.get(:response_cache_agent, fn state ->
      # Find the response map for the current run
      # This is a list of maps
      responses = state.reponses

      # Try to find the response for the current run
      Enum.find_value(responses, nil, fn response_map ->
        Map.get(response_map, current_run)
      end)
    end)
  end
end
