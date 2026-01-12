defmodule OllamaRemoteService do
  require Logger

  @doc """
  Process a request to a remote Ollama server.
  """
  def process_request(ollama_server_url, messages, model, parameters \\ %{}) do
    # Validate URL
    case validate_url(ollama_server_url) do
      {:ok, base_url} ->
        # Format the request body
        request_body = %{
          model: model,
          messages: format_messages(messages),
          options: parameters
        }

        # Send request with retry mechanism
        send_request_with_retry(base_url, request_body)

      {:error, reason} ->
        Logger.error("Invalid Ollama server URL: #{reason}")
        "ERROR: Invalid Ollama server URL - #{reason}"
    end
  end

  # Validate and normalize the URL
  defp validate_url(nil), do: {:error, "No Ollama server URL provided"}
  defp validate_url(""), do: {:error, "Empty Ollama server URL"}

  defp validate_url(url) do
    # Ensure URL ends with /api
    url = String.trim_trailing(url, "/")

    if String.ends_with?(url, "/api") do
      {:ok, url}
    else
      # Add /api if not present
      {:ok, "#{url}/api"}
    end
  end

  # Format messages to match Ollama API format
  defp format_messages(messages) do
    Enum.map(messages, fn msg ->
      %{
        role: msg.role,
        content: msg.content
      }
    end)
  end

  # Send request with retry mechanism
  defp send_request_with_retry(base_url, request_body, retries_left \\ 3) do
    endpoint = "#{base_url}/chat"

    headers = [
      {"Content-Type", "application/json"},
      {"Accept", "application/json"}
    ]

    body = Jason.encode!(request_body)

    case HTTPoison.post(endpoint, body, headers, recv_timeout: 60000) do
      {:ok, %{status_code: 200, body: response_body}} ->
        case Jason.decode(response_body) do
          {:ok, %{"message" => %{"content" => content}}} ->
            content

          {:ok, decoded} ->
            Logger.warning("Unexpected response format: #{inspect(decoded)}")
            "ERROR: Unexpected response format"

          {:error, reason} ->
            Logger.error("Failed to decode response: #{inspect(reason)}")
            "ERROR: Failed to decode response"
        end

      {:ok, %{status_code: status_code, body: body}} ->
        error_message = "Ollama server returned status #{status_code}: #{body}"
        Logger.error(error_message)

        if retries_left > 0 do
          # Wait a moment before retrying
          :timer.sleep(2000)
          send_request_with_retry(base_url, request_body, retries_left - 1)
        else
          "ERROR: #{error_message}"
        end

      {:error, %{reason: reason}} ->
        error_message = "HTTP request failed: #{inspect(reason)}"
        Logger.error(error_message)

        if retries_left > 0 do
          # Wait a moment before retrying
          :timer.sleep(2000)
          send_request_with_retry(base_url, request_body, retries_left - 1)
        else
          "ERROR: #{error_message}"
        end
    end
  end
end
