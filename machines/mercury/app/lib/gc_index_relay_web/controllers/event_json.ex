defmodule GcIndexRelayWeb.EventJSON do
  alias GcIndexRelay.Nostr.PubEvent

  @doc """
  Renders a single event.
  """
  def show(%{event: event}) do
    %{data: data(event)}
  end

  defp data(%PubEvent{} = event) do
    %{
      id: event.id,
      pubkey: event.pubkey,
      created_at: event.created_at,
      kind: event.kind,
      content: event.content,
      sig: event.sig,
      tags: event.tags
    }
  end
end
