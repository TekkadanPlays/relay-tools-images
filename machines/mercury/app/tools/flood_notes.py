#!/usr/bin/env python3
"""
Mercury Relay Note Flood Tool
==============================

Generates and publishes signed Nostr kind-1 text notes to a Mercury relay
instance via its REST API. Useful for populating a fresh instance with test
data so the Android client has content to display.

Usage:
    python flood_notes.py [OPTIONS]

Options:
    --url URL          Mercury API base URL (default: https://api.mycelium.social)
    --count N          Number of notes to generate (default: 50)
    --community ATAG   Optional community aTag to attach to all notes
    --privkey HEX      Private key hex (generates a random one if omitted)
    --delay MS         Delay between publishes in ms (default: 100)
    --clear            Delete all events before flooding (admin)
    --dry-run          Print events without publishing

Requirements:
    pip install secp256k1 requests

The script generates realistic-looking social media posts with varied
content, hashtags, and timestamps spread across the last 24 hours.
"""

import argparse
import hashlib
import json
import os
import random
import secrets
import struct
import sys
import time
from datetime import datetime, timedelta

try:
    import requests
except ImportError:
    print("ERROR: 'requests' package required. Run: pip install requests")
    sys.exit(1)

try:
    import secp256k1
except ImportError:
    secp256k1 = None
    print("WARNING: 'secp256k1' not available. Trying fallback signing...")

# ── Content templates ──────────────────────────────────────────────────

CONTENT_TEMPLATES = [
    "Just discovered {topic}. This changes everything! 🔥",
    "Has anyone tried {topic}? I'm curious about the community's experience.",
    "Thoughts on {topic}? I think it's underrated.",
    "Building something cool with {topic}. Stay tuned for updates!",
    "The future of social media is decentralized. {topic} is proof.",
    "Morning coffee and {topic}. Perfect start to the day. ☕",
    "Hot take: {topic} will be more important than most people think.",
    "Learning about {topic} today. The rabbit hole goes deep.",
    "Can't believe how fast {topic} is evolving. Wild times.",
    "If you're not paying attention to {topic}, you're missing out.",
    "Thread: Why {topic} matters for the open web 🧵",
    "Just shipped a new feature related to {topic}! Feedback welcome.",
    "{topic} + open protocols = freedom. Simple as that.",
    "Debating {topic} with friends. Interesting perspectives all around.",
    "The {topic} community is one of the best I've been part of.",
    "New blog post about {topic} dropping soon. Here's a preview...",
    "Reminder: {topic} exists and it's awesome.",
    "What's your unpopular opinion about {topic}?",
    "TIL something fascinating about {topic}.",
    "Celebrating a milestone with {topic} today! 🎉",
    "Quick question about {topic} — anyone have experience with this?",
    "The intersection of {topic} and privacy is fascinating.",
    "Nostr is the protocol, {topic} is the application. Both matter.",
    "Spent the weekend deep-diving into {topic}. Mind = blown. 🤯",
    "Pro tip: combine {topic} with self-hosting for maximum sovereignty.",
    "The {topic} ecosystem is growing faster than I expected.",
    "Grateful for the {topic} community. You all are amazing. 💜",
    "Prediction: {topic} will go mainstream within 2 years.",
    "Open source + {topic} = unstoppable. Change my mind.",
    "AMA about {topic}. Drop your questions below! 👇",
]

TOPICS = [
    "Nostr", "Bitcoin", "Lightning Network", "decentralized social",
    "relay architecture", "NIP-65", "outbox model", "zaps",
    "content moderation", "community governance", "federation",
    "self-hosting", "privacy tools", "open protocols", "mesh networking",
    "Mycelium", "Mercury relay", "event sourcing", "Elixir",
    "Kotlin", "Compose UI", "Android development", "WebSockets",
    "REST APIs", "distributed systems", "peer-to-peer",
    "digital sovereignty", "cryptography", "key management",
    "censorship resistance",
]

HASHTAGS = [
    "#nostr", "#bitcoin", "#decentralized", "#opensource", "#privacy",
    "#selfhost", "#relay", "#zap", "#community", "#mycelium",
    "#dev", "#building", "#freedom", "#protocol", "#federation",
]


def generate_content():
    """Generate a random note content string."""
    template = random.choice(CONTENT_TEMPLATES)
    topic = random.choice(TOPICS)
    content = template.format(topic=topic)

    # Randomly append 1-3 hashtags
    if random.random() > 0.4:
        tags = random.sample(HASHTAGS, min(random.randint(1, 3), len(HASHTAGS)))
        content += "\n\n" + " ".join(tags)

    return content


def sha256(data: bytes) -> bytes:
    return hashlib.sha256(data).digest()


def serialize_event(pubkey: str, created_at: int, kind: int,
                    tags: list, content: str) -> str:
    """NIP-01 canonical serialization for event ID computation."""
    return json.dumps(
        [0, pubkey, created_at, kind, tags, content],
        separators=(",", ":"),
        ensure_ascii=False,
    )


def compute_event_id(pubkey: str, created_at: int, kind: int,
                     tags: list, content: str) -> str:
    serialized = serialize_event(pubkey, created_at, kind, tags, content)
    return sha256(serialized.encode("utf-8")).hex()


def sign_event_secp256k1(event_id_hex: str, privkey_hex: str) -> str:
    """Sign with the secp256k1 library (Schnorr/BIP-340)."""
    privkey = secp256k1.PrivateKey(bytes.fromhex(privkey_hex))
    msg = bytes.fromhex(event_id_hex)
    sig = privkey.schnorr_sign(msg, bip340tag=None, raw=True)
    return sig.hex()


def sign_event_fallback(event_id_hex: str, privkey_hex: str) -> str:
    """
    Fallback: try using coincurve for Schnorr signing.
    """
    try:
        from coincurve import PrivateKey as CPrivateKey
        pk = CPrivateKey(bytes.fromhex(privkey_hex))
        sig = pk.sign_schnorr(bytes.fromhex(event_id_hex))
        return sig.hex()
    except ImportError:
        pass

    # Last resort: generate a dummy signature (won't verify but
    # allows testing the API pipeline if sig validation is off)
    print("WARNING: No signing library available. Using dummy signatures.")
    print("         Events will NOT pass signature verification.")
    print("         Install: pip install secp256k1  OR  pip install coincurve")
    return "0" * 128


def sign_event(event_id_hex: str, privkey_hex: str) -> str:
    if secp256k1 is not None:
        return sign_event_secp256k1(event_id_hex, privkey_hex)
    return sign_event_fallback(event_id_hex, privkey_hex)


def privkey_to_pubkey(privkey_hex: str) -> str:
    """Derive the x-only public key from a private key."""
    if secp256k1 is not None:
        pk = secp256k1.PrivateKey(bytes.fromhex(privkey_hex))
        # x-only pubkey = last 32 bytes of the 33-byte compressed key
        compressed = pk.pubkey.serialize(compressed=True)
        return compressed[1:].hex()

    try:
        from coincurve import PrivateKey as CPrivateKey
        pk = CPrivateKey(bytes.fromhex(privkey_hex))
        pub = pk.public_key.format(compressed=True)
        return pub[1:].hex()
    except ImportError:
        pass

    # Fallback: random pubkey (for testing only)
    print("WARNING: Cannot derive pubkey. Using random hex.")
    return secrets.token_hex(32)


def create_event(privkey_hex: str, pubkey_hex: str, content: str,
                 kind: int = 1, tags: list = None,
                 created_at: int = None) -> dict:
    """Create a fully signed Nostr event."""
    if tags is None:
        tags = []
    if created_at is None:
        created_at = int(time.time())

    event_id = compute_event_id(pubkey_hex, created_at, kind, tags, content)
    sig = sign_event(event_id, privkey_hex)

    return {
        "id": event_id,
        "pubkey": pubkey_hex,
        "created_at": created_at,
        "kind": kind,
        "tags": tags,
        "content": content,
        "sig": sig,
    }


def publish_event(base_url: str, event: dict) -> bool:
    """Publish a signed event to the Mercury REST API."""
    url = f"{base_url}/api/events"
    payload = {"event": event}
    try:
        resp = requests.post(url, json=payload, timeout=10)
        if resp.status_code in (200, 201):
            return True
        else:
            print(f"  FAIL [{resp.status_code}]: {resp.text[:200]}")
            return False
    except Exception as e:
        print(f"  ERROR: {e}")
        return False


def delete_all_events(base_url: str) -> bool:
    """
    Delete all events from the Mercury relay.
    Uses the filter endpoint to fetch all event IDs, then DELETE each one.
    """
    print("Fetching all events for deletion...")
    try:
        resp = requests.post(
            f"{base_url}/api/events/filter",
            json={"limit": 10000},
            timeout=30,
        )
        if resp.status_code != 200:
            print(f"Failed to fetch events: {resp.status_code}")
            return False

        data = resp.json()
        events = data if isinstance(data, list) else data.get("data", [])
        print(f"Found {len(events)} events to delete.")

        deleted = 0
        for ev in events:
            eid = ev.get("id") or ev.get("event_id")
            if eid:
                del_resp = requests.delete(
                    f"{base_url}/api/events/{eid}", timeout=10
                )
                if del_resp.status_code in (200, 204):
                    deleted += 1
                else:
                    print(f"  Failed to delete {eid[:16]}...: {del_resp.status_code}")

        print(f"Deleted {deleted}/{len(events)} events.")
        return True
    except Exception as e:
        print(f"Error during deletion: {e}")
        return False


def main():
    parser = argparse.ArgumentParser(
        description="Flood a Mercury relay with test notes"
    )
    parser.add_argument(
        "--url", default="https://api.mycelium.social",
        help="Mercury API base URL"
    )
    parser.add_argument(
        "--count", type=int, default=50,
        help="Number of notes to generate"
    )
    parser.add_argument(
        "--community",
        help="Community aTag to attach (e.g. '34550:<pubkey>:<id>')"
    )
    parser.add_argument(
        "--privkey",
        help="Private key hex (random if omitted)"
    )
    parser.add_argument(
        "--delay", type=int, default=100,
        help="Delay between publishes in milliseconds"
    )
    parser.add_argument(
        "--clear", action="store_true",
        help="Delete all events before flooding"
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Print events without publishing"
    )
    parser.add_argument(
        "--spread-hours", type=int, default=24,
        help="Spread timestamps across this many hours (default: 24)"
    )

    args = parser.parse_args()

    # Key setup
    privkey = args.privkey or secrets.token_hex(32)
    pubkey = privkey_to_pubkey(privkey)

    print(f"╔══════════════════════════════════════════╗")
    print(f"║  Mercury Relay Note Flood Tool           ║")
    print(f"╚══════════════════════════════════════════╝")
    print(f"  URL:       {args.url}")
    print(f"  Count:     {args.count}")
    print(f"  Pubkey:    {pubkey[:16]}...")
    print(f"  Community: {args.community or '(none)'}")
    print(f"  Spread:    {args.spread_hours}h")
    print()

    # Clear if requested
    if args.clear:
        delete_all_events(args.url)
        print()

    # Generate and publish
    now = int(time.time())
    spread_sec = args.spread_hours * 3600
    success = 0
    fail = 0

    for i in range(args.count):
        content = generate_content()

        # Spread timestamps across the configured window
        offset = random.randint(0, spread_sec)
        created_at = now - offset

        # Build tags
        tags = []
        if args.community:
            tags.append(["a", args.community])

        event = create_event(
            privkey_hex=privkey,
            pubkey_hex=pubkey,
            content=content,
            kind=1,
            tags=tags,
            created_at=created_at,
        )

        ts = datetime.fromtimestamp(created_at).strftime("%H:%M:%S")
        preview = content[:60].replace("\n", " ")

        if args.dry_run:
            print(f"  [{i+1:3d}/{args.count}] {ts} | {preview}...")
        else:
            ok = publish_event(args.url, event)
            if ok:
                success += 1
                print(f"  ✓ [{i+1:3d}/{args.count}] {ts} | {preview}...")
            else:
                fail += 1

            if args.delay > 0 and i < args.count - 1:
                time.sleep(args.delay / 1000.0)

    print()
    if args.dry_run:
        print(f"Dry run complete. {args.count} events generated (not published).")
    else:
        print(f"Done! Published: {success}, Failed: {fail}")

    if not args.privkey:
        print(f"\n  Generated privkey (save if you want to reuse this identity):")
        print(f"  {privkey}")


if __name__ == "__main__":
    main()
