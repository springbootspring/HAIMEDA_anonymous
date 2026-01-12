defmodule RAM.PromptBuilder do
  @moduledoc """
  This module handles the creation of prompts for LLMs, requested by other specialized modules.
  """

  alias RAM.PromptBuilderHelpers, as: PBH

  def create_prompt(prompt_key, input_info, type \\ nil) do
    case prompt_key do
      "chapter_creation" ->
        create_chapter_prompt(prompt_key, input_info, type)

      "text_optimization" ->
        create_text_optimization_prompt(prompt_key, input_info)

      "text_revision" ->
        create_text_revision_prompt(prompt_key, input_info)

      "text_summarization" ->
        create_text_summarization_prompt(prompt_key, input_info)

      "user_request" ->
        create_user_request_prompt(prompt_key, input_info, type)

      _ ->
        {:error, "Unknown prompt key"}
    end
  end

  def create_user_request_prompt(prompt_key, input_info, type) do
    case type do
      :no_context ->
        create_user_question_prompt_no_context(prompt_key, input_info)

      :with_context ->
        create_user_question_prompt_with_context(prompt_key, input_info)

      _ ->
        {:error, "Unknown prompt type"}
    end
  end

  def create_user_question_prompt_with_context(prompt_key, input_info) do
    base_template = PBH.extract_prompt_element(prompt_key, "base")

    task2_template = PBH.extract_prompt_element(prompt_key, "task_2")
    context_template = PBH.extract_prompt_element(prompt_key, "context")

    questions = PBH.format_questions(input_info.user_request)

    {task_template, context_string} =
      case input_info.result_type do
        :vector_results ->
          context_snippet_template =
            PBH.extract_prompt_element(prompt_key, "context_snippet_report")

          task_template = PBH.extract_prompt_element(prompt_key, "task_report")

          context_snippets =
            PBH.format_context_reports(
              context_snippet_template,
              input_info.vector_results
            )

          {
            task_template,
            context_snippets
          }

        :mdb_results ->
          context_snippet_template =
            PBH.extract_prompt_element(prompt_key, "context_snippet_mdb")

          task_template = PBH.extract_prompt_element(prompt_key, "task_mdb")

          context_snippets =
            PBH.format_context_mdb(context_snippet_template, input_info.mdb_results)

          {
            task_template,
            context_snippets
          }

        :combined_results ->
          context_snippet_template_mdb =
            PBH.extract_prompt_element(prompt_key, "context_snippet_mdb")

          context_snippet_template_report =
            PBH.extract_prompt_element(prompt_key, "context_snippet_report")

          task_template = PBH.extract_prompt_element(prompt_key, "task_combined")

          context_snippets =
            PBH.format_context_combined(
              context_snippet_template_report,
              context_snippet_template_mdb,
              input_info.vector_results,
              input_info.mdb_results
            )

          {
            task_template,
            context_snippets
          }

        _ ->
          ""
      end

    context_string =
      EEx.eval_string(context_template,
        assigns: %{
          context_snippets: context_string,
          task_2: task2_template,
          questions: questions
        }
      )

    # Build the final prompt
    input_string =
      EEx.eval_string(base_template,
        assigns: %{
          task: task_template,
          questions: questions,
          context: context_string
        }
      )
      |> PBH.normalize_prompt_newlines()

    input_string
  end

  def create_user_question_prompt_no_context(prompt_key, input_info) do
    base_template = PBH.extract_prompt_element(prompt_key, "base")
    task_template = PBH.extract_prompt_element(prompt_key, "task_no_context")
    questions = PBH.format_questions(input_info.user_request)

    # Build the final prompt
    input_string =
      EEx.eval_string(base_template,
        assigns: %{
          task: task_template,
          questions: questions,
          context: ""
        }
      )
      |> PBH.normalize_prompt_newlines()

    input_string
  end

  def create_text_optimization_prompt(prompt_key, content) do
    base_template = PBH.extract_prompt_element(prompt_key, "base")
    task_template = PBH.extract_prompt_element(prompt_key, "task")
    example_template = PBH.extract_prompt_element(prompt_key, "example")
    task_2_template = PBH.extract_prompt_element(prompt_key, "task_2")

    normalized_content =
      if is_binary(content) do
        content
        |> PBH.normalize_newlines()
        |> String.trim()
      else
        ""
      end

    # Build the final prompt
    input_string =
      EEx.eval_string(base_template,
        assigns: %{
          task: task_template,
          examples_section: example_template,
          task_2: task_2_template,
          text: normalized_content
        }
      )
      |> PBH.normalize_prompt_newlines()

    input_string
  end

  def create_text_revision_prompt(prompt_key, input_info) do
    missing_entities = input_info.missing_entities
    textarea_content = input_info.textarea_content

    base_template = PBH.extract_prompt_element(prompt_key, "base")
    task_template = PBH.extract_prompt_element(prompt_key, "task")
    example_template = PBH.extract_prompt_element(prompt_key, "example")
    task_2_template = PBH.extract_prompt_element(prompt_key, "task_2")

    normalized_content =
      if is_binary(textarea_content) do
        textarea_content
        |> PBH.normalize_newlines()
        |> String.trim()
      else
        ""
      end

    formatted_missing_entities =
      if is_list(missing_entities) do
        missing_entities
        |> Enum.map(fn entity ->
          text = Map.get(entity, :text, "")
          category = Map.get(entity, :category, "")

          category_german =
            case category do
              "date" -> "Datum"
              "identifier" -> "Identifikator"
              "number" -> "Zahl"
              "phrase" -> "Phrase"
              "statement" -> "Aussage"
              _ -> category
            end

          # "#{text} (#{category_german})"
          "#{text})"
        end)
        |> Enum.join("\n")
      else
        ""
      end

    # Build the final prompt
    input_string =
      EEx.eval_string(base_template,
        assigns: %{
          task: task_template,
          examples_section: example_template,
          task_2: task_2_template,
          text: normalized_content,
          missing_entities: formatted_missing_entities
        }
      )
      |> PBH.normalize_prompt_newlines()

    input_string
  end

  def create_text_summarization_prompt(prompt_key, content) do
    base_template = PBH.extract_prompt_element(prompt_key, "base")
    task_template = PBH.extract_prompt_element(prompt_key, "task")
    example_template = PBH.extract_prompt_element(prompt_key, "example")
    task_2_template = PBH.extract_prompt_element(prompt_key, "task_2")

    normalized_content =
      if is_binary(content) do
        content
        |> PBH.normalize_newlines()
        |> String.trim()
      else
        ""
      end

    # Build the final prompt
    input_string =
      EEx.eval_string(base_template,
        assigns: %{
          task: task_template,
          examples_section: example_template,
          task_2: task_2_template,
          text: normalized_content
        }
      )
      |> PBH.normalize_prompt_newlines()

    input_string
  end

  def create_chapter_prompt(prompt_key, input_info, previous_contents_type) do
    case previous_contents_type do
      :summaries ->
        create_chapter_prompt_with_summaries(prompt_key, input_info)

      :full_chapters ->
        create_chapter_prompt_with_full_chapters(prompt_key, input_info)

      nil ->
        create_chapter_prompt_without_previous_content(prompt_key, input_info)

      _ ->
        {:error, "Unknown chapter type"}
    end
  end

  def create_chapter_prompt_with_summaries(prompt_key, input_info) do
    raw_chapter_num = input_info.chapter_num
    chapter_num = PBH.format_chapter_num(raw_chapter_num)
    chapter_name = input_info.title
    chapter_info = input_info.chapter_info || ""

    {meta_data, parties_statements} =
      PBH.extract_single_meta_data(input_info.meta_data)

    summary =
      if parties_statements != %{} do
        party_statements_string =
          parties_statements
          |> Enum.sort_by(fn {key, _} -> key end, :asc)
          |> Enum.map(fn {_key, value} -> value end)
          |> Enum.join("\n")

        chapter_info <> "\n" <> party_statements_string
      else
        chapter_info
      end

    task_template = PBH.extract_prompt_element(prompt_key, "task")
    base_template = PBH.extract_prompt_element(prompt_key, "base")
    summary_template = PBH.extract_prompt_element(prompt_key, "summary")
    meta_data_template = PBH.extract_prompt_element(prompt_key, "meta_data")

    task_description =
      EEx.eval_string(task_template,
        assigns: %{
          chapter_num: chapter_num,
          chapter_name: chapter_name
        }
      )

    current_chapter_summary =
      if summary && summary != "" && !PBH.contains_restricted_tags?(summary) do
        normalized_summary =
          summary
          |> PBH.remove_footnote_tags()
          |> PBH.remove_image_lines()
          |> PBH.remove_special_tags()
          |> PBH.remove_chapter_header(chapter_num, chapter_name)
          |> PBH.normalize_newlines()

        EEx.eval_string(summary_template,
          assigns: %{
            previous_summary_content: normalized_summary,
            previous_summary_following: ""
          }
        )
      else
        ""
      end

    meta_data_string = PBH.format_meta_data(meta_data_template, meta_data)

    previous_content =
      PBH.format_previous_content(
        input_info.previous_content,
        :only_summaries,
        prompt_key
      )

    input_string =
      EEx.eval_string(base_template,
        assigns: %{
          task: task_description,
          current_chapter_summary: current_chapter_summary,
          meta_data: meta_data_string,
          chapter_num: chapter_num,
          chapter_name: chapter_name,
          previous_content: previous_content
        }
      )
      |> PBH.normalize_prompt_newlines()
  end

  def create_chapter_prompt_with_full_chapters(prompt_key, input_info) do
    raw_chapter_num = input_info.chapter_num
    chapter_num = PBH.format_chapter_num(raw_chapter_num)
    chapter_name = input_info.title

    chapter_info = input_info.chapter_info || ""

    {meta_data, parties_statements} =
      PBH.extract_single_meta_data(input_info.meta_data)

    summary =
      if parties_statements != %{} do
        party_statements_string =
          parties_statements
          |> Enum.sort_by(fn {key, _} -> key end, :asc)
          |> Enum.map(fn {_key, value} -> value end)
          |> Enum.join("\n")

        chapter_info <> "\n" <> party_statements_string
      else
        chapter_info
      end

    task_template = PBH.extract_prompt_element(prompt_key, "task")
    base_template = PBH.extract_prompt_element(prompt_key, "base")
    summary_template = PBH.extract_prompt_element(prompt_key, "summary")
    meta_data_template = PBH.extract_prompt_element(prompt_key, "meta_data")

    task_description =
      EEx.eval_string(task_template,
        assigns: %{
          chapter_num: chapter_num,
          chapter_name: chapter_name
        }
      )

    current_chapter_summary =
      if summary && summary != "" && !PBH.contains_restricted_tags?(summary) do
        normalized_summary =
          summary
          |> PBH.remove_footnote_tags()
          |> PBH.remove_image_lines()
          |> PBH.remove_special_tags()
          |> PBH.remove_chapter_header(chapter_num, chapter_name)
          |> PBH.normalize_newlines()

        EEx.eval_string(summary_template,
          assigns: %{
            previous_summary_content: normalized_summary,
            previous_summary_following: ""
          }
        )
      else
        ""
      end

    meta_data_string = PBH.format_meta_data(meta_data_template, meta_data)

    previous_content =
      PBH.format_previous_content(input_info.previous_content, :only_chapters, prompt_key)

    input_string =
      EEx.eval_string(base_template,
        assigns: %{
          task: task_description,
          current_chapter_summary: current_chapter_summary,
          meta_data: meta_data_string,
          chapter_num: chapter_num,
          chapter_name: chapter_name,
          previous_content: previous_content
        }
      )
      |> PBH.normalize_prompt_newlines()
  end

  def create_chapter_prompt_without_previous_content(prompt_key, input_info) do
    raw_chapter_num = input_info.chapter_num
    chapter_num = PBH.format_chapter_num(raw_chapter_num)
    chapter_name = input_info.title

    chapter_info = input_info.chapter_info

    {meta_data, parties_statements} =
      PBH.extract_single_meta_data(input_info.meta_data)

    summary =
      if parties_statements != %{} do
        party_statements_string =
          parties_statements
          |> Enum.sort_by(fn {key, _} -> key end, :asc)
          |> Enum.map(fn {_key, value} -> value end)
          |> Enum.join("\n")

        chapter_info <> "\n" <> party_statements_string
      else
        chapter_info
      end

    task_template = PBH.extract_prompt_element(prompt_key, "task")
    base_template = PBH.extract_prompt_element(prompt_key, "base_no_previous_content")
    summary_template = PBH.extract_prompt_element(prompt_key, "summary")
    meta_data_template = PBH.extract_prompt_element(prompt_key, "meta_data")

    task_description =
      EEx.eval_string(task_template,
        assigns: %{
          chapter_num: chapter_num,
          chapter_name: chapter_name
        }
      )

    current_chapter_summary =
      if summary && summary != "" && !PBH.contains_restricted_tags?(summary) do
        normalized_summary =
          summary
          |> PBH.remove_footnote_tags()
          |> PBH.remove_image_lines()
          |> PBH.remove_special_tags()
          |> PBH.remove_chapter_header(chapter_num, chapter_name)
          |> PBH.normalize_newlines()

        EEx.eval_string(summary_template,
          assigns: %{
            previous_summary_content: normalized_summary,
            previous_summary_following: ""
          }
        )
      else
        ""
      end

    meta_data_string = PBH.format_meta_data(meta_data_template, meta_data)

    input_string =
      EEx.eval_string(base_template,
        assigns: %{
          task: task_description,
          current_chapter_summary: current_chapter_summary,
          meta_data: meta_data_string,
          chapter_num: chapter_num,
          chapter_name: chapter_name
        }
      )
      |> PBH.normalize_prompt_newlines()

    input_string
  end
end
