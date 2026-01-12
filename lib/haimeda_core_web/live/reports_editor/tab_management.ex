defmodule HaimedaCoreWeb.ReportsEditor.TabManagement do
  alias HaimedaCoreWeb.ReportsEditor.{ContentPersistence, PreviousContent}
  alias HaimedaCore.Report
  require Logger

  @impl true
  def handle_event("save-content", %{"id" => tab_id, "value" => value}, socket) do
    Logger.info("Processing save-content event for tab #{tab_id}")

    tabs =
      Enum.map(socket.assigns.tabs, fn tab ->
        if tab.id == tab_id do
          Map.put(tab, :content, value)
        else
          tab
        end
      end)

    updated_tab = Enum.find(tabs, &(&1.id == tab_id))

    if updated_tab do
      ContentPersistence.save_tab_content_to_db(socket, updated_tab)
      {:tabs, tabs}
    else
      {:error, "Tab not found"}
    end
  end

  @impl true
  def handle_event("select-tab", %{"id" => tab_id}, socket) do
    updates = handle_select_tab(socket, tab_id)

    if Map.has_key?(updates, :tabs) && Map.has_key?(updates, :active_tab) do
      updates
    else
      tab = Enum.find(socket.assigns.tabs, &(&1.id == tab_id))

      if tab && tab.id != "new_tab" &&
           ((tab.category == "chapters" && (tab.content == "" || tab.chapter_info == "")) ||
              (tab.category == "parties" &&
                 (tab.person_statements == "[]" || tab.analysis_statements == "[]" ||
                    !Map.has_key?(tab, :person_statements) ||
                    !Map.has_key?(tab, :analysis_statements))) ||
              (tab.category == "general" && tab.content == "")) do
        fake_socket = %{assigns: Map.put(socket.assigns, :active_tab, tab_id)}

        loaded_tab =
          ContentPersistence.load_content_from_db(
            fake_socket,
            tab,
            tab.section_id,
            tab.category
          )

        updated_tabs =
          Enum.map(socket.assigns.tabs, fn t ->
            if t.id == tab_id, do: loaded_tab, else: t
          end)

        %{tabs: updated_tabs, active_tab: tab_id}
      else
        updates
      end
    end
  end

  @impl true
  def handle_event("close-tab", %{"id" => tab_id}, socket) do
    handle_close_tab(socket, tab_id)
  end

  @impl true
  def handle_event("select-section-item", %{"id" => item_id, "category" => category}, socket) do
    handle_select_section_item(socket, item_id, category)
  end

  @impl true
  def handle_event("add-tab", _params, socket) do
    add_tab_to_category(socket, "chapters")
  end

  @impl true
  def handle_event("add-section-item", %{"category" => category}, socket) do
    add_tab_to_category(socket, category)
  end

  @doc """
  Creates a new tab for a specific navigation item in a category.
  Returns a map with updated socket assigns.
  """
  def create_tab_for_item(socket, item_id, category) do
    section = Enum.find(socket.assigns.nav_sections, &(&1.id == category))

    item =
      if section do
        Enum.find(section.items, &(&1.id == item_id))
      else
        nil
      end

    label = if item, do: item.label, else: "Neuer Bereich"

    chapter_number =
      if category == "chapters" && item, do: Map.get(item, :chapter_number, ""), else: nil

    tab_id = "tab_#{:erlang.system_time(:millisecond)}"

    default_content =
      if category == "general" do
        Jason.encode!([])
      else
        ""
      end

    # Create a new tab with default values for all fields needed by any category
    new_tab = %{
      id: tab_id,
      label: label,
      content: default_content,
      category: category,
      section_id: item_id,
      # Always include active_meta_info
      active_meta_info: %{},
      # Always include read_only
      read_only: false
    }

    # Add category-specific fields
    new_tab =
      case category do
        "chapters" ->
          new_tab
          |> Map.put(:chapter_info, "")
          |> Map.put(:chapter_number, chapter_number)

        "parties" ->
          new_tab
          |> Map.put(:person_statements, "[]")
          |> Map.put(:analysis_statements, "[]")

        _ ->
          new_tab
      end

    # Load content from database, which will also handle backward compatibility
    new_tab = ContentPersistence.load_content_from_db(socket, new_tab, item_id, category)

    updated_tabs =
      socket.assigns.tabs
      |> Enum.filter(fn tab -> tab.id != "new_tab" end)
      |> Enum.concat([
        new_tab,
        %{id: "new_tab", label: "+", content: "", category: nil, section_id: nil}
      ])

    %{
      tabs: updated_tabs,
      active_tab: tab_id
    }
  end

  @doc """
  Adds a new tab to a specific category.
  Returns a map with updated socket assigns.
  """
  def add_tab_to_category(socket, category) do
    timestamp = :erlang.system_time(:millisecond)
    section_id = "section_#{timestamp}"
    tab_id = "tab_#{timestamp}"

    section = Enum.find(socket.assigns.nav_sections, &(&1.id == category))
    category_name = if section, do: section.title, else: "Kapitel"

    new_tab_title = "Neuer Eintrag"

    next_chapter_number =
      if category == "chapters" do
        get_next_chapter_number(socket.assigns.nav_sections)
      else
        nil
      end

    nav_sections =
      if category == "chapters" do
        add_item_to_section(socket.assigns.nav_sections, category, %{
          id: section_id,
          label: new_tab_title,
          chapter_number: next_chapter_number
        })
      else
        add_item_to_section(socket.assigns.nav_sections, category, %{
          id: section_id,
          label: new_tab_title
        })
      end

    # Create a new tab with all required fields
    new_tab = %{
      id: tab_id,
      label: new_tab_title,
      content: "",
      category: category,
      section_id: section_id,
      # Always include active_meta_info
      active_meta_info: %{},
      # Always include read_only flag
      read_only: false
    }

    new_tab =
      case category do
        "chapters" ->
          # Initialize with proper version structure
          initial_formatted_content = ContentPersistence.create_default_formatted_content("")

          # Make sure we're initializing with a valid version 1
          chapter_versions = [
            %{
              "version" => 1,
              # Starting with empty content
              "plain_content" => "",
              "formatted_content" => initial_formatted_content,
              "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
            }
          ]

          new_tab
          |> Map.put(:chapter_info, "")
          |> Map.put(:chapter_number, next_chapter_number)
          |> Map.put(:chapter_versions, chapter_versions)
          |> Map.put(:current_version, 1)
          |> Map.put(:formatted_content, initial_formatted_content)

        "parties" ->
          new_tab
          |> Map.put(:person_statements, "[]")
          |> Map.put(:analysis_statements, "[]")

        _ ->
          new_tab
      end

    updated_tabs =
      socket.assigns.tabs
      |> Enum.filter(fn tab -> tab.id != "new_tab" end)
      |> Enum.concat([
        new_tab,
        %{id: "new_tab", label: "+", content: "", category: nil, section_id: nil}
      ])

    section_data =
      case category do
        "chapters" ->
          # Include chapter_versions in the section data
          initial_formatted_content = ContentPersistence.create_default_formatted_content("")

          # Ensure we have a valid version 1 in the database too
          chapter_versions = [
            %{
              "version" => 1,
              # Starting with empty content
              "plain_content" => "",
              "summary" => "",
              "type" => "only_heading",
              "formatted_content" => initial_formatted_content,
              "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
            }
          ]

          %{
            id: section_id,
            title: new_tab_title,
            chapter_info: "",
            chapter_number: next_chapter_number,
            chapter_versions: chapter_versions,
            current_version: 1
          }

        "parties" ->
          %{
            id: section_id,
            title: new_tab_title,
            person_statements: [],
            analysis_statements: []
          }

        _ ->
          %{}
      end

    if category != "general" do
      Report.update_report_section(socket.assigns.report_id, category, section_id, section_data)
    end

    %{
      tabs: updated_tabs,
      active_tab: tab_id,
      nav_sections: nav_sections
    }
  end

  @doc """
  Handles event to select an existing tab or create a new one if it doesn't exist.
  Returns a map with updated socket assigns.
  """
  def handle_select_tab(socket, tab_id) do
    if tab_id == "new_tab" do
      %{active_tab: tab_id}
    else
      tab = Enum.find(socket.assigns.tabs, &(&1.id == tab_id))

      if tab do
        # Make sure we have all required fields regardless of which tab we select
        tab = ensure_tab_has_required_fields(tab)

        # Check if content needs to be loaded - important for restored sessions
        content_needs_loading =
          (tab.category == "chapters" && (tab.content == "" || tab.chapter_info == "")) ||
            (tab.category == "parties" &&
               (tab.person_statements == "[]" || tab.analysis_statements == "[]")) ||
            (tab.category == "general" && tab.content == "")

        # Load content if needed
        updated_tab =
          if content_needs_loading do
            ContentPersistence.load_content_from_db(socket, tab, tab.section_id, tab.category)
          else
            tab
          end

        # Update tabs if content was loaded
        tabs =
          if updated_tab != tab do
            Enum.map(socket.assigns.tabs, fn t ->
              if t.id == tab_id, do: updated_tab, else: t
            end)
          else
            socket.assigns.tabs
          end

        %{
          active_tab: tab_id,
          tabs: tabs
        }
      else
        Logger.error("Tab not found: #{tab_id}")
        %{}
      end
    end
  end

  @doc """
  Handles event to close a tab.
  Returns a map with updated socket assigns.
  """
  def handle_close_tab(socket, tab_id) do
    if tab_id == "new_tab" do
      %{}
    else
      updated_tabs = Enum.reject(socket.assigns.tabs, &(&1.id == tab_id))

      new_active_tab =
        cond do
          socket.assigns.active_tab == tab_id ->
            case List.first(updated_tabs) do
              nil -> "new_tab"
              first_tab -> first_tab.id
            end

          true ->
            socket.assigns.active_tab
        end

      %{
        tabs: updated_tabs,
        active_tab: new_active_tab
      }
    end
  end

  @doc """
  Handles event to update a tab's title.
  Returns a map with updated socket assigns.
  """
  def handle_update_tab_title(socket, tab_id, value) do
    Logger.info("Processing update-tab-title event for tab #{tab_id}")

    # Find the tab to update
    tab = Enum.find(socket.assigns.tabs, &(&1.id == tab_id))

    if tab do
      # Update the tab title
      updated_tab = Map.put(tab, :label, value)

      # Only update type for chapter tabs
      updated_tab =
        if tab.category == "chapters" do
          # Determine new chapter type based on the updated title
          chapter_type = ContentPersistence.determine_chapter_type(value)

          # Store the updated type in the tab
          Map.put(updated_tab, :chapter_type, chapter_type)
        else
          updated_tab
        end

      # Update the tabs list
      tabs =
        Enum.map(socket.assigns.tabs, fn t ->
          if t.id == tab_id, do: updated_tab, else: t
        end)

      # Update navigation sections to reflect the title change
      nav_sections = update_nav_item_label(socket.assigns.nav_sections, updated_tab)

      # Save the updated tab content to the database
      ContentPersistence.save_tab_content_to_db(socket, updated_tab)

      %{
        tabs: tabs,
        nav_sections: nav_sections
      }
    else
      %{}
    end
  end

  @doc """
  Handles updating a chapter number.
  Returns a map with updated socket assigns.
  """
  def handle_update_chapter_number(socket, tab_id, value) do
    Logger.info("Processing update-chapter-number event for tab #{tab_id}")

    # Find the tab to update
    tab = Enum.find(socket.assigns.tabs, &(&1.id == tab_id))

    if tab && tab.category == "chapters" do
      # Format the chapter number
      formatted_number = PreviousContent.format_chapter_number_string(value)

      # Update the tab with the formatted chapter number
      updated_tab = Map.put(tab, :chapter_number, formatted_number)

      # Update the tabs list
      tabs =
        Enum.map(socket.assigns.tabs, fn t ->
          if t.id == tab_id, do: updated_tab, else: t
        end)

      # Update navigation sections to reflect the chapter number change
      nav_sections =
        Enum.map(socket.assigns.nav_sections, fn section ->
          if section.id == "chapters" do
            updated_items =
              Enum.map(section.items, fn item ->
                if item.id == tab.section_id do
                  Map.put(item, :chapter_number, formatted_number)
                else
                  item
                end
              end)

            # Sort items by chapter number
            sorted_items =
              Enum.sort_by(
                updated_items,
                fn item -> Map.get(item, :chapter_number, "") end,
                fn a, b -> PreviousContent.chapter_number_less_than?(a, b) end
              )

            %{section | items: sorted_items}
          else
            section
          end
        end)

      # Save the updated tab content to the database
      ContentPersistence.save_tab_content_to_db(socket, updated_tab)

      %{
        tabs: tabs,
        nav_sections: nav_sections
      }
    else
      %{}
    end
  end

  @doc """
  Handles event to select a section item, creating a tab if needed.
  Returns a map with updated socket assigns.
  """
  def handle_select_section_item(socket, item_id, category) do
    Logger.info("Selecting section item: #{category}/#{item_id}")

    # Find if there's already a tab open for this section item
    existing_tab =
      Enum.find(socket.assigns.tabs, fn tab ->
        tab.section_id == item_id && tab.category == category
      end)

    if existing_tab do
      # If the tab exists, select it and ensure content is loaded
      updated_tab =
        ContentPersistence.load_content_from_db(socket, existing_tab, item_id, category)

      # Update the tab in the tabs list
      updated_tabs =
        Enum.map(socket.assigns.tabs, fn tab ->
          if tab.id == existing_tab.id, do: updated_tab, else: tab
        end)

      %{tabs: updated_tabs, active_tab: existing_tab.id}
    else
      # Otherwise, create and select a new tab
      new_tab = create_tab_for_section_item(socket, item_id, category)

      new_tab = Map.put_new(new_tab, :active_meta_info, %{})

      loaded_tab = ContentPersistence.load_content_from_db(socket, new_tab, item_id, category)

      # Keep the new_tab entry at the end
      updated_tabs =
        socket.assigns.tabs
        |> Enum.filter(fn tab -> tab.id != "new_tab" end)
        |> Enum.concat([
          loaded_tab,
          %{id: "new_tab", label: "+", content: "", category: nil, section_id: nil}
        ])

      %{tabs: updated_tabs, active_tab: loaded_tab.id}
    end
  end

  defp get_next_chapter_number(nav_sections) do
    chapters_section = Enum.find(nav_sections, &(&1.id == "chapters"))

    if chapters_section do
      chapter_numbers =
        chapters_section.items
        |> Enum.map(fn item ->
          chapter_num = Map.get(item, :chapter_number, "")

          case String.split(chapter_num, ".", parts: 2) do
            [num | _] ->
              case Integer.parse(num) do
                {int_num, _} -> int_num
                :error -> 0
              end

            _ ->
              0
          end
        end)
        |> Enum.filter(&(&1 > 0))

      next_num =
        if Enum.empty?(chapter_numbers) do
          1
        else
          Enum.max(chapter_numbers) + 1
        end

      "#{next_num}."
    else
      "1."
    end
  end

  defp add_item_to_section(sections, category_id, item) do
    Enum.map(sections, fn section ->
      if section.id == category_id do
        %{section | items: section.items ++ [item]}
      else
        section
      end
    end)
  end

  defp update_nav_item_label(sections, tab) do
    case tab do
      %{section_id: section_id, label: label, category: category}
      when not is_nil(section_id) and not is_nil(category) ->
        Enum.map(sections, fn section ->
          if section.id == category do
            updated_items =
              Enum.map(section.items, fn item ->
                if item.id == section_id do
                  %{item | label: label}
                else
                  item
                end
              end)

            %{section | items: updated_items}
          else
            section
          end
        end)

      _ ->
        sections
    end
  end

  # Helper function to ensure a tab has all required fields
  defp ensure_tab_has_required_fields(tab) do
    tab
    |> Map.put_new(:active_meta_info, %{})
    |> Map.put_new(:formatted_content, %{})
    # Default to writable mode
    |> Map.put_new(:read_only, false)
    |> case do
      %{category: "chapters"} = t ->
        t
        |> Map.put_new(:chapter_number, "")
        |> Map.put_new(:chapter_info, "")

      %{category: "parties"} = t ->
        t
        |> Map.put_new(:person_statements, "[]")
        |> Map.put_new(:analysis_statements, "[]")

      t ->
        t
    end
  end

  defp create_tab_for_section_item(socket, item_id, category) do
    Logger.info("Creating tab for section item: #{category}/#{item_id}")

    report = socket.assigns.report

    tab_id = "tab_#{System.os_time(:millisecond)}"

    case category do
      "general" ->
        # Handle general sections (e.g., basic info, device info)
        section = Enum.find(socket.assigns.nav_sections, &(&1.id == "general"))
        item = Enum.find(section.items, &(&1.id == item_id))

        content = get_general_section_content(report, item_id)

        %{
          id: tab_id,
          label: item.label,
          category: category,
          section_id: item_id,
          content: content,
          read_only: false,
          active_meta_info: %{},
          formatted_content: %{
            "version" => 1,
            "plain_content" => content,
            "formatted_content" => ContentPersistence.create_default_formatted_content(content),
            "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        }

      "parties" ->
        # Handle party sections
        party = Enum.find(report["parties"] || [], &(&1["id"] == item_id))

        %{
          id: tab_id,
          label: party["title"] || "Unbenannt",
          category: category,
          section_id: item_id,
          person_statements: Jason.encode!(party["person_statements"] || []),
          analysis_statements: Jason.encode!(party["analysis_statements"] || []),
          read_only: false,
          active_meta_info: %{},
          formatted_content: %{
            "version" => 1,
            "plain_content" => "",
            "formatted_content" => ContentPersistence.create_default_formatted_content(""),
            "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        }

      "chapters" ->
        # Handle chapter sections
        chapters_section = Enum.find(socket.assigns.nav_sections, &(&1.id == "chapters"))
        chapter_item = Enum.find(chapters_section.items, &(&1.id == item_id))

        chapter = Enum.find(report["chapters"] || [], &(&1["id"] == item_id))

        %{
          id: tab_id,
          label: chapter["title"] || chapter_item.label || "Unbenannt",
          category: category,
          section_id: item_id,
          # Use chapter_text instead of content
          content: chapter["chapter_text"] || "",
          chapter_info: chapter["chapter_info"] || "",
          chapter_number: chapter["chapter_number"] || "",
          active_meta_info: chapter["active_meta_info"] || %{},
          read_only: false,
          formatted_content:
            chapter["formatted_content"] ||
              %{
                "version" => 1,
                "plain_content" => chapter["chapter_text"] || "",
                "formatted_content" =>
                  ContentPersistence.create_default_formatted_content(
                    chapter["chapter_text"] || ""
                  ),
                "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
              }
        }

      _ ->
        Logger.error("Unknown category: #{category}")

        %{
          id: tab_id,
          label: "Error",
          category: category,
          section_id: item_id,
          content: "",
          read_only: false,
          active_meta_info: %{},
          formatted_content: %{
            "version" => 1,
            "plain_content" => "",
            "formatted_content" => ContentPersistence.create_default_formatted_content(""),
            "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        }
    end
  end

  # Helper function to get general section content from a report
  defp get_general_section_content(report, section_id) do
    case section_id do
      "basic_info" ->
        # Get the basic info section data
        basic_info = get_in(report, ["general", "basic_info"]) || []
        Jason.encode!(basic_info)

      "device_info" ->
        # Get the device info section data
        device_info = get_in(report, ["general", "device_info"]) || []
        Jason.encode!(device_info)

      _ ->
        # For any unknown section, return empty JSON array
        "[]"
    end
  rescue
    e ->
      Logger.error("Error getting general section content: #{inspect(e)}")
      "[]"
  end
end
