defmodule GcIndexRelay.Nostr.ValidatorTest do
  use ExUnit.Case, async: true

  alias GcIndexRelay.Nostr.Validator

  import GcIndexRelay.NostrFixtures

  @moduletag :unit

  describe "valid_hex_id?/1" do
    @valid_hex_ids [
      %{id: String.duplicate("a", 64), desc: "64-character lowercase hex"},
      %{
        id: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        desc: "mixed lowercase hex characters"
      }
    ]

    for %{id: id, desc: desc} <- @valid_hex_ids do
      test "returns true for valid #{desc}" do
        assert Validator.valid_hex_id?(unquote(id))
      end
    end

    @invalid_hex_ids [
      %{id: String.duplicate("A", 64), desc: "uppercase hex"},
      %{id: String.duplicate("a", 32), desc: "short hex string"},
      %{id: String.duplicate("a", 128), desc: "long hex string"},
      %{id: String.duplicate("z", 64), desc: "non-hex characters"},
      %{id: nil, desc: "nil"}
    ]

    for %{id: id, desc: desc} <- @invalid_hex_ids do
      test "returns false for #{desc}" do
        refute Validator.valid_hex_id?(unquote(Macro.escape(id)))
      end
    end

    @invalid_types [
      %{value: 123, desc: "integer"},
      %{value: [], desc: "empty list"}
    ]

    for %{value: value, desc: desc} <- @invalid_types do
      test "returns false for non-string type: #{desc}" do
        refute Validator.valid_hex_id?(unquote(Macro.escape(value)))
      end
    end
  end

  describe "validate_id/1" do
    test "returns {:ok, event} for valid event ID" do
      event = valid_pub_event_fixture()

      assert {:ok, ^event} = Validator.validate_id(event)
    end

    test "returns {:error, message} for semantically invalid event ID" do
      event = invalid_id_pub_event_fixture()

      assert {:error, message} = Validator.validate_id(event)
      assert message =~ "ID"
      assert message =~ "is invalid for the given event"
    end

    @invalid_id_formats [
      %{
        id: nil,
        desc: "nil id"
      },
      %{
        id: String.duplicate("z", 64),
        desc: "non-hex characters in id"
      },
      %{
        id: String.duplicate("a", 32),
        desc: "incorrect length id"
      },
      %{
        id: String.duplicate("A", 64),
        desc: "uppercase hex id"
      }
    ]

    for %{id: id, desc: desc} <- @invalid_id_formats do
      test "returns {:error, message} for #{desc}" do
        event = valid_pub_event_fixture()
        invalid_event = %{event | id: unquote(Macro.escape(id))}

        assert {:error, message} = Validator.validate_id(invalid_event)
        assert message =~ "invalid format"
        assert message =~ "64 lowercase hex characters"
      end
    end
  end

  describe "validate_signature/1" do
    test "returns {:ok, event} for valid signature" do
      event = valid_pub_event_fixture()

      assert {:ok, ^event} = Validator.validate_signature(event)
    end

    test "returns {:error, message} for invalid signature" do
      event = invalid_sig_pub_event_fixture()

      assert {:error, message} = Validator.validate_signature(event)
      assert message =~ "Signature"
      assert message =~ "is invalid"
    end

    test "returns {:error, message} for mismatched pubkey" do
      keypairs = test_keypairs()

      # Create event signed by keypair1
      event = valid_pub_event_fixture(keypair: :keypair1)

      # Replace pubkey with keypair2's pubkey (signature won't match)
      mismatched_event = %{event | pubkey: keypairs.keypair2.public_key_hex}

      assert {:error, message} = Validator.validate_signature(mismatched_event)
      assert message =~ "Signature"
      assert message =~ "is invalid"
    end

    @invalid_signature_formats [
      %{sig: nil, desc: "nil signature"},
      %{sig: String.duplicate("z", 128), desc: "non-hex characters in signature"},
      %{sig: String.duplicate("a", 32), desc: "incorrect length signature"}
    ]

    for %{sig: sig, desc: desc} <- @invalid_signature_formats do
      test "handles #{desc} gracefully" do
        event = valid_pub_event_fixture()
        invalid_event = %{event | sig: unquote(Macro.escape(sig))}

        assert {:error, _message} = Validator.validate_signature(invalid_event)
      end
    end
  end

  describe "validate_not_protected/1" do
    test "returns {:ok, event} for a normal event with no tags" do
      event = valid_pub_event_fixture()

      assert {:ok, ^event} = Validator.validate_not_protected(event)
    end

    test "returns {:ok, event} for an event with other tags but no protection tag" do
      event = valid_pub_event_fixture(tags: [["e", "abc123"], ["p", "def456"]])

      assert {:ok, ^event} = Validator.validate_not_protected(event)
    end

    test "returns {:error, message} for an event with the [\"-\"] protection tag" do
      event = valid_pub_event_fixture(tags: [["-"]])

      assert {:error, message} = Validator.validate_not_protected(event)
      assert message =~ "auth-required"
    end

    test "returns {:error, message} when [\"-\"] is mixed with other tags" do
      event = valid_pub_event_fixture(tags: [["e", "abc123"], ["-"], ["p", "def456"]])

      assert {:error, message} = Validator.validate_not_protected(event)
      assert message =~ "auth-required"
    end
  end

  describe "static reference test" do
    test "validates against known-good pre-computed event" do
      event = static_valid_pub_event()

      # Both ID and signature should validate
      assert {:ok, ^event} = Validator.validate_id(event)
      assert {:ok, ^event} = Validator.validate_signature(event)
    end

    test "validates real kind 1111 multi-tag reference event" do
      event = reference_kind1111_pub_event()

      assert {:ok, ^event} = Validator.validate_id(event)
      assert {:ok, ^event} = Validator.validate_signature(event)
    end
  end
end
