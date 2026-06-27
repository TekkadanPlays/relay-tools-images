defmodule Mix.Tasks.Mercury.AddAdmin do
  @moduledoc """
  Adds a site admin pubkey to the database.

  Unlike `claim_admin`, this works even when admins already exist.
  Use this to add additional admins after the initial claim.

  ## Usage

      mix mercury.add_admin abc123...def456
      mix mercury.add_admin npub1... --label "Moderator Bob"
  """

  use Mix.Task

  @shortdoc "Add an additional site admin"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional, _} = OptionParser.parse(args, strict: [label: :string])
    label = Keyword.get(opts, :label)

    case positional do
      [pubkey_input] ->
        # Reuse the pubkey resolver from ClaimAdmin
        pubkey = resolve_pubkey(pubkey_input)

        case GcIndexRelay.Auth.Roles.claim_admin(pubkey, label) do
          {:ok, admin} ->
            Mix.shell().info("✓ Added admin: #{admin.pubkey}")

          {:error, changeset} ->
            errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)
            Mix.shell().error("Failed: #{inspect(errors)}")
        end

      _ ->
        Mix.shell().error("Usage: mix mercury.add_admin <pubkey_hex_or_npub> [--label \"Name\"]")
    end
  end

  defp resolve_pubkey("npub1" <> _ = npub) do
    case Mix.Tasks.Mercury.ClaimAdmin.decode_bech32(npub) do
      {:ok, hex} -> hex
      {:error, reason} ->
        Mix.shell().error("Failed to decode npub: #{reason}")
        System.halt(1)
    end
  end

  defp resolve_pubkey(hex) when byte_size(hex) == 64 do
    if String.match?(hex, ~r/^[0-9a-f]{64}$/), do: hex,
    else: (Mix.shell().error("Invalid hex pubkey"); System.halt(1))
  end

  defp resolve_pubkey(_) do
    Mix.shell().error("Expected 64-char hex or npub1...")
    System.halt(1)
  end
end
