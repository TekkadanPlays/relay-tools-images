defmodule GcIndexRelay.Auth.Roles do
  @moduledoc """
  Role resolution for Mycelium admin/moderation system.

  Checks three sources for admin status (in priority order):
  1. `MERCURY_ADMIN_PUBKEYS` env var (comma-separated, lockout recovery)
  2. `site_admins` DB table (first-claim + API-appointed)
  3. `community_moderators` DB table (appointed by admin)

  Bans are checked via `banned_users` with automatic expiry handling.
  """

  import Ecto.Query
  alias GcIndexRelay.Repo
  alias GcIndexRelay.Nostr.SiteAdmin
  alias GcIndexRelay.Nostr.BannedUser
  alias GcIndexRelay.Nostr.CommunityModerator

  @doc """
  Returns true if the given pubkey has site admin privileges.
  Checks the .env override first, then the DB.
  """
  @spec is_admin?(String.t()) :: boolean()
  def is_admin?(pubkey) when is_binary(pubkey) do
    pubkey_lower = String.downcase(pubkey)
    in_env_admin_list?(pubkey_lower) or in_db_admin_list?(pubkey_lower)
  end

  @doc """
  Returns true if no site admin has been claimed yet.
  Used by the claim-admin endpoint.
  """
  @spec admin_unclaimed?() :: boolean()
  def admin_unclaimed? do
    env_admins = parse_env_admin_pubkeys()
    db_count = Repo.aggregate(SiteAdmin, :count)
    Enum.empty?(env_admins) and db_count == 0
  end

  @doc """
  Inserts a new site admin into the DB.
  Returns `{:ok, admin}` or `{:error, changeset}`.
  """
  @spec claim_admin(String.t(), String.t() | nil) :: {:ok, SiteAdmin.t()} | {:error, Ecto.Changeset.t()}
  def claim_admin(pubkey, label \\ nil) do
    %SiteAdmin{}
    |> SiteAdmin.changeset(%{
      pubkey: String.downcase(pubkey),
      label: label,
      claimed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert()
  end

  @doc """
  Returns true if the given pubkey is banned, either site-wide
  or from the given community scope. Expired bans are ignored.
  """
  @spec is_banned?(String.t(), String.t() | nil) :: boolean()
  def is_banned?(pubkey, scope \\ nil) when is_binary(pubkey) do
    pubkey_lower = String.downcase(pubkey)
    now = DateTime.utc_now()

    # For site-wide check (scope=nil), only match NULL scope.
    # For community check, match NULL (site-wide) OR the specific scope.
    query =
      if scope do
        from b in BannedUser,
          where: b.pubkey == ^pubkey_lower,
          where: is_nil(b.scope) or b.scope == ^scope,
          where: is_nil(b.expires_at) or b.expires_at > ^now,
          limit: 1
      else
        from b in BannedUser,
          where: b.pubkey == ^pubkey_lower,
          where: is_nil(b.scope),
          where: is_nil(b.expires_at) or b.expires_at > ^now,
          limit: 1
      end

    Repo.exists?(query)
  end

  @doc """
  Creates a ban record. Returns `{:ok, ban}` or `{:error, changeset}`.
  """
  @spec ban_user(String.t(), String.t(), String.t() | nil, String.t() | nil, DateTime.t() | nil) ::
          {:ok, BannedUser.t()} | {:error, Ecto.Changeset.t()}
  def ban_user(pubkey, banned_by, scope \\ nil, reason \\ nil, expires_at \\ nil) do
    %BannedUser{}
    |> BannedUser.changeset(%{
      pubkey: String.downcase(pubkey),
      banned_by: String.downcase(banned_by),
      scope: scope,
      reason: reason,
      expires_at: expires_at
    })
    |> Repo.insert(
      on_conflict: {:replace, [:banned_by, :reason, :expires_at, :updated_at]},
      conflict_target: {:unsafe_fragment, "(pubkey, scope) WHERE scope IS NOT NULL"}
    )
  end

  @doc """
  Removes a ban. Returns `{deleted_count, nil}`.
  """
  @spec unban_user(String.t(), String.t() | nil) :: {non_neg_integer(), nil}
  def unban_user(pubkey, scope \\ nil) do
    pubkey_lower = String.downcase(pubkey)

    query =
      if scope do
        from b in BannedUser,
          where: b.pubkey == ^pubkey_lower and b.scope == ^scope
      else
        from b in BannedUser,
          where: b.pubkey == ^pubkey_lower and is_nil(b.scope)
      end

    Repo.delete_all(query)
  end

  @doc """
  Lists all active bans (unexpired).
  """
  @spec list_bans() :: [BannedUser.t()]
  def list_bans do
    now = DateTime.utc_now()

    from(b in BannedUser,
      where: is_nil(b.expires_at) or b.expires_at > ^now,
      order_by: [desc: b.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Lists all site admins (DB + env).
  """
  @spec list_admins() :: [map()]
  def list_admins do
    db_admins =
      Repo.all(from a in SiteAdmin, order_by: [asc: a.claimed_at])
      |> Enum.map(fn a ->
        %{pubkey: a.pubkey, label: a.label, source: "database", claimed_at: a.claimed_at}
      end)

    env_admins =
      parse_env_admin_pubkeys()
      |> Enum.map(fn pk ->
        %{pubkey: pk, label: nil, source: "env_override", claimed_at: nil}
      end)

    # Deduplicate: DB entries take precedence over env
    db_pubkeys = MapSet.new(db_admins, & &1.pubkey)
    env_only = Enum.reject(env_admins, fn a -> MapSet.member?(db_pubkeys, a.pubkey) end)

    db_admins ++ env_only
  end

  # ── Moderator functions ──

  @doc """
  Returns true if the given pubkey is a moderator for the given community.
  Admins implicitly have mod privileges on all communities.
  """
  @spec is_mod?(String.t(), String.t()) :: boolean()
  def is_mod?(pubkey, community_atag) when is_binary(pubkey) and is_binary(community_atag) do
    pubkey_lower = String.downcase(pubkey)
    is_admin?(pubkey_lower) or
      Repo.exists?(
        from m in CommunityModerator,
          where: m.pubkey == ^pubkey_lower and m.community_atag == ^community_atag
      )
  end

  @doc """
  Appoints a community moderator. Only admins should call this.
  Returns `{:ok, mod}` or `{:error, changeset}`.
  """
  @spec appoint_mod(String.t(), String.t(), String.t()) ::
          {:ok, CommunityModerator.t()} | {:error, Ecto.Changeset.t()}
  def appoint_mod(pubkey, community_atag, appointed_by) do
    %CommunityModerator{}
    |> CommunityModerator.changeset(%{
      pubkey: String.downcase(pubkey),
      community_atag: community_atag,
      appointed_by: String.downcase(appointed_by),
      appointed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert()
  end

  @doc """
  Removes a community moderator. Returns `{deleted_count, nil}`.
  """
  @spec remove_mod(String.t(), String.t()) :: {non_neg_integer(), nil}
  def remove_mod(pubkey, community_atag) do
    pubkey_lower = String.downcase(pubkey)
    from(m in CommunityModerator,
      where: m.pubkey == ^pubkey_lower and m.community_atag == ^community_atag
    )
    |> Repo.delete_all()
  end

  @doc """
  Lists all community moderators, optionally filtered by community.
  """
  @spec list_mods(String.t() | nil) :: [CommunityModerator.t()]
  def list_mods(community_atag \\ nil) do
    query = from(m in CommunityModerator, order_by: [asc: m.appointed_at])
    query =
      if community_atag do
        from m in query, where: m.community_atag == ^community_atag
      else
        query
      end
    Repo.all(query)
  end

  # ── Private ──

  defp in_env_admin_list?(pubkey) do
    pubkey in parse_env_admin_pubkeys()
  end

  defp in_db_admin_list?(pubkey) do
    Repo.exists?(from a in SiteAdmin, where: a.pubkey == ^pubkey)
  end

  defp parse_env_admin_pubkeys do
    case System.get_env("MERCURY_ADMIN_PUBKEYS") do
      nil -> []
      "" -> []
      raw ->
        raw
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.map(&String.downcase/1)
        |> Enum.filter(&String.match?(&1, ~r/^[0-9a-f]{64}$/))
    end
  end
end
