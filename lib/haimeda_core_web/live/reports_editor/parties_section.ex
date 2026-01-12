defmodule HaimedaCoreWeb.ReportsEditor.PartiesSection do
  alias HaimedaCoreWeb.ReportsEditor.ContentPersistence
  require Logger

  def handle_event("add-person-statement", %{"id" => tab_id}, socket) do
    tab = Enum.find(socket.assigns.tabs, &(&1.id == tab_id))

    if tab && tab.category == "parties" do
      statements =
        ContentPersistence.get_person_statements_for_ui(Map.get(tab, :person_statements, "[]"))

      next_id =
        if Enum.empty?(statements) do
          1
        else
          statements
          |> Enum.map(fn statement -> Map.get(statement, "id", 0) end)
          |> Enum.max()
          |> Kernel.+(1)
        end

      updated_statements = statements ++ [%{"id" => next_id, "content" => ""}]

      updated_tabs =
        Enum.map(socket.assigns.tabs, fn t ->
          if t.id == tab_id do
            Map.put(t, :person_statements, Jason.encode!(updated_statements))
          else
            t
          end
        end)

      updated_tab = Enum.find(updated_tabs, &(&1.id == tab_id))
      ContentPersistence.save_party_statements_to_db(socket, updated_tab)

      {:tabs, updated_tabs}
    else
      {:error, "Invalid tab or category"}
    end
  end

  def handle_event("remove-person-statement", %{"id" => tab_id, "index" => index}, socket) do
    index = String.to_integer(index)
    tab = Enum.find(socket.assigns.tabs, &(&1.id == tab_id))

    if tab && tab.category == "parties" do
      statements =
        ContentPersistence.get_person_statements_for_ui(Map.get(tab, :person_statements, "[]"))

      statement_to_remove = Enum.at(statements, index)
      removed_id = statement_to_remove["id"]

      updated_statements = List.delete_at(statements, index)

      updated_tabs =
        Enum.map(socket.assigns.tabs, fn t ->
          if t.id == tab_id do
            Map.put(t, :person_statements, Jason.encode!(updated_statements))
          else
            t
          end
        end)

      if removed_id do
        analysis_statements =
          ContentPersistence.get_analysis_statements_for_ui(
            Map.get(tab, :analysis_statements, "[]")
          )

        updated_analysis =
          Enum.reject(analysis_statements, fn stmt ->
            Map.get(stmt, "related_to") == removed_id
          end)

        updated_tabs =
          Enum.map(updated_tabs, fn t ->
            if t.id == tab_id do
              Map.put(t, :analysis_statements, Jason.encode!(updated_analysis))
            else
              t
            end
          end)
      end

      updated_tab = Enum.find(updated_tabs, &(&1.id == tab_id))
      ContentPersistence.save_party_statements_to_db(socket, updated_tab)

      {:tabs, updated_tabs}
    else
      {:error, "Invalid tab or category"}
    end
  end

  def handle_event("update-person-statement", params, socket) do
    tab_id = params["id"]
    index = String.to_integer(params["index"])
    value = params["value"]
    tab = Enum.find(socket.assigns.tabs, &(&1.id == tab_id))

    if tab && tab.category == "parties" do
      statements =
        ContentPersistence.get_person_statements_for_ui(Map.get(tab, :person_statements, "[]"))

      updated_statements =
        List.update_at(statements, index, fn statement ->
          Map.put(statement, "content", value)
        end)

      updated_tabs =
        Enum.map(socket.assigns.tabs, fn t ->
          if t.id == tab_id do
            Map.put(t, :person_statements, Jason.encode!(updated_statements))
          else
            t
          end
        end)

      updated_tab = Enum.find(updated_tabs, &(&1.id == tab_id))
      ContentPersistence.save_party_statements_to_db(socket, updated_tab)

      {:tabs, updated_tabs}
    else
      {:error, "Invalid tab or category"}
    end
  end

  def handle_event("update-person-statement-id", params, socket) do
    tab_id = params["id"]
    index = params["index"] |> ensure_integer()
    new_id = params["value"] |> ensure_integer()

    Logger.info("Received update-person-statement-id event with params: #{inspect(params)}")
    Logger.info("Processing index: #{index}, new_id: #{new_id} for tab: #{tab_id}")

    tab = Enum.find(socket.assigns.tabs, &(&1.id == tab_id))

    if tab && tab.category == "parties" do
      person_statements_json = Map.get(tab, :person_statements, "[]")
      Logger.debug("Current person statements JSON: #{inspect(person_statements_json)}")

      statements = ContentPersistence.get_person_statements_for_ui(person_statements_json)

      current_ids = Enum.map(statements, & &1["id"])
      Logger.debug("Current statement IDs: #{inspect(current_ids)}")

      old_id = Enum.at(statements, index)["id"]
      Logger.info("Changing person statement ID from #{old_id} to #{new_id}")

      updated_statements =
        List.update_at(statements, index, fn statement ->
          Map.put(statement, "id", new_id)
        end)

      analysis_statements =
        ContentPersistence.get_analysis_statements_for_ui(
          Map.get(tab, :analysis_statements, "[]")
        )

      updated_analysis =
        Enum.map(analysis_statements, fn stmt ->
          if Map.get(stmt, "related_to") == old_id do
            Map.put(stmt, "related_to", new_id)
          else
            stmt
          end
        end)

      updated_person_json = Jason.encode!(updated_statements)
      updated_analysis_json = Jason.encode!(updated_analysis)

      Logger.debug("Updated person statements: #{inspect(updated_statements)}")

      updated_tab = %{
        tab
        | person_statements: updated_person_json,
          analysis_statements: updated_analysis_json
      }

      updated_tabs =
        Enum.map(socket.assigns.tabs, fn t ->
          if t.id == tab_id, do: updated_tab, else: t
        end)

      save_result = ContentPersistence.save_party_statements_to_db(socket, updated_tab)
      Logger.info("Database save result: #{inspect(save_result)}")

      {:tabs, updated_tabs}
    else
      Logger.warning("Tab not found or not a parties tab: #{tab_id}")
      {:error, "Tab not found or not a parties tab"}
    end
  end

  def handle_event("add-analysis-statement", params, socket) do
    tab_id = params["id"]
    tab = Enum.find(socket.assigns.tabs, &(&1.id == tab_id))

    if tab && tab.category == "parties" do
      analysis_statements =
        ContentPersistence.get_analysis_statements_for_ui(
          Map.get(tab, :analysis_statements, "[]")
        )

      next_id =
        if Enum.empty?(analysis_statements) do
          1
        else
          analysis_statements
          |> Enum.map(fn statement -> Map.get(statement, "id", 0) end)
          |> Enum.max()
          |> Kernel.+(1)
        end

      person_statements =
        ContentPersistence.get_person_statements_for_ui(Map.get(tab, :person_statements, "[]"))

      related_to =
        if Enum.empty?(person_statements) do
          1
        else
          Map.get(List.first(person_statements), "id", 1)
        end

      updated_statements =
        analysis_statements ++
          [
            %{"id" => next_id, "related_to" => related_to, "content" => ""}
          ]

      updated_tabs =
        Enum.map(socket.assigns.tabs, fn t ->
          if t.id == tab_id do
            Map.put(t, :analysis_statements, Jason.encode!(updated_statements))
          else
            t
          end
        end)

      updated_tab = Enum.find(updated_tabs, &(&1.id == tab_id))
      ContentPersistence.save_party_statements_to_db(socket, updated_tab)

      {:tabs, updated_tabs}
    else
      {:error, "Invalid tab or category"}
    end
  end

  def handle_event("remove-analysis-statement", params, socket) do
    tab_id = params["id"]
    index = String.to_integer(params["index"])
    tab = Enum.find(socket.assigns.tabs, &(&1.id == tab_id))

    if tab && tab.category == "parties" do
      statements =
        ContentPersistence.get_analysis_statements_for_ui(
          Map.get(tab, :analysis_statements, "[]")
        )

      updated_statements = List.delete_at(statements, index)

      updated_tabs =
        Enum.map(socket.assigns.tabs, fn t ->
          if t.id == tab_id do
            Map.put(t, :analysis_statements, Jason.encode!(updated_statements))
          else
            t
          end
        end)

      updated_tab = Enum.find(updated_tabs, &(&1.id == tab_id))
      ContentPersistence.save_party_statements_to_db(socket, updated_tab)

      {:tabs, updated_tabs}
    else
      {:error, "Invalid tab or category"}
    end
  end

  def handle_event("update-analysis-statement", params, socket) do
    tab_id = params["id"]
    index = String.to_integer(params["index"])
    value = params["value"]
    tab = Enum.find(socket.assigns.tabs, &(&1.id == tab_id))

    if tab && tab.category == "parties" do
      statements =
        ContentPersistence.get_analysis_statements_for_ui(
          Map.get(tab, :analysis_statements, "[]")
        )

      updated_statements =
        List.update_at(statements, index, fn statement ->
          Map.put(statement, "content", value)
        end)

      updated_tabs =
        Enum.map(socket.assigns.tabs, fn t ->
          if t.id == tab_id do
            Map.put(t, :analysis_statements, Jason.encode!(updated_statements))
          else
            t
          end
        end)

      updated_tab = Enum.find(updated_tabs, &(&1.id == tab_id))
      ContentPersistence.save_party_statements_to_db(socket, updated_tab)

      {:tabs, updated_tabs}
    else
      {:error, "Invalid tab or category"}
    end
  end

  def handle_event("update-analysis-statement-related", params, socket) do
    tab_id = params["id"]
    index = params["index"] |> ensure_integer()
    related_to = params["value"] |> ensure_integer()

    Logger.info(
      "Received update-analysis-statement-related event with params: #{inspect(params)}"
    )

    Logger.info("Processing index: #{index}, related_to: #{related_to} for tab: #{tab_id}")

    tab = Enum.find(socket.assigns.tabs, &(&1.id == tab_id))

    if tab && tab.category == "parties" do
      analysis_statements =
        ContentPersistence.get_analysis_statements_for_ui(
          Map.get(tab, :analysis_statements, "[]")
        )

      person_statements =
        ContentPersistence.get_person_statements_for_ui(Map.get(tab, :person_statements, "[]"))

      available_ids = Enum.map(person_statements, & &1["id"])

      Logger.debug("Available person statement IDs: #{inspect(available_ids)}")

      if related_to in available_ids do
        updated_statements =
          List.update_at(analysis_statements, index, fn statement ->
            Map.put(statement, "related_to", related_to)
          end)

        updated_json = Jason.encode!(updated_statements)

        updated_tab = %{
          tab
          | analysis_statements: updated_json
        }

        updated_tabs =
          Enum.map(socket.assigns.tabs, fn t ->
            if t.id == tab_id, do: updated_tab, else: t
          end)

        save_result = ContentPersistence.save_party_statements_to_db(socket, updated_tab)
        Logger.info("Database save result: #{inspect(save_result)}")

        {:tabs, updated_tabs}
      else
        Logger.warning(
          "Attempted to link analysis to non-existent person statement ID: #{related_to}"
        )

        {:error, "Invalid related_to ID"}
      end
    else
      Logger.warning("Tab not found or not a parties tab: #{tab_id}")
      {:error, "Tab not found or not a parties tab"}
    end
  end

  def ensure_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {num, _} -> num
      :error -> 0
    end
  end

  def ensure_integer(value) when is_integer(value), do: value
  def ensure_integer(_), do: 0
end
