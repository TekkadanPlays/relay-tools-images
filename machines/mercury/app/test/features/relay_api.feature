Feature: Nostr Relay REST API
  As a Nostr client (e.g. Jumble at https://jumble.imwald.eu/)
  I want to interact with the relay over HTTP
  So that I can publish and query Nostr events

  Background:
    Given the relay is running at http://localhost:4000

  # ---------------------------------------------------------------------------
  # Discovery
  # ---------------------------------------------------------------------------

  Scenario: Client discovers available endpoints
    When the client sends GET /api
    Then the response status is 200
    And the response lists the available endpoints

  # ---------------------------------------------------------------------------
  # Publishing events
  # ---------------------------------------------------------------------------

  Scenario: Client publishes a valid kind 1 note
    Given a valid signed kind 1 event from keypair 1
    When the client sends POST /api/events with the event body
    Then the response status is 201 Created
    And the response body contains the published event

  Scenario: Client publishes a kind 0 profile event with metadata
    Given a valid signed kind 0 event containing a JSON metadata content field
    When the client sends POST /api/events with the event body
    Then the response status is 201 Created

  Scenario: Relay rejects a duplicate event
    Given a valid signed event has already been published
    When the client sends POST /api/events with the same event again
    Then the response status is 409 Conflict

  Scenario: Relay rejects an event with an invalid ID
    Given a signed event whose ID does not match the hash of its content
    When the client sends POST /api/events with the event body
    Then the response status is 400 Bad Request

  Scenario: Relay rejects a NIP-70 protected event
    Given a valid signed event with a ["-"] protection tag
    When the client sends POST /api/events with the event body
    Then the response status is 400 Bad Request
    And the response error contains "auth-required"

  # ---------------------------------------------------------------------------
  # Deleting events (DELETE /api/events/:id)
  # ---------------------------------------------------------------------------

  Scenario: Client deletes an existing event by ID
    Given a known event has been published
    When the client sends DELETE /api/events/<event_id>
    Then the response status is 204 No Content

  Scenario: Deleting a non-existent event returns 404
    When the client sends DELETE /api/events/<unknown_id>
    Then the response status is 404 Not Found

  # ---------------------------------------------------------------------------
  # Fetching events (GET /api/events — cacheable, requires since/until/limit)
  # ---------------------------------------------------------------------------

  Scenario: Client fetches events using time-bounded query params
    Given two kind 1 notes have been published
    When the client sends GET /api/events?since=0&until=9999999999&limit=10
    Then the response status is 200
    And the response contains both kind 1 events

  Scenario: GET /api/events without required params is rejected
    When the client sends GET /api/events without "since", "until", or "limit"
    Then the response status is 400 Bad Request

  # ---------------------------------------------------------------------------
  # Fetching events (POST /api/events/filter — what most Nostr clients use)
  # ---------------------------------------------------------------------------

  Scenario: Client fetches recent notes (kind 1)
    Given two kind 1 notes have been published
    When the client sends POST /api/events/filter with body {"kinds": [1], "limit": 10}
    Then the response status is 200
    And the response contains both kind 1 events
    And events are ordered newest first

  Scenario: Client fetches a user profile (kind 0)
    Given a kind 0 profile event has been published for keypair 1
    When the client sends POST /api/events/filter with body {"kinds": [0], "authors": ["<pubkey1>"], "limit": 1}
    Then the response status is 200
    And the response contains exactly 1 event
    And the event kind is 0

  Scenario: Client fetches events mentioning a specific pubkey (#p tag)
    Given an event tagged with ["p", "<some pubkey>"] has been published
    When the client sends POST /api/events/filter with body {"#p": ["<some pubkey>"], "limit": 10}
    Then the response status is 200
    And the response contains the tagged event

  Scenario: Client fetches events within a time window
    Given two events with different created_at timestamps exist
    When the client sends POST /api/events/filter with a "since" before the newer event
    Then only the newer event is returned

  Scenario: Filter without a limit is rejected
    When the client sends POST /api/events/filter with body {"kinds": [1]}
    Then the response status is 400 Bad Request

  Scenario: Filter with a limit over 100 is rejected
    When the client sends POST /api/events/filter with body {"limit": 101}
    Then the response status is 400 Bad Request

  # ---------------------------------------------------------------------------
  # Fetching a single event by ID (GET /api/events/:id)
  # ---------------------------------------------------------------------------

  Scenario: Client fetches a specific event by ID
    Given a known event has been published
    When the client sends GET /api/events/<event_id>
    Then the response status is 200
    And the response body contains the correct event

  Scenario: Fetching a non-existent event returns 404
    When the client sends GET /api/events/<unknown_id>
    Then the response status is 404 Not Found

  # ---------------------------------------------------------------------------
  # CORS — required for browser-based clients like Jumble
  # ---------------------------------------------------------------------------

  Scenario: Relay includes CORS headers on API responses
    When the client sends any request to the API
    Then the response includes "Access-Control-Allow-Origin: *"
    And the response includes "Access-Control-Allow-Methods" listing GET, POST, DELETE, OPTIONS

  Scenario: Relay handles a browser preflight OPTIONS request
    When the client sends OPTIONS /api/events
    Then the response status is 200
    And the response includes CORS headers
    And the response body is empty

  # ---------------------------------------------------------------------------
  # NIP-11 relay information document
  # ---------------------------------------------------------------------------

  Scenario: Client requests NIP-11 relay info
    When the client sends GET / with header "Accept: application/nostr+json"
    Then the response status is 200
    And the response content-type is "application/nostr+json"
    And the response includes a "name" field
    And the response includes a "supported_nips" array
    And the response includes a "limitation" object
    And the response includes an "icon" field with a URL

  Scenario: NIP-11 response includes correct CORS headers
    When the client sends GET / with header "Accept: application/nostr+json"
    Then the response includes "Access-Control-Allow-Origin: *"

  Scenario: Regular browser request to GET / still serves the HTML page
    When the client sends GET / with header "Accept: text/html"
    Then the response status is 200
    And the response content-type contains "text/html"

  # ---------------------------------------------------------------------------
  # Health check
  # ---------------------------------------------------------------------------

  Scenario: Health check returns OK
    When the client sends GET /health
    Then the response status is 200
