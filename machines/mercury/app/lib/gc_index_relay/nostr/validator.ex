defmodule GcIndexRelay.Nostr.Validator do
  @moduledoc """
  Nostr key and signature validation.

  Uses [lib_secp256k1](https://hexdocs.pm/lib_secp256k1/) for Schnorr signature verification (BIP-340).

  Will migrate to [noscrypt](https://www.vaughnnugent.com/resources/software/modules/noscrypt) (via
  NIF integration) at a later date.
  """

  alias GcIndexRelay.Nostr.PubEvent

  @doc """
  Validates that a string is exactly 64 lowercase hexadecimal characters.

  This is used for Nostr event IDs and public keys (schnorr pubkeys).

  ## Examples

      iex> Validator.valid_hex_id?("a" |> String.duplicate(64))
      true

      iex> Validator.valid_hex_id?("A" |> String.duplicate(64))
      false

      iex> Validator.valid_hex_id?("abc")
      false
  """
  @spec valid_hex_id?(any()) :: boolean()
  def valid_hex_id?(id) when is_binary(id) do
    String.length(id) == 64 and String.match?(id, ~r/^[0-9a-f]{64}$/)
  end

  def valid_hex_id?(_), do: false

  @doc """
  Validates a Nostr event ID per [NIP-01](https://github.com/nostr-protocol/nips/blob/master/01.md).

  Performs two checks:
  1. Format validation - ensures ID is 64 lowercase hex characters
  2. Semantic validation - ensures ID matches the computed hash of event data
  """
  def validate_id(event) when is_struct(event, PubEvent) do
    cond do
      !valid_hex_id?(event.id) ->
        {:error, "ID #{event.id} has invalid format (must be 64 lowercase hex characters)"}

      !valid_id?(event) ->
        {:error, "ID #{event.id} is invalid for the given event"}

      true ->
        {:ok, event}
    end
  end

  defp valid_id?(event) when is_struct(event, PubEvent) do
    computed_id = compute_id!(event)
    event.id == computed_id
  end

  @doc """
  Rejects protected events per [NIP-70](https://github.com/nostr-protocol/nips/blob/master/70.md).

  An event containing the `["-"]` tag is considered protected and may only be
  published by its author after completing the NIP-42 AUTH flow. Since this relay
  does not implement NIP-42, protected events are rejected outright.
  """
  def validate_not_protected(event) when is_struct(event, PubEvent) do
    if Enum.member?(event.tags, ["-"]) do
      {:error, "auth-required: this event may only be published by its author"}
    else
      {:ok, event}
    end
  end

  @doc """
  Validates a Nostr event signature per [NIP-01](https://github.com/nostr-protocol/nips/blob/master/01.md).
  """
  def validate_signature(event) when is_struct(event, PubEvent) do
    if valid_signature?(event),
      do: {:ok, event},
      else: {:error, "Signature #{event.sig} is invalid for the given event"}
  end

  defp valid_signature?(event) when is_struct(event, PubEvent) do
    with true <- is_binary(event.sig) and is_binary(event.pubkey),
         {:ok, binary_signature} <- decode_hex(event.sig),
         {:ok, binary_pubkey} <- decode_hex(event.pubkey),
         {:ok, binary_event_data} <- decode_hex(compute_id!(event)) do
      # Use Schnorr signature verification (BIP-340)
      # Wrap in try/rescue since Secp256k1.schnorr_valid? raises on invalid input
      try do
        Secp256k1.schnorr_valid?(binary_signature, binary_event_data, binary_pubkey)
      rescue
        _ -> false
      end
    else
      _ -> false
    end
  end

  defp decode_hex(hex_string) when is_binary(hex_string) do
    case Base.decode16(hex_string, case: :lower) do
      {:ok, _} = result -> result
      :error -> {:error, :invalid_hex}
    end
  end

  defp decode_hex(_), do: {:error, :invalid_input}

  defp compute_id!(event) when is_struct(event, PubEvent) do
    Jason.encode!([0, event.pubkey, event.created_at, event.kind, event.tags, event.content])
    |> sha256(:lowercase_hex)
  end

  defp sha256(data, :binary = output_type) when is_binary(data) and is_atom(output_type),
    do: :crypto.hash(:sha256, data)

  defp sha256(data, :lowercase_hex = output_type) when is_binary(data) and is_atom(output_type) do
    sha256(data, :binary)
    |> Base.encode16(case: :lower)
  end
end
