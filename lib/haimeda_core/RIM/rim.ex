defmodule RIM do
  alias RIM.{
    VectorPersistence,
    QueryProcessor,
    ResponseGenerator,
    RequestHandler,
    ResourceAgent
  }

  alias HaimedaCore.FeedbackModule

  require Logger

  def initialize_RAG_processor(target_pid, rag_config) do
    # Verify embedding model existence
    case rag_config.embedding_model do
      nil ->
        Logger.error("No embedding model specified in RAG configuration")
        {:error, :no_embedding_model}

      model ->
        Logger.info("Initializing RAG processor with embedding model: #{model}")

        # Verify vector existence
        case VectorPersistence.verify_existence_of_vectors(rag_config) do
          {:ok, message} ->
            Logger.info("RAG processor initialized: #{message}")
            # Initialize the resource agent when the RAG processor starts
            mdb_files_path =
              Map.get(rag_config, :mdb_files_path) || Map.get(rag_config, "mdb_files_path")

            ResourceAgent.startup_resource_agent(mdb_files_path)
            {:ok, message}

          {:error, reason} ->
            Logger.error("Failed to initialize RAG processor: #{reason}")
            {:error, reason}
        end
    end
  end

  def process_user_request(target_pid, rag_config, user_request) do
    # extract keywords from the user request

    # Start both operations in parallel
    embedding_task =
      Task.async(fn ->
        VectorPersistence.embed_string(user_request, rag_config)
      end)

    mdb_files_path = Map.get(rag_config, :mdb_files_path) || Map.get(rag_config, "mdb_files_path")

    resource_agent_task =
      Task.async(fn ->
        unless ResourceAgent.is_running?() do
          ResourceAgent.startup_resource_agent(mdb_files_path)
        end

        :ok
      end)

    # Wait for both operations to complete
    embedded_user_request = Task.await(embedding_task)
    :ok = Task.await(resource_agent_task)

    input_info = %{
      user_request: user_request,
      embedded_user_request: embedded_user_request,
      rag_config: rag_config
    }

    query_processor_map =
      RequestHandler.construct_query_processor_map(input_info)

    if target_pid != nil do
      FeedbackModule.set_loading_message(target_pid, :db_search)
    end

    case QueryProcessor.process_query(query_processor_map) do
      {:ok, query_results} ->
        ResponseGenerator.generate_reponse_from_query_results(query_results)

      _ ->
        {:error, :query_processing_failed}
    end
  end
end
