defmodule PreProcessing.ConditionProver do
  @tr_rules Path.join([File.cwd!(), "../resources/patterns.json"])

  def verify_condition("contains_custom_title", data, cond_id) when is_map(data) do
    title = Map.get(data, :title)

    if title && String.trim(title) != "" && title != "Neuer Eintrag" && title != "Neues Kapitel" do
      cond_id
    else
      nil
    end
  end

  def verify_condition("title_is_long", data, cond_id) when is_map(data) do
    title = Map.get(data, :title, "")

    if String.length(String.trim(title)) >= 5 do
      cond_id
    else
      nil
    end
  end

  def verify_condition("defined_Produktart", data, cond_id) when is_map(data) do
    meta_data = Map.get(data, :meta_data, %{})

    # Check if any key in meta_data contains "Produktart"
    has_produktart =
      Enum.any?(meta_data, fn {key, value} ->
        (is_binary(key) && String.contains?(String.downcase(key), "produktart")) ||
          (is_binary(value) && String.contains?(String.downcase(value), "produktart"))
      end)

    if has_produktart do
      cond_id
    else
      nil
    end
  end

  def verify_condition("defined_Produkttyp", data, cond_id) when is_map(data) do
    meta_data = Map.get(data, :meta_data, %{})

    # Check if any key in meta_data contains "Produkttyp"
    has_produkttyp =
      Enum.any?(meta_data, fn {key, value} ->
        (is_binary(key) && String.contains?(String.downcase(key), "produkttyp")) ||
          (is_binary(value) && String.contains?(String.downcase(value), "produkttyp"))
      end)

    if has_produkttyp do
      cond_id
    else
      nil
    end
  end

  def verify_condition("defined_Auftraggeber", data, cond_id) when is_map(data) do
    meta_data = Map.get(data, :meta_data, %{})

    # Check if any key in meta_data contains "Auftraggeber"
    has_auftraggeber =
      Enum.any?(meta_data, fn {key, value} ->
        (is_binary(key) && String.contains?(String.downcase(key), "auftraggeber")) ||
          (is_binary(value) && String.contains?(String.downcase(value), "auftraggeber"))
      end)

    if has_auftraggeber do
      cond_id
    else
      nil
    end
  end

  def verify_condition("defined_Auftragsdatum", data, cond_id) when is_map(data) do
    meta_data = Map.get(data, :meta_data, %{})

    # Check if any key in meta_data contains "Auftragsdatum"
    has_auftragsdatum =
      Enum.any?(meta_data, fn {key, value} ->
        (is_binary(key) && String.contains?(String.downcase(key), "auftragsdatum")) ||
          (is_binary(value) && String.contains?(String.downcase(value), "auftragsdatum"))
      end)

    if has_auftragsdatum do
      cond_id
    else
      nil
    end
  end

  def verify_condition("chapter_info_present", data, cond_id) when is_map(data) do
    chapter_info = Map.get(data, :chapter_info)

    if chapter_info && (is_binary(chapter_info) && String.trim(chapter_info) != "") do
      cond_id
    else
      nil
    end
  end

  def verify_condition("chapter_info_size_sufficient", data, cond_id) when is_map(data) do
    chapter_info = Map.get(data, :chapter_info, "")

    if is_binary(chapter_info) do
      word_count = chapter_info |> String.split() |> length()

      if word_count >= 5 do
        cond_id
      else
        nil
      end
    else
      nil
    end
  end

  def contains_word?(name, user_input, id) do
    if String.downcase(user_input) |> String.contains?(String.downcase(name)) do
      id
    end
  end

  # Helper functions

  defp count_examples(input, separators) do
    input = String.downcase(input)

    # Count regex-based separators
    regex_count =
      Enum.reduce(separators, 0, fn
        %Regex{} = pattern, acc ->
          acc + length(Regex.scan(pattern, input))

        separator, acc when is_binary(separator) ->
          acc + count_occurrences(input, separator)
      end)

    # Adjust count based on common patterns
    base_count = max(1, regex_count)

    # Increase count if there are clear multiple example indicators
    cond do
      String.contains?(input, "examples:") && regex_count > 0 -> base_count + 1
      String.contains?(input, "multiple examples") -> base_count + 1
      String.contains?(input, "following examples") -> base_count + 1
      true -> base_count
    end
  end

  defp count_occurrences(string, pattern) do
    string
    |> String.split(pattern)
    |> length()
    |> Kernel.-(1)
    |> max(0)
  end

  defp load_rules do
    with {:ok, content} <- File.read(@tr_rules),
         {:ok, json} <- Jason.decode(content) do
      {:ok, json}
    else
      error ->
        IO.puts("Error loading rules: #{inspect(error)}")
        {:error, "Failed to load rules"}
    end
  end
end
