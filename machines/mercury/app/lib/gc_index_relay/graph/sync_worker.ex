defmodule GcIndexRelay.Graph.SyncWorker do
  @moduledoc """
  Subscribes to new Nostr events via PubSub and syncs relevant graph data 
  to Apache AGE (e.g. follows, community memberships).
  """
  use GenServer
  require Logger

  alias GcIndexRelay.Nostr.PubEvent
  alias GcIndexRelay.Repo
  import Ecto.Adapters.SQL, only: [query: 3]

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    Phoenix.PubSub.subscribe(GcIndexRelay.PubSub, "events")
    Logger.info("Graph.SyncWorker started and subscribed to events for AGE")
    {:ok, state}
  end

  @impl true
  def handle_info({:new_event, %PubEvent{kind: 3} = event}, state) do
    # Kind 3: Contact List
    pubkey = event.pubkey
    
    follow_pubkeys = 
      (event.tags || [])
      |> Enum.filter(fn [name | _] -> name == "p" end)
      |> Enum.map(fn [_, val | _] -> val end)

    # Wrap in transaction to delete existing and insert new
    Repo.transaction(fn ->
      # Delete existing follows
      delete_sql = """
      SELECT * FROM cypher('nostr_graph', $$
        MATCH (u:Pubkey {id: '#{pubkey}'})-[r:FOLLOWS]->()
        DELETE r
      $$) AS (v agtype);
      """
      query(Repo, delete_sql, [])

      # Merge current user node
      merge_user_sql = """
      SELECT * FROM cypher('nostr_graph', $$
        MERGE (u:Pubkey {id: '#{pubkey}'})
      $$) AS (v agtype);
      """
      query(Repo, merge_user_sql, [])

      # Merge follows
      Enum.each(follow_pubkeys, fn p ->
        merge_follow_sql = """
        SELECT * FROM cypher('nostr_graph', $$
          MATCH (u:Pubkey {id: '#{pubkey}'})
          MERGE (f:Pubkey {id: '#{p}'})
          MERGE (u)-[:FOLLOWS]->(f)
        $$) AS (v agtype);
        """
        query(Repo, merge_follow_sql, [])
      end)
    end)
    
    Logger.debug("Synced Kind 3 follows for pubkey #{pubkey}")
    {:noreply, state}
  end

  def handle_info({:new_event, %PubEvent{kind: 34550} = event}, state) do
    # Kind 34550: Communities
    pubkey = event.pubkey
    d_tag = 
      (event.tags || [])
      |> Enum.find(fn [name | _] -> name == "d" end)
      |> case do
        [_, val | _] -> val
        _ -> "unknown"
      end

    community_id = "#{pubkey}:#{d_tag}"

    moderator_pubkeys = 
      (event.tags || [])
      |> Enum.filter(fn [name | _] -> name == "p" end)
      |> Enum.map(fn [_, val | _] -> val end)

    Repo.transaction(fn ->
      # Merge community and owner
      merge_comm_sql = """
      SELECT * FROM cypher('nostr_graph', $$
        MERGE (c:Community {id: '#{community_id}'})
        MERGE (o:Pubkey {id: '#{pubkey}'})
        MERGE (c)-[:OWNED_BY]->(o)
      $$) AS (v agtype);
      """
      query(Repo, merge_comm_sql, [])

      # Merge moderators
      Enum.each(moderator_pubkeys, fn p ->
        merge_mod_sql = """
        SELECT * FROM cypher('nostr_graph', $$
          MATCH (c:Community {id: '#{community_id}'})
          MERGE (m:Pubkey {id: '#{p}'})
          MERGE (m)-[:MODERATES]->(c)
        $$) AS (v agtype);
        """
        query(Repo, merge_mod_sql, [])
      end)
    end)
    
    Logger.debug("Synced Kind 34550 community #{community_id}")
    {:noreply, state}
  end

  def handle_info({:new_event, _}, state) do
    # Ignore other kinds
    {:noreply, state}
  end
end
