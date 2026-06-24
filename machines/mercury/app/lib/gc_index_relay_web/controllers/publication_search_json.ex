defmodule GcIndexRelayWeb.PublicationSearchJSON do
  alias GcIndexRelay.Nostr.PubEvent

  def index(%{events: events}) do
    %{data: Enum.map(events, &data/1)}
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
