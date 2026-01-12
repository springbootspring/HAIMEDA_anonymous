defmodule OllamaService do
  alias HaimedaCore.GeneralHelperFunctions, as: GHF

  def integrate_gguf_in_ollama(
        path_gguf_file,
        overwrite \\ true,
        modelfile_parameters \\ nil
      ) do
    raw_name = Path.basename(path_gguf_file, ".gguf")
    model_name = sanitize_model_name(raw_name)

    modelfile_params =
      case modelfile_parameters do
        nil -> ""
        params when is_map(params) -> format_params_for_modelfile(params)
        _ -> ""
      end

    # Check if model already exists in Ollama
    model_exists =
      case System.cmd("ollama", ["list"], stderr_to_stdout: true) do
        {output, 0} ->
          # Get models from output, handling both with and without ":latest" suffix
          models = String.split(output, "\n")

          # Check for exact model name or model_name:latest
          Enum.any?(models, fn line ->
            model_parts = String.split(line) |> Enum.at(0, "")
            model_parts == model_name || model_parts == "#{model_name}:latest"
          end)

        _ ->
          false
      end

    # Skip integration if model exists and overwrite is false
    if model_exists && !overwrite do
      IO.puts("Model #{model_name} already exists. Skipping integration.")
      {:ok, "Model #{model_name} already exists, integration skipped"}
    else
      # Remove existing model if overwrite is true and model exists
      if model_exists && overwrite do
        case System.cmd("ollama", ["rm", model_name], stderr_to_stdout: true) do
          {_, 0} ->
            IO.puts("Removed existing model #{model_name} for replacement.")

          {error, code} ->
            IO.puts(
              "Warning: Model #{model_name} was detected but couldn't be removed. Error code: #{code}"
            )

            IO.puts("Error details: #{error}")
            # Continue with model creation anyway since we intended to overwrite
        end
      end

      # Create temporary directory for Modelfile
      temp_dir =
        Path.join(System.tmp_dir(), "ollama_integration_#{:os.system_time(:millisecond)}")

      File.mkdir_p!(temp_dir)
      modelfile_path = Path.join(temp_dir, "Modelfile")

      complete_modelfile_content = """
      FROM #{path_gguf_file}
      #{modelfile_params}
      """

      File.write!(modelfile_path, complete_modelfile_content)

      # Create the model
      case System.cmd("ollama", ["create", model_name, "-f", modelfile_path],
             stderr_to_stdout: true
           ) do
        {output, 0} ->
          IO.puts("Successfully integrated model into Ollama:")
          IO.puts(output)
          File.rm_rf!(temp_dir)
          {:ok, "Model #{model_name} successfully integrated into Ollama"}

        {error, code} ->
          IO.puts("Failed to integrate model into Ollama. Exit code: #{code}")
          IO.puts("Error: #{error}")
          File.rm_rf!(temp_dir)
          {:error, "Failed to integrate model with error: #{error}"}
      end
    end
  end

  def pull_model_if_not_available(model_name) do
    # Get all available models with exact names
    available_models = list_available_models()

    IO.inspect(available_models, label: "Available models in Ollama")

    # Check if auto quantization is enabled
    auto_quantized = GHF.get_auto_quantized_models_setting()

    # Try to find exact match first (with and without :latest)
    exact_match =
      Enum.find(available_models, fn available ->
        available == model_name or available == "#{model_name}:latest"
      end)

    # Try to find case-insensitive match (with and without :latest)
    case_insensitive_match =
      Enum.find(available_models, fn available ->
        String.downcase(available) == String.downcase(model_name) or
          String.downcase(available) == String.downcase("#{model_name}:latest")
      end)

    cond do
      # If exact match exists, check if we should use a quantized version instead
      exact_match != nil ->
        if auto_quantized do
          case select_optimal_model_for_vram(model_name, available_models) do
            {:ok, optimal_model} when optimal_model != exact_match ->
              IO.puts("VRAM optimization: using '#{optimal_model}' instead of '#{exact_match}'")
              {:ok, optimal_model}
            _ ->
              IO.puts("Model '#{exact_match}' already exists.")
              {:ok, exact_match}
          end
        else
          IO.puts("Model '#{exact_match}' already exists.")
          {:ok, exact_match}
        end

      # If case-insensitive match exists, use the correctly cased version
      case_insensitive_match != nil ->
        if auto_quantized do
          case select_optimal_model_for_vram(model_name, available_models) do
            {:ok, optimal_model} when optimal_model != case_insensitive_match ->
              IO.puts("VRAM optimization: using '#{optimal_model}' instead of '#{case_insensitive_match}'")
              {:ok, optimal_model}
            _ ->
              IO.puts(
                "Model found with different case: requested '#{model_name}', using '#{case_insensitive_match}'"
              )
              {:ok, case_insensitive_match}
          end
        else
          IO.puts(
            "Model found with different case: requested '#{model_name}', using '#{case_insensitive_match}'"
          )
          {:ok, case_insensitive_match}
        end

      # Otherwise try to pull it
      true ->
        IO.puts("Model '#{model_name}' not found locally, attempting to pull...")

        # If auto quantization is enabled, try to find and pull the best quantized version
        if auto_quantized do
          case find_and_pull_optimal_quantized_model(model_name) do
            {:ok, optimal_model} ->
              IO.puts("Successfully pulled optimal quantized model: '#{optimal_model}'")
              {:ok, optimal_model}
            _ ->
              # Fallback to standard pulling logic
              attempt_standard_pull(model_name)
          end
        else
          attempt_standard_pull(model_name)
        end
    end
  end

  # Attempt standard model pulling with case variations
  defp attempt_standard_pull(model_name) do
    # Try case variations for models that might have been listed with different casing
    case try_pull_with_case_variations(model_name) do
      {:ok, actual_model} ->
        # Successfully pulled a variant
        IO.puts("Successfully pulled model variant '#{actual_model}'")
        {:ok, actual_model}

      _ ->
        # Standard pull attempt
        case System.cmd("ollama", ["pull", model_name], stderr_to_stdout: true) do
          {output, 0} ->
            IO.puts("Successfully pulled model from Ollama:")
            IO.puts(output)
            {:ok, model_name}

          {error, code} ->
            IO.puts("Failed to pull model from Ollama. Exit code: #{code}")
            IO.puts("Error: #{error}")
            {:error, :model_not_available}
        end
    end
  end

  # Try pulling model with different case variations
  defp try_pull_with_case_variations(model_name) do
    # Generate common case variations
    variations =
      [
        model_name,
        String.downcase(model_name),
        String.upcase(model_name),
        # Convert v1/v2/v3 to V1/V2/V3
        Regex.replace(~r/v(\d+)/, model_name, fn _, num -> "V#{num}" end)
      ]
      |> Enum.uniq()

    # Try each variation until one succeeds
    Enum.reduce_while(variations, {:error, :no_match}, fn variation, _acc ->
      if variation == model_name do
        # Skip the original name (we'll try it later if nothing else works)
        {:cont, {:error, :no_match}}
      else
        IO.puts("Trying model variant: #{variation}")

        case System.cmd("ollama", ["pull", variation], stderr_to_stdout: true) do
          {_output, 0} ->
            # Found a working variant
            {:halt, {:ok, variation}}

          _ ->
            # Try next variation
            {:cont, {:error, :no_match}}
        end
      end
    end)
  end

  # Get list of available models in Ollama
  def list_available_models do
    case System.cmd("ollama", ["list"], stderr_to_stdout: true) do
      {output, 0} ->
        # Parse the output to extract model names
        output
        |> String.split("\n")
        # Skip header line
        |> Enum.drop(1)
        |> Enum.filter(&(String.trim(&1) != ""))
        |> Enum.map(fn line ->
          line
          |> String.split()
          |> List.first()
        end)
        |> Enum.filter(&(&1 != nil))

      _ ->
        []
    end
  end

  # Helper function to format parameters as Modelfile directives
  defp format_params_for_modelfile(params) do
    params
    |> Enum.map_join("\n", fn
      # Map LLM params to Ollama-compatible parameters
      {:max_tokens, value} ->
        "PARAMETER num_predict #{value}"

      {:temperature, value} ->
        "PARAMETER temperature #{value}"

      {:top_p, value} ->
        "PARAMETER top_p #{value}"

      {:top_k, value} ->
        "PARAMETER top_k #{value}"

      {:repeat_penalty, value} ->
        "PARAMETER repeat_penalty #{value}"

      {key, value} ->
        "# Unmapped parameter: #{key}=#{value}"
    end)
  end

  def sanitize_model_name(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^A-Za-z0-9_-]/u, "_")
    |> String.replace(~r/_+/u, "_")
    |> String.replace(~r/^_|_$/u, "")
    |> then(fn s -> if s == "", do: "model", else: s end)
  end

  # Get available VRAM in MB from the system using nvidia-smi or similar tools
  defp get_available_vram_mb do
    try do
      # Try NVIDIA first (most common)
      case get_nvidia_vram() do
        {:ok, vram_mb} -> vram_mb
        _ -> 
          # Fallback to other GPU vendors or default
          case get_amd_vram() do
            {:ok, vram_mb} -> vram_mb
            _ -> 
              IO.puts("Warning: Could not detect GPU VRAM, assuming 8GB")
              8192 # Default fallback
          end
      end
    rescue
      _ -> 
        IO.puts("Warning: Error detecting GPU VRAM, assuming 8GB")
        8192 # Default fallback
    end
  end

  # Get NVIDIA GPU VRAM using nvidia-smi
  defp get_nvidia_vram do
    case System.cmd("nvidia-smi", ["--query-gpu=memory.free", "--format=csv,noheader,nounits"], stderr_to_stdout: true) do
      {output, 0} ->
        # Parse the output to get free VRAM in MB
        output
        |> String.trim()
        |> String.split("\n")
        |> List.first()
        |> String.trim()
        |> Integer.parse()
        |> case do
          {vram_mb, ""} -> 
            IO.puts("Detected NVIDIA GPU with #{vram_mb}MB free VRAM")
            {:ok, vram_mb}
          _ -> {:error, :parse_failed}
        end

      _ ->
        {:error, :nvidia_smi_failed}
    end
  end

  # Get AMD GPU VRAM (basic implementation)
  defp get_amd_vram do
    # Try rocm-smi for AMD GPUs
    case System.cmd("rocm-smi", ["--showmeminfo", "vram"], stderr_to_stdout: true) do
      {output, 0} ->
        # Parse rocm-smi output (simplified)
        case Regex.run(~r/(\d+)\s*MB/, output) do
          [_, vram_str] ->
            case Integer.parse(vram_str) do
              {vram_mb, ""} -> 
                IO.puts("Detected AMD GPU with #{vram_mb}MB VRAM")
                {:ok, vram_mb}
              _ -> {:error, :parse_failed}
            end
          _ ->
            {:error, :parse_failed}
        end
      _ ->
        {:error, :rocm_smi_failed}
    end
  end

  # Estimate model VRAM requirements in MB based on model name
  defp estimate_model_vram_mb(model_name) do
    model_lower = String.downcase(model_name)
    
    cond do
      # Large models (70B+ parameters)
      String.contains?(model_lower, "70b") or String.contains?(model_lower, "72b") ->
        estimate_by_quantization(model_lower, 140_000) # ~140GB for fp16
      
      # Medium-large models (30-65B parameters)  
      String.contains?(model_lower, "30b") or String.contains?(model_lower, "33b") or 
      String.contains?(model_lower, "34b") or String.contains?(model_lower, "65b") ->
        estimate_by_quantization(model_lower, 70_000) # ~70GB for fp16
      
      # Medium models (13-20B parameters)
      String.contains?(model_lower, "13b") or String.contains?(model_lower, "15b") or
      String.contains?(model_lower, "20b") ->
        estimate_by_quantization(model_lower, 26_000) # ~26GB for fp16
      
      # Small-medium models (7-8B parameters)
      String.contains?(model_lower, "7b") or String.contains?(model_lower, "8b") ->
        estimate_by_quantization(model_lower, 14_000) # ~14GB for fp16
      
      # Small models (3-4B parameters)
      String.contains?(model_lower, "3b") or String.contains?(model_lower, "4b") ->
        estimate_by_quantization(model_lower, 8_000) # ~8GB for fp16
      
      # Very small models (1-2B parameters)
      String.contains?(model_lower, "1b") or String.contains?(model_lower, "2b") ->
        estimate_by_quantization(model_lower, 4_000) # ~4GB for fp16
      
      # Default estimation for unknown models
      true ->
        8_000 # Default to ~8GB
    end
  end

  # Estimate VRAM based on quantization level
  defp estimate_by_quantization(model_name, base_vram_mb) do
    cond do
      # Q2 quantization (~2 bits per parameter)
      String.contains?(model_name, "q2") ->
        trunc(base_vram_mb * 0.125) # ~1/8 of fp16
      
      # Q4 quantization (~4 bits per parameter)
      String.contains?(model_name, "q4") ->
        trunc(base_vram_mb * 0.25) # ~1/4 of fp16
      
      # Q5 quantization (~5 bits per parameter)
      String.contains?(model_name, "q5") ->
        trunc(base_vram_mb * 0.3125) # ~5/16 of fp16
      
      # Q6 quantization (~6 bits per parameter)
      String.contains?(model_name, "q6") ->
        trunc(base_vram_mb * 0.375) # ~3/8 of fp16
      
      # Q8 quantization (~8 bits per parameter)
      String.contains?(model_name, "q8") ->
        trunc(base_vram_mb * 0.5) # ~1/2 of fp16
      
      # No quantization specified - assume fp16
      true ->
        base_vram_mb
    end
  end

  # Select the optimal model variant for available VRAM
  defp select_optimal_model_for_vram(base_model_name, available_models) do
    available_vram = get_available_vram_mb()
    
    # Reserve some VRAM for system and other processes (e.g., 2GB)
    usable_vram = max(available_vram - 2048, 0)
    
    IO.puts("Available VRAM: #{available_vram}MB, Usable: #{usable_vram}MB")
    
    # Extract base name (without quantization suffix)
    base_name = extract_base_model_name(base_model_name)
    
    # Find all variants of this model in available models
    model_variants = 
      available_models
      |> Enum.filter(fn model -> 
        model_base = extract_base_model_name(model)
        String.downcase(model_base) == String.downcase(base_name)
      end)
    
    # Sort variants by VRAM requirements (ascending)
    suitable_models =
      model_variants
      |> Enum.map(fn model -> 
        vram_req = estimate_model_vram_mb(model)
        {model, vram_req}
      end)
      |> Enum.filter(fn {_model, vram_req} -> vram_req <= usable_vram end)
      |> Enum.sort_by(fn {_model, vram_req} -> -vram_req end) # Descending - prefer higher quality
    
    case suitable_models do
      [] -> 
        IO.puts("No suitable model variants found for #{usable_vram}MB VRAM")
        {:error, :no_suitable_model}
      [{best_model, vram_req} | _] ->
        IO.puts("Selected model '#{best_model}' requiring #{vram_req}MB VRAM")
        {:ok, best_model}
    end
  end

  # Find and pull the optimal quantized model variant
  defp find_and_pull_optimal_quantized_model(model_name) do
    available_vram = get_available_vram_mb()
    usable_vram = max(available_vram - 2048, 0)
    
    # Generate quantized variants to try (in order of preference)
    quantized_variants = generate_quantized_variants(model_name)
    
    # Try to pull the best variant that fits in VRAM
    Enum.reduce_while(quantized_variants, {:error, :no_model_found}, fn variant, _acc ->
      vram_req = estimate_model_vram_mb(variant)
      
      if vram_req <= usable_vram do
        IO.puts("Trying to pull '#{variant}' (estimated #{vram_req}MB VRAM)")
        
        case System.cmd("ollama", ["pull", variant], stderr_to_stdout: true) do
          {_output, 0} ->
            {:halt, {:ok, variant}}
          _ ->
            IO.puts("Failed to pull '#{variant}', trying next variant...")
            {:cont, {:error, :no_model_found}}
        end
      else
        IO.puts("Skipping '#{variant}' (requires #{vram_req}MB, only #{usable_vram}MB available)")
        {:cont, {:error, :no_model_found}}
      end
    end)
  end

  # Extract base model name without quantization suffix
  defp extract_base_model_name(model_name) do
    model_name
    |> String.replace(~r/_q\d+.*$/i, "") # Remove _q8_0, _q4_k_m, etc.
    |> String.replace(~r/:latest$/i, "") # Remove :latest tag
  end

  # Generate quantized variants of a model (in order of preference)
  defp generate_quantized_variants(base_model_name) do
    base = extract_base_model_name(base_model_name)
    
    [
      # Try quantized versions first (smaller VRAM requirements)
      "#{base}_q4_k_m",
      "#{base}_q4_0", 
      "#{base}_q5_k_m",
      "#{base}_q5_0",
      "#{base}_q6_k",
      "#{base}_q8_0",
      "#{base}:q4_k_m",
      "#{base}:q4_0",
      "#{base}:q5_k_m", 
      "#{base}:q5_0",
      "#{base}:q6_k",
      "#{base}:q8_0",
      # Finally try the original model
      base_model_name,
      base
    ]
    |> Enum.uniq()
  end
end
