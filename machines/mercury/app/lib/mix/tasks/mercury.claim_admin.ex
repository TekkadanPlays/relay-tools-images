defmodule Mix.Tasks.Mercury.ClaimAdmin do
  @moduledoc """
  Claims site admin for a given Nostr pubkey.

  This is the simplest way to bootstrap the admin system on a fresh
  instance. Run it directly on the server — no signing required.

  ## Usage

      # With hex pubkey:
      mix mercury.claim_admin abc123...def456

      # With npub (bech32):
      mix mercury.claim_admin npub1...

      # With optional label:
      mix mercury.claim_admin abc123...def456 --label "TekkadanPlays"

  ## Notes

  - Only works if no admin has been claimed yet (empty site_admins table).
  - To force-add additional admins, use `mix mercury.add_admin`.
  """

  use Mix.Task

  @shortdoc "Claim site admin for a Nostr pubkey (first-time setup)"

  @impl Mix.Task
  def run(args) do
    # Start the app so Ecto/Repo is available
    Mix.Task.run("app.start")

    {opts, positional, _} = OptionParser.parse(args, strict: [label: :string])
    label = Keyword.get(opts, :label, "first-claim")

    case positional do
      [pubkey_input] ->
        pubkey = resolve_pubkey(pubkey_input)
        do_claim(pubkey, label)

      _ ->
        Mix.shell().error("""
        Usage: mix mercury.claim_admin <pubkey_hex_or_npub> [--label "Name"]

        Examples:
          mix mercury.claim_admin abc123...def456
          mix mercury.claim_admin npub1abc123...
          mix mercury.claim_admin abc123...def456 --label "TekkadanPlays"
        """)
    end
  end

  defp resolve_pubkey("npub1" <> _ = npub) do
    # Decode bech32 npub to hex
    case decode_bech32(npub) do
      {:ok, hex} ->
        Mix.shell().info("Decoded npub → #{hex}")
        hex

      {:error, reason} ->
        Mix.shell().error("Failed to decode npub: #{reason}")
        System.halt(1)
    end
  end

  defp resolve_pubkey(hex) when byte_size(hex) == 64 do
    if String.match?(hex, ~r/^[0-9a-f]{64}$/) do
      hex
    else
      Mix.shell().error("Invalid pubkey: must be 64 lowercase hex characters")
      System.halt(1)
    end
  end

  defp resolve_pubkey(other) do
    Mix.shell().error("Invalid pubkey format: #{inspect(other)}")
    Mix.shell().error("Expected 64-char hex or npub1... bech32")
    System.halt(1)
  end

  defp do_claim(pubkey, label) do
    alias GcIndexRelay.Auth.Roles

    if Roles.admin_unclaimed?() do
      case Roles.claim_admin(pubkey, label) do
        {:ok, admin} ->
          Mix.shell().info("""

          ╔══════════════════════════════════════════════════╗
          ║  ✓ Admin claimed successfully!                  ║
          ╚══════════════════════════════════════════════════╝

            Pubkey: #{admin.pubkey}
            Label:  #{admin.label || "(none)"}

          You can now use the admin API:
            POST /api/auth/token  → sign a kind-27235 event to get a bearer token
            GET  /api/admin/stats → with Authorization: Bearer <token>

          Or set MERCURY_ADMIN_API_KEY in .env for script access.
          """)

        {:error, changeset} ->
          errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)
          Mix.shell().error("Failed to claim admin: #{inspect(errors)}")
      end
    else
      admins = Roles.list_admins()
      existing = Enum.map_join(admins, "\n    ", &"• #{&1.pubkey} (#{&1.source})")

      Mix.shell().error("""

      ✗ Admin already claimed. Existing admins:
        #{existing}

      To add another admin, use: mix mercury.add_admin <pubkey>
      """)
    end
  end

  @doc "Decode a bech32 npub to hex. Public so other Mix tasks can reuse."
  def decode_bech32(bech32_string) do
    try do
      # bech32 alphabet
      charset = ~c"qpzry9x8gf2tvdw0s3jn54khce6mua7l"
      charset_map = charset |> Enum.with_index() |> Map.new()

      # Split at last "1"
      lower = String.downcase(bech32_string)
      pos = lower |> String.reverse() |> :binary.match("1") |> elem(0)
      data_part = String.slice(lower, -(pos), pos)

      # Decode characters to 5-bit values
      values =
        data_part
        |> String.to_charlist()
        |> Enum.map(fn c ->
          Map.get(charset_map, c) || raise "invalid bech32 character: #{<<c>>}"
        end)

      # Drop the 6-byte checksum
      data_values = Enum.drop(values, -6)

      # Convert from 5-bit groups to 8-bit bytes
      bits = data_values |> Enum.flat_map(fn v ->
        for i <- 4..0//-1, do: Bitwise.band(Bitwise.bsr(v, i), 1)
      end)

      # Drop the first 5 bits (witness version for segwit, but for nostr it's padding)
      # Actually for bech32 npub: the data after hrp is raw 5-bit, convert to 8-bit
      bytes =
        bits
        |> Enum.chunk_every(8)
        |> Enum.reject(&(length(&1) < 8))
        |> Enum.map(fn byte_bits ->
          byte_bits |> Enum.reduce(0, fn bit, acc -> Bitwise.bsl(acc, 1) + bit end)
        end)

      hex = bytes |> Enum.map(&Integer.to_string(&1, 16) |> String.pad_leading(2, "0")) |> Enum.join() |> String.downcase()

      if String.length(hex) == 64 do
        {:ok, hex}
      else
        {:error, "decoded to #{String.length(hex)} chars, expected 64"}
      end
    rescue
      e -> {:error, Exception.message(e)}
    end
  end
end
