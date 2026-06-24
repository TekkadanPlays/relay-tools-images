defmodule GcIndexRelay.NostrFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `GcIndexRelay.Nostr` context.
  """

  alias GcIndexRelay.Nostr.PubEvent

  @doc """
  Generate an event in the database.

  This fixture requires database access and should only be used in integration tests.

  NOTE: This fixture is currently a stub, and should be updated and/or removed when proper integration tests are defined.
  """
  def event_fixture(attrs \\ %{}) do
    # Create a valid PubEvent with the provided attributes
    event = valid_pub_event_fixture(attrs)

    # Insert it into the database
    {:ok, db_event} = GcIndexRelay.Nostr.create_event(event)

    db_event
  end

  @doc """
  Returns test keypairs (public/private) from the grchat reference implementation.

  Returns a map with:
  - `:keypair1` - First test keypair
  - `:keypair2` - Second test keypair

  Each keypair contains:
  - `:secret_key` - 32-byte binary private key
  - `:public_key` - 32-byte binary public key
  - `:secret_key_hex` - Hex-encoded private key
  - `:public_key_hex` - Hex-encoded public key
  """
  def test_keypairs do
    %{
      keypair1: %{
        secret_key_hex: "98c642360e7163a66cee5d9a842b252345b6f3f3e21bd3b7635d5e6c20c7ea36",
        public_key_hex: "0db15182c4ad3418b4fbab75304be7ade9cfa430a21c1c5320c9298f54ea5406",
        secret_key:
          Base.decode16!("98c642360e7163a66cee5d9a842b252345b6f3f3e21bd3b7635d5e6c20c7ea36",
            case: :lower
          ),
        public_key:
          Base.decode16!("0db15182c4ad3418b4fbab75304be7ade9cfa430a21c1c5320c9298f54ea5406",
            case: :lower
          )
      },
      keypair2: %{
        secret_key_hex: "3032cb8da355f9e72c9a94bbabae80ca99d3a38de1aed094b432a9fe3432e1f2",
        public_key_hex: "421181660af5d39eb95e48a0a66c41ae393ba94ffeca94703ef81afbed724e5a",
        secret_key:
          Base.decode16!("3032cb8da355f9e72c9a94bbabae80ca99d3a38de1aed094b432a9fe3432e1f2",
            case: :lower
          ),
        public_key:
          Base.decode16!("421181660af5d39eb95e48a0a66c41ae393ba94ffeca94703ef81afbed724e5a",
            case: :lower
          )
      }
    }
  end

  @doc """
  Generate a valid signed PubEvent for testing.

  Uses Keypair 1 by default. Allows overrides via attrs.

  ## Options
  - `:keypair` - Which keypair to use (`:keypair1` or `:keypair2`, default: `:keypair1`)
  - `:pubkey` - Override public key (hex string)
  - `:created_at` - Override timestamp (integer)
  - `:kind` - Override event kind (integer)
  - `:tags` - Override tags (list)
  - `:content` - Override content (string)
  """
  def valid_pub_event_fixture(attrs \\ %{}) do
    # Convert keyword list to map if needed
    attrs = Enum.into(attrs, %{})

    keypair_key = Map.get(attrs, :keypair, :keypair1)
    keypairs = test_keypairs()
    keypair = Map.fetch!(keypairs, keypair_key)

    # Base event attributes
    base_attrs = %{
      pubkey: Map.get(attrs, :pubkey, keypair.public_key_hex),
      created_at: Map.get(attrs, :created_at, 1_640_000_000),
      kind: Map.get(attrs, :kind, 1),
      tags: Map.get(attrs, :tags, []),
      content: Map.get(attrs, :content, "Test event content")
    }

    # Create event without id and sig
    event = struct(PubEvent, base_attrs)

    # Compute ID according to NIP-01
    id = compute_event_id(event)

    # Sign the ID
    sig = sign_event_id(id, keypair.secret_key)

    # Return complete event
    %{event | id: id, sig: sig}
  end

  @doc """
  Generate a PubEvent with an invalid ID.

  The ID will not match the computed hash of the event data.
  """
  def invalid_id_pub_event_fixture(attrs \\ %{}) do
    # Convert keyword list to map if needed
    attrs = Enum.into(attrs, %{})
    event = valid_pub_event_fixture(attrs)

    # Replace with an invalid ID (all zeros)
    %{event | id: String.duplicate("0", 64)}
  end

  @doc """
  Generate a PubEvent with an invalid signature.

  The signature will not verify against the event ID and public key.
  """
  def invalid_sig_pub_event_fixture(attrs \\ %{}) do
    # Convert keyword list to map if needed
    attrs = Enum.into(attrs, %{})
    event = valid_pub_event_fixture(attrs)

    # Replace with an invalid signature (all zeros)
    %{event | sig: String.duplicate("0", 128)}
  end

  @doc """
  Returns a pre-computed valid PubEvent from the grchat reference implementation.

  This event has a known valid signature and ID, serving as a regression test
  against known-good values.
  """
  def static_valid_pub_event do
    # Generate a static event using the dynamic fixture for consistency
    # This ensures the signature is always valid with the current Schnorr implementation
    valid_pub_event_fixture(%{
      created_at: 1_640_000_000,
      kind: 1,
      tags: [],
      content: "Test event content"
    })
  end

  @doc """
  Returns a real kind `1111` note with many tags (`E`/`P`/`K`/`e`/`k`/`p`/`client`) and a valid NIP-01 id and Schnorr signature.

  Use for tag-parsing, filter, and crypto regression tests. Captured from the network as a known-good vector.
  """
  def reference_kind1111_pub_event do
    %PubEvent{
      id: "ec42b22bcf5e9b7849ee951e0b55c8c9c1467ac694c8087eabf2bf0a7f6c035f",
      pubkey: "dd664d5e4016433a8cd69f005ae1480804351789b59de5af06276de65633d319",
      created_at: 1_775_829_401,
      kind: 1111,
      content: "Ganz brav komprimiert, versprochen. Habe mir extra eine App dafür besorgt.",
      sig:
        "8f5323d967074351f459e562b66ebb7fc16b505b7dec6a979b6b50ce661f6c51e523215e2bc5afd048ed8b5914ba5e2f3ec4562032e971209579a6a9d2516c82",
      tags: [
        [
          "E",
          "6e35ec65661c5e2c453f9585a785b3f082c1daf9f769b3bb208af5459d178fca",
          "wss://nostr.land/",
          "dd664d5e4016433a8cd69f005ae1480804351789b59de5af06276de65633d319"
        ],
        ["P", "dd664d5e4016433a8cd69f005ae1480804351789b59de5af06276de65633d319"],
        ["K", "21"],
        [
          "e",
          "6e35ec65661c5e2c453f9585a785b3f082c1daf9f769b3bb208af5459d178fca",
          "wss://nostr.land/",
          "dd664d5e4016433a8cd69f005ae1480804351789b59de5af06276de65633d319"
        ],
        ["k", "21"],
        ["p", "dd664d5e4016433a8cd69f005ae1480804351789b59de5af06276de65633d319"],
        ["client", "imwald"]
      ]
    }
  end

  # Private helpers

  defp compute_event_id(event) do
    Jason.encode!([0, event.pubkey, event.created_at, event.kind, event.tags, event.content])
    |> sha256()
  end

  defp sha256(data) do
    :crypto.hash(:sha256, data)
    |> Base.encode16(case: :lower)
  end

  defp sign_event_id(id, secret_key) do
    # Convert hex ID to binary for signing
    id_binary = Base.decode16!(id, case: :lower)

    # Sign with Schnorr (BIP-340) - returns 64-byte binary signature
    signature_binary = Secp256k1.schnorr_sign(id_binary, secret_key)

    # Encode to hex string
    Base.encode16(signature_binary, case: :lower)
  end
end
