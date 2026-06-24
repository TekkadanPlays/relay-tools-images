defmodule GcIndexRelayWeb.FallbackController do
  @moduledoc """
  Translates controller action results into valid `Plug.Conn` responses.

  See `Phoenix.Controller.action_fallback/1` for more details.
  """
  use GcIndexRelayWeb, :controller

  # This clause handles errors returned by Ecto's insert/update/delete.
  # Returns 409 Conflict for duplicate event IDs, 422 for other changeset errors.
  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    if duplicate_id_error?(changeset) do
      conn
      |> put_status(:conflict)
      |> json(%{errors: %{detail: "Event already exists"}})
    else
      conn
      |> put_status(:unprocessable_entity)
      |> put_view(json: GcIndexRelayWeb.ChangesetJSON)
      |> render(:error, changeset: changeset)
    end
  end

  # This clause handles string error messages (e.g., from filter validation).
  def call(conn, {:error, message}) when is_binary(message) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: message}})
  end

  # Atom errors (e.g. from PubEvent.to_db/1).
  def call(conn, {:error, reason}) when is_atom(reason) and reason != :not_found do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: atom_error_message(reason)}})
  end

  # This clause is an example of how to handle resources that cannot be found.
  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> put_view(html: GcIndexRelayWeb.ErrorHTML, json: GcIndexRelayWeb.ErrorJSON)
    |> render(:"404")
  end

  defp duplicate_id_error?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:id, {_, opts}} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end)
  end

  defp atom_error_message(:invalid_hex), do: "Invalid hexadecimal encoding in event fields"
  defp atom_error_message(:invalid_event), do: "Invalid event structure"
  defp atom_error_message(_), do: "Bad request"
end
