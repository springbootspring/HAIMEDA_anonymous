defmodule HaimedaCore.PerformanceMonitor do
  @moduledoc """
  Performance monitoring module for tracking execution time and system resources
  across different HAIMEDA modules.
  """

  require Logger
  use GenServer

  # Start the GenServer and ensure os_mon is started
  def start_link(opts \\ []) do
    :application.ensure_started(:os_mon)
    has_nvidia_gpu = check_nvidia_gpu_available()

    GenServer.start_link(
      __MODULE__,
      %{has_nvidia_gpu: has_nvidia_gpu},
      opts ++ [name: __MODULE__]
    )
  end

  # Check if NVIDIA GPU is available
  defp check_nvidia_gpu_available do
    try do
      case :os.type() do
        {:win32, _} ->
          # Try to run nvidia-smi on Windows
          {output, exit_code} =
            System.cmd("nvidia-smi", ["--query-gpu=name", "--format=csv,noheader"],
              stderr_to_stdout: true
            )

          exit_code == 0 && String.trim(output) != ""

        {:unix, _} ->
          # Try to run nvidia-smi on Unix-like systems
          {output, exit_code} =
            System.cmd("nvidia-smi", ["--query-gpu=name", "--format=csv,noheader"],
              stderr_to_stdout: true
            )

          exit_code == 0 && String.trim(output) != ""

        _ ->
          false
      end
    rescue
      _ -> false
    end
  end

  @doc """
  Starts tracking performance for a given module/operation.
  Returns a tracking key that should be used to stop tracking.
  """
  def start_tracking(module_name, operation_name \\ nil) do
    if Process.whereis(__MODULE__) do
      tracking_key = generate_tracking_key(module_name, operation_name)

      # Get the state to check if GPU monitoring is available
      state = GenServer.call(__MODULE__, :get_state)

      # Initial CPU and GPU metrics
      initial_cpu = get_cpu_usage()
      initial_gpu = if(state.has_nvidia_gpu, do: get_gpu_usage(), else: nil)

      initial_metrics = %{
        start_time: System.monotonic_time(:millisecond),
        start_memory: get_memory_usage(),
        start_cpu: initial_cpu,
        start_gpu: initial_gpu,
        # Initialize peak metrics to match starting metrics
        peak_memory: get_memory_usage(),
        peak_cpu: initial_cpu,
        peak_gpu: initial_gpu,
        module: module_name,
        operation: operation_name
      }

      # Start a background process for peak tracking
      if Process.whereis(__MODULE__) do
        tracking_pid =
          spawn_link(fn ->
            track_peak_metrics(tracking_key, state.has_nvidia_gpu)
          end)

        # Store the tracking process PID with the metrics
        initial_metrics = Map.put(initial_metrics, :tracking_pid, tracking_pid)

        GenServer.call(__MODULE__, {:start_tracking, tracking_key, initial_metrics})
        tracking_key
      else
        Logger.warning("PerformanceMonitor not started, skipping tracking")
        nil
      end
    else
      Logger.warning("PerformanceMonitor not started, skipping tracking")
      nil
    end
  end

  # Background process to track peak resource usage
  defp track_peak_metrics(tracking_key, has_gpu) do
    # Check every 100ms for peak values
    Process.sleep(100)

    # Only continue if the module is still running
    if Process.whereis(__MODULE__) do
      # Get current metrics
      current_memory = get_memory_usage()
      current_cpu = get_cpu_usage()
      current_gpu = if has_gpu, do: get_gpu_usage(), else: nil

      # Get the stored metrics
      case GenServer.call(__MODULE__, {:get_tracking, tracking_key}) do
        nil ->
          # Tracking has been stopped, end this process
          :ok

        metrics ->
          # Get current peak values
          peak_memory = metrics.peak_memory
          peak_cpu = metrics.peak_cpu
          peak_gpu = metrics.peak_gpu

          # Update peak memory if current is higher
          new_peak_memory = max(peak_memory, current_memory)

          # Update peak CPU using custom comparator
          new_peak_cpu = update_peak_cpu(peak_cpu, current_cpu)

          # Update peak GPU using custom comparator (if GPU is available)
          new_peak_gpu =
            if peak_gpu && current_gpu do
              update_peak_gpu(peak_gpu, current_gpu)
            else
              peak_gpu
            end

          # Update the tracking state with new peak values
          updated_metrics =
            metrics
            |> Map.put(:peak_memory, new_peak_memory)
            |> Map.put(:peak_cpu, new_peak_cpu)
            |> Map.put(:peak_gpu, new_peak_gpu)

          GenServer.call(__MODULE__, {:update_tracking, tracking_key, updated_metrics})

          # Continue tracking
          track_peak_metrics(tracking_key, has_gpu)
      end
    end
  end

  # Parse GPU metrics output safely
  defp get_gpu_usage do
    try do
      {util_output, 0} =
        System.cmd(
          "nvidia-smi",
          [
            "--query-gpu=utilization.gpu,memory.used,memory.total",
            "--format=csv,noheader,nounits"
          ],
          stderr_to_stdout: true
        )

      case String.split(String.trim(util_output), ",") do
        [utilization, memory_used, memory_total] ->
          utilization_parsed = parse_float_safely(String.trim(utilization))
          memory_used_parsed = parse_float_safely(String.trim(memory_used))
          memory_total_parsed = parse_float_safely(String.trim(memory_total))

          if utilization_parsed != nil && memory_used_parsed != nil && memory_total_parsed != nil do
            %{
              utilization: utilization_parsed,
              memory_used_mb: memory_used_parsed,
              memory_total_mb: memory_total_parsed
            }
          else
            Logger.debug("Failed to parse one or more GPU metrics")
            nil
          end

        _ ->
          Logger.debug("Unexpected GPU metrics format from nvidia-smi")
          nil
      end
    rescue
      e ->
        Logger.debug("GPU monitoring error: #{inspect(e)}")
        nil
    end
  end

  # Update CPU peak values, comparing all relevant metrics
  defp update_peak_cpu(peak_cpu, current_cpu) do
    if is_map(peak_cpu) && is_map(current_cpu) do
      peak_percentage = Map.get(peak_cpu, :cpu_percentage, 0.0)
      current_percentage = Map.get(current_cpu, :cpu_percentage, 0.0)

      # If current usage is higher, update the peak
      if current_percentage > peak_percentage do
        current_cpu
      else
        peak_cpu
      end
    else
      peak_cpu
    end
  end

  # Update GPU peak values
  defp update_peak_gpu(peak_gpu, current_gpu) do
    if is_map(peak_gpu) && is_map(current_gpu) do
      peak_utilization = Map.get(peak_gpu, :utilization, 0.0)
      current_utilization = Map.get(current_gpu, :utilization, 0.0)

      peak_memory = Map.get(peak_gpu, :memory_used_mb, 0.0)
      current_memory = Map.get(current_gpu, :memory_used_mb, 0.0)

      # If either utilization or memory usage is higher, update the peak
      if current_utilization > peak_utilization || current_memory > peak_memory do
        current_gpu
      else
        peak_gpu
      end
    else
      peak_gpu
    end
  end

  @doc """
  Stops tracking and outputs performance metrics if enabled.
  """
  def stop_tracking(tracking_key, show_performance_outputs \\ true)
  def stop_tracking(nil, _), do: :ok

  def stop_tracking(tracking_key, show_performance_outputs) do
    if Process.whereis(__MODULE__) do
      case GenServer.call(__MODULE__, {:get_tracking, tracking_key}) do
        nil ->
          Logger.warning("Performance tracking key not found: #{tracking_key}")
          :ok

        initial_metrics ->
          # If there's a tracking process running, terminate it
          if Map.has_key?(initial_metrics, :tracking_pid) do
            tracking_pid = Map.get(initial_metrics, :tracking_pid)

            if Process.alive?(tracking_pid) do
              Process.exit(tracking_pid, :normal)
            end
          end

          # Calculate final metrics
          end_time = System.monotonic_time(:millisecond)
          end_memory = get_memory_usage()
          end_cpu = get_cpu_usage()
          end_gpu = if Map.get(initial_metrics, :start_gpu), do: get_gpu_usage(), else: nil

          duration_ms = end_time - initial_metrics.start_time
          memory_diff = end_memory - initial_metrics.start_memory

          # Remove from tracking state
          GenServer.call(__MODULE__, {:stop_tracking, tracking_key})

          # Output performance metrics if enabled
          if show_performance_outputs do
            output_performance_metrics(%{
              module: initial_metrics.module,
              operation: initial_metrics.operation,
              duration_ms: duration_ms,
              memory_diff_mb: memory_diff,
              start_cpu: initial_metrics.start_cpu,
              end_cpu: end_cpu,
              peak_cpu: initial_metrics.peak_cpu,
              start_gpu: initial_metrics.start_gpu,
              end_gpu: end_gpu,
              peak_gpu: initial_metrics.peak_gpu,
              peak_memory: initial_metrics.peak_memory
            })
          end

          :ok
      end
    else
      Logger.warning("PerformanceMonitor not started, skipping stop tracking")
      :ok
    end
  end

  @doc """
  Convenience function to track a function execution.
  """
  def track_execution(module_name, operation_name, show_performance_outputs, func) do
    tracking_key = start_tracking(module_name, operation_name)

    try do
      result = func.()
      stop_tracking(tracking_key, show_performance_outputs)
      result
    rescue
      error ->
        stop_tracking(tracking_key, show_performance_outputs)
        reraise error, __STACKTRACE__
    end
  end

  # GenServer Callbacks

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call({:start_tracking, tracking_key, initial_metrics}, _from, state) do
    new_state = Map.put(state, tracking_key, initial_metrics)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:get_tracking, tracking_key}, _from, state) do
    {:reply, Map.get(state, tracking_key), state}
  end

  @impl true
  def handle_call({:stop_tracking, tracking_key}, _from, state) do
    new_state = Map.delete(state, tracking_key)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:update_tracking, tracking_key, updated_metrics}, _from, state) do
    new_state = Map.put(state, tracking_key, updated_metrics)
    {:reply, :ok, new_state}
  end

  defp generate_tracking_key(module_name, operation_name) do
    timestamp = System.monotonic_time(:microsecond)
    base_key = "#{module_name}#{if operation_name, do: "_#{operation_name}", else: ""}"
    "#{base_key}_#{timestamp}"
  end

  defp get_memory_usage do
    # Get current process memory usage in MB
    case :erlang.memory(:total) do
      memory_bytes when is_integer(memory_bytes) ->
        Float.round(memory_bytes / 1_048_576, 2)

      _ ->
        0.0
    end
  end

  defp get_cpu_usage do
    try do
      # Base CPU usage (percentage)
      cpu_percentage = get_cpu_percentage()

      # Get core count information
      cpu_count = :erlang.system_info(:logical_processors_available)

      # Try to get per-core utilization on Windows
      per_core_usage = get_per_core_usage()

      # Get memory information (system total memory in MB)
      system_memory = get_system_memory_mb()

      # Get process memory (this Elixir process memory in MB)
      process_memory = get_memory_usage()

      # Return a comprehensive CPU metrics map
      %{
        cpu_percentage: cpu_percentage,
        cpu_count: cpu_count,
        per_core_usage: per_core_usage,
        process_memory_mb: process_memory,
        system_memory_mb: system_memory
      }
    rescue
      e ->
        Logger.debug("CPU monitoring error: #{inspect(e)}")
        %{cpu_percentage: 0.0}
    end
  end

  # Get system total memory in MB
  defp get_system_memory_mb do
    try do
      case :os.type() do
        {:win32, _} ->
          # Use PowerShell to get total physical memory on Windows
          {output, 0} =
            System.cmd(
              "powershell",
              ["-Command", "(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1MB"],
              stderr_to_stdout: true
            )

          case Float.parse(String.trim(output)) do
            {memory_mb, _} -> Float.round(memory_mb, 0)
            :error -> 0.0
          end

        _ ->
          # For Unix systems, try to use OS_Mon or a fallback
          try do
            {output, 0} = System.cmd("free", ["-m"], stderr_to_stdout: true)
            [_, line | _] = String.split(output, "\n")
            [_, total | _] = String.split(line)
            {total_mb, _} = Float.parse(total)
            total_mb
          rescue
            _ ->
              # Return default value if we can't get the memory
              16000.0
          end
      end
    rescue
      # Default to 16GB if we can't determine
      _ -> 16000.0
    end
  end

  defp get_cpu_percentage do
    try do
      # Check if we're running on Windows
      case :os.type() do
        {:win32, _} ->
          # Windows-specific approach using PowerShell
          {output, exit_code} =
            System.cmd(
              "powershell",
              [
                "-Command",
                "(Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average"
              ],
              stderr_to_stdout: true
            )

          # Parse the output if command was successful
          if exit_code == 0 do
            case Float.parse(String.trim(output)) do
              {cpu_usage, _} ->
                Float.round(cpu_usage, 1)

              :error ->
                # Fallback to alternative Windows CPU measurement if first approach fails
                measure_windows_cpu_fallback()
            end
          else
            # Try fallback method if the first command failed
            measure_windows_cpu_fallback()
          end

        _ ->
          # Non-Windows platforms - try using OS_Mon if available
          case :application.get_application(:os_mon) do
            {:ok, _} ->
              case :cpu_sup.util() do
                {:badrpc, _} -> 0.0
                cpu_util when is_number(cpu_util) -> Float.round(cpu_util, 2)
                _ -> 0.0
              end

            _ ->
              Logger.debug("OS_Mon application not available for CPU monitoring")
              0.0
          end
      end
    rescue
      e ->
        Logger.debug("CPU percentage monitoring error: #{inspect(e)}")
        0.0
    end
  end

  # Get per-core CPU usage (works on Windows)
  defp get_per_core_usage do
    try do
      case :os.type() do
        {:win32, _} ->
          # Get per-core usage on Windows using PowerShell
          {output, exit_code} =
            System.cmd(
              "powershell",
              [
                "-Command",
                "(Get-CimInstance Win32_Processor | Select-Object -ExpandProperty LoadPercentageByCore)"
              ],
              stderr_to_stdout: true
            )

          if exit_code == 0 do
            # Parse the output into a list of per-core percentages
            output
            |> String.trim()
            |> String.split("\n", trim: true)
            |> Enum.map(&String.trim/1)
            |> Enum.map(fn str ->
              case Float.parse(str) do
                {value, _} -> value
                :error -> 0.0
              end
            end)
          else
            []
          end

        _ ->
          # Unix systems - could implement with /proc/stat parsing
          []
      end
    rescue
      _ -> []
    end
  end

  # Fallback method for Windows CPU measurement using an alternative PowerShell command
  defp measure_windows_cpu_fallback do
    try do
      {output, 0} =
        System.cmd(
          "powershell",
          [
            "-Command",
            "Get-Counter '\\Processor(_Total)\\% Processor Time' | Select-Object -ExpandProperty CounterSamples | Select-Object -ExpandProperty CookedValue"
          ],
          stderr_to_stdout: true
        )

      case Float.parse(String.trim(output)) do
        {cpu_usage, _} -> Float.round(cpu_usage, 1)
        :error -> 0.0
      end
    rescue
      _ -> 0.0
    end
  end

  # Helper function to safely parse a float string
  defp parse_float_safely(str) do
    try do
      # Remove any non-numeric characters except decimal point
      clean_str =
        str
        # Keep only digits, decimal point and negative sign
        |> String.replace(~r/[^\d\.-]/, "")
        |> String.trim()

      case Float.parse(clean_str) do
        {value, _} -> value
        :error -> nil
      end
    rescue
      _ -> nil
    end
  end

  defp output_performance_metrics(metrics) do
    module_display =
      if metrics.operation do
        "#{metrics.module}.#{metrics.operation}"
      else
        "#{metrics.module}"
      end

    duration_display = format_duration(metrics.duration_ms)
    memory_display = format_memory_change(metrics.memory_diff_mb)

    IO.puts(
      "\n" <>
        IO.ANSI.magenta() <>
        "[debug_performance] " <>
        IO.ANSI.cyan() <> "=== PERFORMANCE METRICS ===" <> IO.ANSI.reset()
    )

    IO.puts(
      IO.ANSI.magenta() <>
        "[debug_performance] " <>
        IO.ANSI.bright() <> "Module: " <> IO.ANSI.reset() <> "#{module_display}"
    )

    IO.puts(
      IO.ANSI.magenta() <>
        "[debug_performance] " <>
        IO.ANSI.bright() <> "Duration: " <> IO.ANSI.reset() <> "#{duration_display}"
    )

    IO.puts(
      IO.ANSI.magenta() <>
        "[debug_performance] " <>
        IO.ANSI.bright() <> "Memory Change: " <> IO.ANSI.reset() <> "#{memory_display}"
    )

    # Output process memory separately if available
    if metrics.start_cpu && is_map(metrics.start_cpu) && metrics.end_cpu &&
         is_map(metrics.end_cpu) do
      process_memory_start = Map.get(metrics.start_cpu, :process_memory_mb, 0)
      process_memory_end = Map.get(metrics.end_cpu, :process_memory_mb, 0)
      system_memory = Map.get(metrics.end_cpu, :system_memory_mb, 0)

      if process_memory_end > 0 do
        IO.puts(
          IO.ANSI.magenta() <>
            "[debug_performance] " <>
            IO.ANSI.bright() <>
            "Process Memory: " <>
            IO.ANSI.reset() <>
            "#{Float.round(process_memory_start, 1)}MB → #{Float.round(process_memory_end, 1)}MB (of #{system_memory}MB system total)"
        )
      end
    end

    # Output CPU utilization with peak and core count
    if metrics.start_cpu && metrics.end_cpu && metrics.peak_cpu do
      cpu_display =
        format_cpu_usage_with_peak_and_cores(metrics.start_cpu, metrics.end_cpu, metrics.peak_cpu)

      IO.puts(
        IO.ANSI.magenta() <>
          "[debug_performance] " <>
          IO.ANSI.bright() <> "CPU Utilization: " <> IO.ANSI.reset() <> "#{cpu_display}"
      )
    end

    # Add GPU metrics with peak if available
    if metrics.start_gpu && metrics.end_gpu && metrics.peak_gpu do
      gpu_display =
        format_gpu_usage_with_peak(metrics.start_gpu, metrics.end_gpu, metrics.peak_gpu)

      IO.puts(
        IO.ANSI.magenta() <>
          "[debug_performance] " <>
          IO.ANSI.bright() <> "GPU Utilization: " <> IO.ANSI.reset() <> "#{gpu_display}"
      )
    end

    IO.puts(
      IO.ANSI.magenta() <>
        "[debug_performance] " <>
        IO.ANSI.cyan() <> "===========================" <> IO.ANSI.reset() <> "\n"
    )
  end

  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 2)}s"
  defp format_duration(ms), do: "#{Float.round(ms / 60_000, 2)}min"

  defp format_memory_change(mb) when mb > 0, do: "+#{mb}MB"
  defp format_memory_change(mb) when mb < 0, do: "#{mb}MB"
  defp format_memory_change(_), do: "0MB"

  # Format CPU usage information showing before and after values
  defp format_cpu_usage(start_cpu, end_cpu) do
    # Get CPU utilization percentages
    start_percentage = extract_cpu_percentage(start_cpu)
    end_percentage = extract_cpu_percentage(end_cpu)

    # Format the display string to show change in utilization
    "#{start_percentage}% → #{end_percentage}%"
  end

  # Format CPU usage with peak information and core count
  defp format_cpu_usage_with_peak_and_cores(start_cpu, end_cpu, peak_cpu) do
    # Get CPU utilization percentages
    start_percentage = extract_cpu_percentage(start_cpu)
    end_percentage = extract_cpu_percentage(end_cpu)
    peak_percentage = extract_cpu_percentage(peak_cpu)

    # Get CPU core count
    cpu_count = Map.get(end_cpu, :cpu_count, 0)
    cores_info = if cpu_count > 0, do: " [#{cpu_count} cores]", else: ""

    # Format the display string to show change and peak in utilization
    "#{start_percentage}% → #{end_percentage}% (peak: #{peak_percentage}%)#{cores_info}"
  end

  # Format GPU usage information showing before and after values
  defp format_gpu_usage(start_gpu, end_gpu) do
    # Extract utilization percentages
    start_util = start_gpu.utilization
    end_util = end_gpu.utilization

    # Extract memory usage values
    start_mem = start_gpu.memory_used_mb
    end_mem = end_gpu.memory_used_mb
    total_mem = end_gpu.memory_total_mb

    # Format string to show changes in utilization and memory
    "#{start_util}% → #{end_util}%, VRAM: #{Float.round(start_mem, 0)}MB → #{Float.round(end_mem, 0)}MB (of #{Float.round(total_mem, 0)}MB)"
  end

  # Format GPU usage with peak information - clarifying that utilization % is separate from VRAM
  defp format_gpu_usage_with_peak(start_gpu, end_gpu, peak_gpu) do
    # Extract utilization percentages
    start_util = start_gpu.utilization
    end_util = end_gpu.utilization
    peak_util = peak_gpu.utilization

    # Extract memory usage values
    start_mem = start_gpu.memory_used_mb
    end_mem = end_gpu.memory_used_mb
    peak_mem = peak_gpu.memory_used_mb
    total_mem = end_gpu.memory_total_mb

    # Format string to show changes and peaks in utilization and memory
    "#{start_util}% → #{end_util}% (peak: #{peak_util}%), " <>
      "VRAM: #{Float.round(start_mem, 0)}MB → #{Float.round(end_mem, 0)}MB (peak: #{Float.round(peak_mem, 0)}MB of #{Float.round(total_mem, 0)}MB)"
  end

  # Helper to extract CPU percentage from a CPU metrics map
  defp extract_cpu_percentage(cpu_metrics) when is_map(cpu_metrics) do
    Map.get(cpu_metrics, :cpu_percentage, 0.0)
  end

  defp extract_cpu_percentage(_), do: 0.0
end
