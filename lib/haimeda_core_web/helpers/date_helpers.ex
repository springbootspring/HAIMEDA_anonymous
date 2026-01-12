defmodule HaimedaCoreWeb.DateHelpers do
  @moduledoc """
  Helper functions for date formatting and manipulation.
  """

  @doc """
  Formats a DateTime object to a human-readable string.
  Returns a default message for nil or invalid dates.
  """
  def format_date(%DateTime{} = date) do
    Calendar.strftime(date, "%d.%m.%Y %H:%M")
  end

  # Handle string dates
  def format_date(date) when is_binary(date) do
    case DateTime.from_iso8601(date) do
      {:ok, datetime, _} ->
        Calendar.strftime(datetime, "%d.%m.%Y %H:%M")

      _ ->
        case Date.from_iso8601(date) do
          {:ok, parsed_date} -> Calendar.strftime(parsed_date, "%d.%m.%Y")
          _ -> date
        end
    end
  rescue
    _ -> date
  end

  # Handle nil values
  def format_date(nil), do: ""

  def format_date(_), do: "Unbekanntes Datum"
end
