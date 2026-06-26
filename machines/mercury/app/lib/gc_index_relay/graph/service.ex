defmodule GcIndexRelay.Graph.Service do
  @moduledoc """
  Service for querying Apache AGE for user and community connections.
  """

  alias GcIndexRelay.Repo
  import Ecto.Adapters.SQL, only: [query: 3]

  @doc """
  Finds all pubkeys that a given pubkey follows.
  """
  def get_follows(pubkey) do
    sql = """
    SELECT * FROM cypher('nostr_graph', $$
      MATCH (u:Pubkey {id: '#{pubkey}'})-[:FOLLOWS]->(f:Pubkey)
      RETURN f.id
    $$) AS (id agtype);
    """
    
    case query(Repo, sql, []) do
      {:ok, %{rows: rows}} -> 
        {:ok, Enum.map(rows, &parse_agtype/1)}
      error -> error
    end
  end

  @doc """
  Finds all communities that a given pubkey moderates.
  """
  def get_moderated_communities(pubkey) do
    sql = """
    SELECT * FROM cypher('nostr_graph', $$
      MATCH (u:Pubkey {id: '#{pubkey}'})-[:MODERATES]->(c:Community)
      RETURN c.id
    $$) AS (id agtype);
    """
    
    case query(Repo, sql, []) do
      {:ok, %{rows: rows}} -> 
        {:ok, Enum.map(rows, &parse_agtype/1)}
      error -> error
    end
  end

  @doc """
  Finds all members of a community (those who follow a moderator of the community).
  """
  def get_community_network(community_id) do
    sql = """
    SELECT * FROM cypher('nostr_graph', $$
      MATCH (m:Pubkey)-[:MODERATES]->(c:Community {id: '#{community_id}'})
      MATCH (u:Pubkey)-[:FOLLOWS]->(m)
      RETURN u.id
    $$) AS (id agtype);
    """
    
    case query(Repo, sql, []) do
      {:ok, %{rows: rows}} -> 
        {:ok, Enum.map(rows, &parse_agtype/1) |> Enum.uniq()}
      error -> error
    end
  end

  # Helper to clean up AGE's agtype string, e.g., "\"pubkey123\"" -> "pubkey123"
  defp parse_agtype([agtype_str]) when is_binary(agtype_str) do
    String.trim(agtype_str, "\"")
  end
  defp parse_agtype(_), do: nil
end
