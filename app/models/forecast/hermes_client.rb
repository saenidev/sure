module Forecast
  # Thin client for the external Hermes planning agent.
  #
  # STUBBED BOUNDARY: the actual network round-trip (POST the packet, await the
  # agent's response_packet) is intentionally NOT implemented in this slice. The
  # external send/receive is the excluded boundary so Hermes drafts never
  # auto-flow into the app without human approval.
  #
  # In the absence of a configured endpoint (the default), `submit` raises
  # `Forecast::HermesClient::NotConfigured`. The controller catches this and
  # renders a graceful "Hermes is not configured" notice rather than a 500, so
  # the rest of the review workflow (deterministic facts, manual status
  # transitions, draft approval of any already-stored response_packet) keeps
  # working with the external integration switched off.
  #
  # An operator wires Hermes up by setting the endpoint
  # (Rails.configuration.x.forecast.hermes_endpoint via FORECAST_HERMES_ENDPOINT)
  # and replacing the `perform_request` stub with a real HTTP call.
  class HermesClient
    # Raised when no Hermes endpoint is configured. Carries a human message the
    # controller surfaces via i18n.
    class NotConfigured < StandardError; end

    # Raised when a configured endpoint exists but the request fails. Present so
    # the eventual real implementation has a typed failure the UI can handle the
    # same graceful way; the stub never reaches this today.
    class RequestFailed < StandardError; end

    def self.configured?
      endpoint.present?
    end

    def self.endpoint
      config = Rails.configuration.x.forecast
      config.respond_to?(:hermes_endpoint) ? config.hermes_endpoint.presence : nil
    end

    def initialize(endpoint: self.class.endpoint)
      @endpoint = endpoint.presence
    end

    def configured?
      @endpoint.present?
    end

    # Submit a packet (the Hash from Forecast::PacketBuilder) to Hermes and
    # return the parsed response_packet Hash.
    #
    # STUB: with no endpoint configured this raises NotConfigured immediately —
    # nothing is sent. This is the excluded external boundary; the method exists
    # so the call site is real and tested, while the round-trip is deliberately
    # absent.
    def submit(packet)
      raise NotConfigured, "Hermes endpoint is not configured" unless configured?

      perform_request(packet)
    end

    private
      attr_reader :endpoint

      # STUBBED: the real implementation would POST `packet` to `endpoint` and
      # parse the agent's response_packet. Left unimplemented on purpose so the
      # external round-trip is not silently faked. Reaching here without a real
      # implementation raises RequestFailed (only possible once an endpoint is
      # configured, which the default never is).
      def perform_request(_packet)
        raise RequestFailed, "Hermes request transport is not implemented in this build"
      end
  end
end
