#!/usr/bin/bash
# Ergo channel management helper
# Used by Mycelium Live to create/destroy per-stream IRC channels
# Usage:
#   channel-mgmt.sh create <channel> [topic]
#   channel-mgmt.sh destroy <channel>
#   channel-mgmt.sh topic <channel> <topic>
#
# Requires the oper password to be set in ERGO_OPER_PASS env var
# Connects to Ergo on localhost:6667 via netcat

ERGO_HOST="${ERGO_HOST:-127.0.0.1}"
ERGO_PORT="${ERGO_PORT:-6667}"
OPER_USER="${ERGO_OPER_USER:-admin}"
OPER_PASS="${ERGO_OPER_PASS:-}"

ACTION="$1"
CHANNEL="$2"
TOPIC="$3"

if [ -z "$ACTION" ] || [ -z "$CHANNEL" ]; then
    echo "Usage: $0 <create|destroy|topic> <channel> [topic]"
    exit 1
fi

if [ -z "$OPER_PASS" ]; then
    echo "Error: ERGO_OPER_PASS env var not set"
    exit 1
fi

# Ensure channel starts with #
if [[ "$CHANNEL" != \#* ]]; then
    CHANNEL="#$CHANNEL"
fi

send_irc() {
    # Send IRC commands via netcat with a brief delay for processing
    {
        echo "NICK ChannelBot"
        echo "USER channelbot 0 * :Channel Manager"
        sleep 0.5
        echo "OPER $OPER_USER $OPER_PASS"
        sleep 0.3

        case "$ACTION" in
            create)
                echo "JOIN $CHANNEL"
                sleep 0.2
                if [ -n "$TOPIC" ]; then
                    echo "TOPIC $CHANNEL :$TOPIC"
                    sleep 0.1
                fi
                # Set channel modes: +ntC (no external messages, topic lock, no CTCP)
                echo "MODE $CHANNEL +ntC"
                sleep 0.1
                echo "PART $CHANNEL"
                ;;
            destroy)
                echo "JOIN $CHANNEL"
                sleep 0.2
                echo "TOPIC $CHANNEL :Stream ended"
                sleep 0.1
                # Kick all users and set invite-only to effectively close it
                echo "MODE $CHANNEL +i"
                sleep 0.1
                echo "PART $CHANNEL"
                ;;
            topic)
                echo "JOIN $CHANNEL"
                sleep 0.2
                echo "TOPIC $CHANNEL :$TOPIC"
                sleep 0.1
                echo "PART $CHANNEL"
                ;;
        esac

        sleep 0.2
        echo "QUIT :Done"
    } | nc -q 2 "$ERGO_HOST" "$ERGO_PORT"
}

send_irc
echo "[$ACTION] $CHANNEL — done"
