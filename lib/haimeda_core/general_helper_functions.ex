defmodule HaimedaCore.GeneralHelperFunctions do
  # Helper function to format inspect output with proper line breaks
  def format_inspection_result(terms) when is_list(terms) do
    terms
    |> Enum.map(&inspect/1)
    |> Enum.join("\n")
  end

  def format_inspection_result(term) do
    inspect(term, pretty: true, width: 80)
  end

  @doc """
  Formats SMTLib statements to display them with proper formatting for readability.

  Instead of showing escape sequences like \\r and \\n as text,
  it converts them to actual newlines and proper indentation.

  Usage:
    - For a single statement: format_smtlib("(declare-const text String)\\n(check-sat)")
    - For a list of statements: format_smtlib(date_patterns)

  Returns:
    - A properly formatted string with actual newlines and indentation
  """
  def format_smtlib(statements) when is_list(statements) do
    statements
    |> Enum.map(&format_smtlib/1)
    |> Enum.join("\n\n")
  end

  def format_smtlib(statement) when is_binary(statement) do
    # Replace escaped line breaks with actual line breaks
    formatted =
      statement
      # Handle Windows-style line endings
      |> String.replace("\\r\\n", "\n")
      # Handle Unix-style line endings
      |> String.replace("\\n", "\n")
      # Handle old Mac-style line endings
      |> String.replace("\\r", "\n")

    # Apply proper indentation
    formatted
    |> String.split("\n")
    |> Enum.map(fn line ->
      cond do
        # Comments should be at the same level as previous line
        String.starts_with?(line, ";") -> line
        # Opening parentheses without closing on same line increase indent
        String.contains?(line, "(") && !String.contains?(line, ")") -> line
        # Add indentation to continued lines (like inside OR statements)
        String.trim_leading(line) |> String.starts_with?("(str.contains") -> "    #{line}"
        # Default formatting
        true -> line
      end
    end)
    |> Enum.join("\n")
  end

  def format_smtlib(term) do
    IO.inspect(term, label: "Non-string SMTLib statement")
    "Non-string SMTLib statement: #{inspect(term)}"
  end

  # Helper function to get performance output setting from application properties
  def get_performance_output_setting do
    Application.get_env(:haimeda_core, :show_performance_outputs, false)
  end

  def get_verbose_output_setting do
    Application.get_env(:haimeda_core, :verbose_console_output, false)
  end

  def get_disable_hybrid_postprocessing_setting do
    Application.get_env(:haimeda_core, :disable_hybrid_postprocessing, false)
  end

  def get_remote_config do
    Application.get_env(:haimeda_core, :remote_config, %{use_remote_ollama_models: false})
  end

  def get_auto_quantized_models_setting do
    Application.get_env(:haimeda_core, :auto_quantized_models, false)
  end
end
