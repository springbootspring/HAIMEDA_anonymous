defmodule HaimedaCore.GatewayAPI do
  @moduledoc """
  API to establish a connection to modules written in other languages, e.g. Python via ErlPort.
  Connection is established lazily only when needed.
  """

  use GenServer
  require Logger

  @python_path Path.join([__DIR__, "external", "python"])

  # Public API functions

  @doc """
  Ensures that the GatewayAPI is started and Python connection is established.
  Returns {:ok, pid} if successful or {:error, reason} if it fails.
  """
  def ensure_started(module \\ nil) do
    case Process.whereis(__MODULE__) do
      nil ->
        # Gateway not started, start it manually
        Logger.info("GatewayAPI not found, starting manually")
        # Use start instead of start_link to avoid linking to the calling process
        GenServer.start(__MODULE__, [python_module: module], name: __MODULE__)

      pid when is_pid(pid) ->
        # Gateway is already started
        Logger.debug("GatewayAPI already running with pid #{inspect(pid)}")
        {:ok, pid}
    end
  end

  @doc """
  Restarts the GatewayAPI GenServer and its Python instance.
  This is useful when Python files have been modified while the application is running.

  Options:
  - file: Optional Python filename to reload specifically after a full restart

  Returns:
  - :ok if the restart was successful
  - {:error, reason} if restart failed
  """
  def restart_genserver(options \\ []) do
    file_to_reload = Keyword.get(options, :file)
    reload = Keyword.get(options, :reload)

    # Full restart logic - always performed
    Logger.info("Attempting to restart GatewayAPI GenServer")

    case Process.whereis(__MODULE__) do
      nil ->
        # GenServer isn't running, just start it
        Logger.info("GatewayAPI GenServer not found, starting fresh")
        result = ensure_started(file_to_reload)

        # If we need to reload a module after start, do it now
        if reload, do: reload_python_module(file_to_reload)

        result

      pid when is_pid(pid) ->
        # First stop the existing GenServer
        Logger.info("Stopping existing GatewayAPI GenServer")

        # Try graceful termination first
        try do
          GenServer.stop(pid, :normal, 5000)
        catch
          :exit, _ ->
            # If graceful termination fails, forcefully terminate
            Logger.warning("Graceful termination failed, forcing termination")
            Process.exit(pid, :kill)
        end

        # Give the system a moment to clean up
        Process.sleep(500)

        # Now start a new instance
        Logger.info("Starting fresh GatewayAPI GenServer")
        ensure_started(file_to_reload)

        # If we need to reload a module after restart, do it now
        if reload, do: reload_python_module(file_to_reload)
    end

    # Verify the restart was successful
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        # Check if the new instance works
        case test_connection(file_to_reload) do
          true ->
            Logger.info("GatewayAPI GenServer successfully restarted")
            :ok

          false ->
            Logger.error("GatewayAPI GenServer restarted but Python verification failed")
            {:error, :module_unavailable}
        end

      nil ->
        Logger.error("Failed to restart GatewayAPI GenServer")
        {:error, :restart_failed}
    end
  end

  @doc """
  Reloads a specific Python module without restarting the entire GenServer.
  This is useful for quick updates to individual Python files.

  Returns:
  - :ok if the module was reloaded successfully
  - {:error, reason} if the reload failed
  """
  def reload_python_module(module_name) when is_atom(module_name) do
    module_name_str = Atom.to_string(module_name)
    reload_python_module(module_name_str)
  end

  def reload_python_module(module_name) when is_binary(module_name) do
    # Remove .py extension if provided
    module_name = String.replace(module_name, ".py", "")

    Logger.info("Attempting to reload Python module: #{module_name}")

    with {:ok, pid} <- ensure_started(),
         true <- Process.alive?(pid) do
      try do
        # First check if the module has a custom reload function
        case GenServer.call(__MODULE__, {:call, String.to_atom(module_name), :reload_module, []}) do
          {:ok, result} ->
            Logger.info("Custom reload for #{module_name}: #{result}")
            :ok

          # If the module doesn't have a custom reload function, use importlib
          {:error, _} ->
            # Call Python's importlib.reload function to reload the module
            case GenServer.call(__MODULE__, {:reload_module, module_name}) do
              {:ok, _} ->
                Logger.info("Successfully reloaded Python module: #{module_name}")
                :ok

              {:error, reason} ->
                Logger.error("Failed to reload Python module #{module_name}: #{inspect(reason)}")
                {:error, reason}
            end
        end
      catch
        kind, reason ->
          Logger.error("Error during Python module reload: #{inspect({kind, reason})}")
          {:error, {kind, reason}}
      end
    else
      false ->
        Logger.error("GatewayAPI GenServer not alive")
        {:error, :server_not_alive}

      error ->
        Logger.error("Failed to ensure GatewayAPI is started: #{inspect(error)}")
        error
    end
  end

  @doc """
  Check if a model is loaded in a specific Python module.
  Useful for determining if a reload would be expensive.
  """
  def check_model_loaded(module) do
    with {:ok, _pid} <- ensure_started() do
      try do
        case GenServer.call(__MODULE__, {:call, module, :is_model_loaded, []}) do
          {:ok, status} ->
            status = if is_list(status), do: List.to_string(status), else: "#{status}"
            {:ok, status}

          error ->
            error
        end
      catch
        _, _ -> {:error, :unavailable}
      end
    end
  end

  @doc """
  Call any Python function in a given module.
  module: atom name of the Python module
  function: atom name of the Python function
  args: list of arguments to pass
  options: map or keyword list with the following supported keys:
    - restart: boolean, if true, restart the GenServer before the function call
    - reload: boolean, if true, reload the module before the function call
    - format_errors: boolean, if true, format Python errors into readable strings (default: true)
  timeout: optional timeout in milliseconds (defaults to standard GenServer timeout)

  For backward compatibility, a boolean can be passed instead of options map, which
  is equivalent to %{reload: value}

  Returns {:ok, result} or {:error, reason} from Python. Error messages are automatically
  formatted in a human-readable way unless format_errors: false is specified.
  """
  def call(module, function, args \\ [], options \\ nil, timeout \\ 10000) do
    # Handle the different ways options can be provided
    options =
      cond do
        # backward compatibility
        is_boolean(options) -> %{reload: options, format_errors: true}
        is_map(options) -> Map.put_new(options, :format_errors, true)
        is_list(options) -> options |> Map.new() |> Map.put_new(:format_errors, true)
        is_nil(options) -> %{format_errors: true}
        true -> %{format_errors: true}
      end

    # Check if restart is requested
    if Map.get(options, :restart, false) do
      Logger.info("Restarting GenServer before calling #{inspect(module)}.#{inspect(function)}")
      # Restart the entire GenServer
      case restart_genserver(file: module) do
        :ok ->
          Logger.debug("GenServer restarted successfully")

        {:error, reason} ->
          Logger.warning("Failed to restart GenServer: #{inspect(reason)}")
      end

      # If not restarting, check if reload is requested
    else
      if Map.get(options, :reload, false) do
        Logger.debug("Reloading module #{inspect(module)} before function call")
        # Just reload the module
        case reload_python_module(module) do
          :ok ->
            Logger.debug("Module #{inspect(module)} reloaded before function call")

          {:error, reason} ->
            Logger.warning("Failed to reload module #{inspect(module)}: #{inspect(reason)}")
        end
      end
    end

    # Now ensure the GenServer is started and call the function with the specified timeout
    result =
      with {:ok, _pid} <- ensure_started() do
        GenServer.call(__MODULE__, {:call, module, function, args}, timeout)
      end

    # Format errors if requested
    format_errors = Map.get(options, :format_errors, true)

    case {result, format_errors} do
      {{:error, reason}, true} -> {:error, format_python_error(reason)}
      _ -> result
    end
  end

  @doc """
  Format Python errors into readable Elixir strings.
  """
  def format_python_error(error) do
    case error do
      {:exception, %ErlangError{original: {:python, error_type, error_msg, _traceback}}} ->
        error_type_str = Atom.to_string(error_type) |> String.replace("builtins.", "")

        error_msg_str =
          if is_list(error_msg),
            do: List.to_string(error_msg),
            else: "#{error_msg}"

        "Python #{error_type_str}: #{error_msg_str}"

      {:exception, %ErlangError{original: {:python, error_payload}}}
      when is_tuple(error_payload) ->
        "Python error: #{inspect(error_payload, pretty: true)}"

      # Handle other error formats
      {:exception, %ErlangError{original: original}} ->
        "Python error: #{inspect(original, pretty: true)}"

      # Catch-all for other error types
      err ->
        "Error: #{inspect(err, pretty: true)}"
    end
  end

  @doc """
  Register a callback function to receive progress updates from Python.
  The callback will be called with progress updates.
  """
  def register_progress_callback(pid_or_name \\ nil, module) do
    pid =
      cond do
        is_nil(pid_or_name) -> self()
        is_pid(pid_or_name) -> pid_or_name
        true -> Process.whereis(pid_or_name)
      end

    if is_nil(pid) do
      {:error, "Invalid process"}
    else
      with {:ok, _} <- ensure_started() do
        GenServer.call(__MODULE__, {:register_callback, pid, module})
      end
    end
  end

  @doc """
  Tests the connection to Python for a specific module.
  Returns true if connection is working, false otherwise.

  The timeout parameter allows for longer waiting times when testing connections
  that might involve loading large ML models (default: 30 seconds).
  """
  def test_connection(module) do
    with {:ok, _pid} <- ensure_started() do
      try do
        # Increase timeout from 5000 to 10000ms (10 seconds)
        result = GenServer.call(__MODULE__, {:test_connection, module}, 10000)
        if result, do: Logger.debug("Successfully connected to Python module: #{module}")
        result
      catch
        :exit, {_} ->
          Logger.error("Timeout after ms when testing connection to Python module: #{module}")

          false

        error, reason ->
          Logger.error(
            "Error when testing connection to Python module: #{module}, #{inspect({error, reason})}"
          )

          false
      end
    else
      _ -> false
    end
  end

  # GenServer implementation

  def init(opts) do
    # Ensure Python path exists
    File.mkdir_p!(@python_path)

    python_module = Keyword.get(opts, :python_module)
    Logger.info("Starting Python via erlport with path: #{@python_path}")

    # Start Python instance with improved error handling
    try do
      python_options = [
        {:python_path, to_charlist(@python_path)},
        # Explicitly specify python3
        {:python, ~c"python"},
        {:cd, to_charlist(@python_path)}
      ]

      case :python.start(python_options) do
        {:ok, python} ->
          # Allow process to handle exits
          Process.flag(:trap_exit, true)

          if python_module do
            # If a specific module was requested, verify it works
            case verify_python_connection(python, python_module) do
              :ok ->
                Logger.info("Python connection to #{python_module} successfully established")
                {:ok, %{python: python}}

              {:error, error_msg} ->
                Logger.error(
                  "Python verification failed for module: #{python_module} - #{error_msg}"
                )

                :python.stop(python)
                {:stop, :python_verification_failed}
            end
          else
            # No specific module requested, verify Python works with a basic test
            Logger.info("Python connection established successfully (no specific module)")
            {:ok, %{python: python}}
          end

        {:error, reason} ->
          Logger.error("Failed to start Python: #{inspect(reason)}")
          {:stop, :python_start_failed}
      end
    rescue
      e ->
        Logger.error("Exception starting Python: #{inspect(e)}")
        {:stop, {:python_error, e}}
    end
  end

  # Verify Python connection works by calling module.test_connection()
  defp verify_python_connection(python, module) when is_atom(module) do
    verify_python_connection(python, Atom.to_string(module))
  end

  defp verify_python_connection(python, module) when is_binary(module) do
    try do
      # Create an atom from the module name
      module_atom = String.to_atom(module)

      # Try the module's own test_connection function
      case :python.call(python, module_atom, :test_connection, []) do
        result when is_list(result) ->
          result_str = List.to_string(result)

          if result_str == "ok" do
            :ok
          else
            {:error, "Unexpected test result: #{result_str}"}
          end

        "ok" ->
          :ok

        other ->
          {:error, "Unexpected return type: #{inspect(other)}"}
      end
    rescue
      e -> {:error, "Python verification error: #{inspect(e)}"}
    catch
      kind, reason -> {:error, "Python verification caught: #{inspect({kind, reason})}"}
    end
  end

  # Server callbacks

  def handle_call({:call, mod, fun, args}, _from, %{python: python} = state) do
    reply =
      try do
        {:ok, :python.call(python, mod, fun, args)}
      rescue
        e -> {:error, {:exception, e}}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    {:reply, reply, state}
  end

  # Handle extra arguments by forwarding to the standard call handler
  def handle_call({:call, mod, fun, args, _extra_args}, from, state) do
    # Forward to the standard handler, ignoring extra arguments
    handle_call({:call, mod, fun, args}, from, state)
  end

  def handle_call({:test_connection, module}, %{python: python} = state) do
    # Default test with no specific module - just check if Python is alive
    result =
      try do
        test_result =
          :python.call(python, module, :test_connection, [])
          |> List.to_string()

        test_result == "ok"
      rescue
        _ -> false
      catch
        _, _ -> false
      end

    {:reply, result, state}
  end

  def handle_call({:test_connection, module}, _from, %{python: python} = state) do
    module_atom = if is_atom(module), do: module, else: String.to_atom("#{module}")

    result =
      try do
        # Try calling the test_connection function of the module
        case :python.call(python, module_atom, :test_connection, []) do
          result when is_list(result) ->
            result_str = List.to_string(result)
            Logger.debug("Module #{module} test_connection result: #{result_str}")
            result_str == "ok"

          "ok" ->
            Logger.debug("Module #{module} test_connection returned ok")
            true

          other ->
            Logger.warning(
              "Module #{module} test_connection returned unexpected: #{inspect(other)}"
            )

            false
        end
      rescue
        e ->
          Logger.error("Error testing connection to #{module}: #{inspect(e)}")
          false
      catch
        kind, reason ->
          Logger.error("Error testing connection to #{module}: #{inspect({kind, reason})}")
          false
      end

    {:reply, result, state}
  end

  # Register Python callback handler
  def handle_call({:register_callback, pid, module}, _from, state) do
    # Register the callback process
    new_state = Map.put(state, :callback_pid, pid)
    module_atom = if is_atom(module), do: module, else: String.to_atom("#{module}")

    # Try to call the module's register_callback function directly
    reply =
      try do
        :python.call(state.python, module_atom, :register_progress_callback, [])
        {:ok, "Callback registered"}
      rescue
        e ->
          Logger.info("Function for registering callback in Python file #{module} doesn't exist!")
          {:error, {:exception, e}}
      catch
        kind, reason ->
          Logger.info("Function for registering callback in Python file #{module} doesn't exist!")
          {:error, {kind, reason}}
      end

    {:reply, reply, new_state}
  end

  # Handle Python process exits
  def handle_info({:EXIT, python_pid, reason}, %{python: python_pid} = state) do
    Logger.error("Python process exited: #{inspect(reason)}")
    # Attempt to restart Python
    try do
      :python.stop(python_pid)
    catch
      _, _ -> :ok
    end

    case :python.start([{:python_path, to_charlist(@python_path)}]) do
      {:ok, new_python} ->
        Logger.info("Successfully restarted Python process")
        {:noreply, %{state | python: new_python}}

      {:error, restart_reason} ->
        Logger.error("Failed to restart Python: #{inspect(restart_reason)}")
        {:stop, {:python_restart_failed, restart_reason}, state}
    end
  end

  # Handle termination requests for Python
  def handle_info(:terminate_python, %{python: python} = state) do
    Logger.info("Received request to terminate Python process")
    # Gracefully stop the Python process
    :python.stop(python)
    # Don't restart - just end this GenServer instance
    {:stop, :normal, state}
  end

  def handle_info(msg, state) do
    Logger.debug("Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  def terminate(_reason, %{python: python}) do
    :python.stop(python)
    :ok
  end
end
