defmodule HaimedaCoreWeb.ReportsEditor.MetadataSection do
  alias HaimedaCoreWeb.ReportsEditor.ContentPersistence
  alias HaimedaCore.Report
  require Logger

  def handle_event("add-key-value-pair", %{"id" => tab_id}, socket) do
    tab = Enum.find(socket.assigns.tabs, &(&1.id == tab_id))

    if tab && tab.category == "general" do
      pairs = ContentPersistence.parse_key_value_pairs(tab.content)
      updated_pairs = pairs ++ [%{"key" => "", "value" => ""}]
      updated_content = Jason.encode!(updated_pairs)

      updated_tabs =
        Enum.map(socket.assigns.tabs, fn t ->
          if t.id == tab_id, do: %{t | content: updated_content}, else: t
        end)

      {:tabs, updated_tabs}
    else
      {:error, "Invalid tab or category"}
    end
  end

  def handle_event("remove-key-value-pair", %{"id" => tab_id, "index" => index}, socket) do
    index = String.to_integer(index)
    tab = Enum.find(socket.assigns.tabs, &(&1.id == tab_id))

    if tab && tab.category == "general" do
      pairs = ContentPersistence.parse_key_value_pairs(tab.content)
      updated_pairs = List.delete_at(pairs, index)
      updated_content = Jason.encode!(updated_pairs)

      updated_tabs =
        Enum.map(socket.assigns.tabs, fn t ->
          if t.id == tab_id, do: %{t | content: updated_content}, else: t
        end)

      updated_tab = Enum.find(updated_tabs, &(&1.id == tab_id))
      ContentPersistence.save_general_section_to_db(socket, updated_tab)

      {:tabs, updated_tabs}
    else
      {:error, "Invalid tab or category"}
    end
  end

  def handle_event(
        "update-key-value-pair",
        %{"id" => tab_id, "index" => index, "field" => field, "value" => value},
        socket
      ) do
    index = String.to_integer(index)
    tab = Enum.find(socket.assigns.tabs, &(&1.id == tab_id))

    if tab && tab.category == "general" do
      pairs = ContentPersistence.parse_key_value_pairs(tab.content)

      updated_pairs =
        List.update_at(pairs, index, fn pair ->
          Map.put(pair, field, value)
        end)

      updated_content = Jason.encode!(updated_pairs)

      updated_tabs =
        Enum.map(socket.assigns.tabs, fn t ->
          if t.id == tab_id, do: %{t | content: updated_content}, else: t
        end)

      updated_tab = Enum.find(updated_tabs, &(&1.id == tab_id))
      ContentPersistence.save_general_section_to_db(socket, updated_tab)

      {:tabs, updated_tabs}
    else
      {:error, "Invalid tab or category"}
    end
  end

  def handle_event(
        "toggle-meta-info-button",
        %{"id" => tab_id, "section" => section, "key" => key},
        socket
      ) do
    Logger.info("Toggling metadata button for tab #{tab_id}, section #{section}, key #{key}")

    tabs = socket.assigns.tabs
    tab = Enum.find(tabs, &(&1.id == tab_id))

    if tab do
      active_meta_info = Map.get(tab, :active_meta_info, %{})
      section_map = Map.get(active_meta_info, section, %{})
      meta_value = get_metadata_value(socket.assigns.report_id, section, key)

      updated_section_map =
        if Map.has_key?(section_map, key) do
          Map.delete(section_map, key)
        else
          Map.put(section_map, key, meta_value)
        end

      updated_meta_info = Map.put(active_meta_info, section, updated_section_map)
      updated_tab = Map.put(tab, :active_meta_info, updated_meta_info)

      updated_tabs =
        Enum.map(tabs, fn t ->
          if t.id == tab_id, do: updated_tab, else: t
        end)

      ContentPersistence.save_tab_meta_info_to_db(socket, updated_tab)

      {:tabs, updated_tabs}
    else
      Logger.error("Tab not found for ID #{tab_id}")
      {:error, "Tab not found"}
    end
  end

  def get_metadata_value(report_id, section, key) do
    case section do
      "basic_info" ->
        basic_info = get_basic_info(report_id)
        Map.get(basic_info, key)

      "device_info" ->
        device_info = get_device_info(report_id)
        Map.get(device_info, key)

      "parties" ->
        case String.split(key, ":") do
          [party_title, "person", statement_id] ->
            get_party_statement(report_id, party_title, "person", statement_id)

          [party_title, "analysis", related_to, statement_id] ->
            get_party_statement(report_id, party_title, "analysis", statement_id, related_to)

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  def get_basic_info(report_id) do
    case Report.get_report(report_id) do
      {:ok, report} ->
        general_data = Map.get(report, "general", %{})
        basic_info = Map.get(general_data, "basic_info", [])

        basic_info
        |> Enum.reduce(%{}, fn item, acc ->
          case item do
            %{"key" => key, "value" => value} when key != "" ->
              Map.put(acc, key, value)

            _ ->
              acc
          end
        end)

      _ ->
        %{}
    end
  end

  def get_device_info(report_id) do
    case Report.get_report(report_id) do
      {:ok, report} ->
        general_data = Map.get(report, "general", %{})
        device_info = Map.get(general_data, "device_info", [])

        device_info
        |> Enum.reduce(%{}, fn item, acc ->
          case item do
            %{"key" => key, "value" => value} when key != "" ->
              Map.put(acc, key, value)

            _ ->
              acc
          end
        end)

      _ ->
        %{}
    end
  end

  def get_party_statement(
        report_id,
        party_title,
        statement_type,
        statement_id,
        related_to \\ nil
      ) do
    case Report.get_report(report_id) do
      {:ok, report} ->
        parties = Map.get(report, "parties", [])

        party =
          Enum.find(parties, fn p ->
            Map.get(p, "title", "") == party_title
          end)

        if party do
          case statement_type do
            "person" ->
              statements = Map.get(party, "person_statements", [])

              statement =
                Enum.find(statements, fn s ->
                  to_string(Map.get(s, "id", "")) == statement_id
                end)

              if statement, do: Map.get(statement, "content", ""), else: nil

            "analysis" ->
              statements = Map.get(party, "analysis_statements", [])

              statement =
                Enum.find(statements, fn s ->
                  to_string(Map.get(s, "id", "")) == statement_id &&
                    (related_to == nil || to_string(Map.get(s, "related_to", "")) == related_to)
                end)

              if statement, do: Map.get(statement, "content", ""), else: nil
          end
        else
          nil
        end

      _ ->
        nil
    end
  end

  def generate_nav_sections_from_report(report) do
    base_sections = [
      %{
        id: "general",
        icon: "hero-document-text",
        title: "Allgemein",
        items: [
          %{label: "Grundlegende Informationen", id: "basic_info"},
          %{label: "Gerätedaten", id: "device_info"}
        ]
      },
      %{
        id: "parties",
        icon: "hero-clipboard-document-check",
        title: "Angaben der beteiligten Personen",
        items: []
      },
      %{
        id: "chapters",
        icon: "hero-document",
        title: "Kapitel",
        items: []
      }
    ]

    parties_items =
      (report["parties"] || [])
      |> Enum.map(fn party ->
        %{label: party["title"] || "Unbenannt", id: party["id"]}
      end)

    chapters_items =
      (report["chapters"] || [])
      |> Enum.map(fn chapter ->
        %{
          label: chapter["title"] || "Unbenannt",
          id: chapter["id"],
          chapter_number: chapter["chapter_number"] || ""
        }
      end)
      |> sort_items_by_chapter_number()

    base_sections
    |> Enum.map(fn section ->
      case section.id do
        "parties" -> %{section | items: parties_items}
        "chapters" -> %{section | items: chapters_items}
        _ -> section
      end
    end)
  end

  def sort_items_by_chapter_number(items) do
    Enum.sort_by(items, fn item ->
      chapter_num = Map.get(item, :chapter_number, "")

      chapter_num
      |> String.trim()
      |> String.split(".")
      |> Enum.filter(&(&1 != ""))
      |> Enum.map(fn segment ->
        case Integer.parse(segment) do
          {num, _} -> num
          :error -> 0
        end
      end)
      |> pad_with_zeros()
    end)
  end

  defp pad_with_zeros(nums) do
    nums ++ List.duplicate(0, 10 - length(nums))
  end
end
