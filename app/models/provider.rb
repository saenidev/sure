class Provider
  Response = Data.define(:success?, :data, :error)

  class Error < StandardError
    attr_reader :details, :failure_code

    # Builds a provider error. `details` holds opaque response metadata
    # (e.g. the upstream body); `failure_code` is an optional symbol the
    # admin AI status page and health probe key on so they can show a
    # specific, actionable reason instead of a generic message. `transient`
    # marks a failure that may succeed if the same call is repeated later
    # (upstream outage, timeout, dropped connection, garbled model output), so
    # callers can retry it instead of failing outright.
    def initialize(message, details: nil, failure_code: nil, transient: false)
      super(message)
      @details = details
      @failure_code = failure_code
      @transient = transient
    end

    def transient?
      @transient
    end

    # Serialized form for API consumers. Includes `failure_code` so
    # downstream UI can branch on the reason rather than the message text.
    def as_json
      {
        message: message,
        details: details,
        failure_code: failure_code
      }
    end
  end

  private
    PaginatedData = Data.define(:paginated, :first_page, :total_pages)
    UsageData = Data.define(:used, :limit, :utilization, :plan)

    def with_provider_response(error_transformer: nil, &block)
      data = yield

      Response.new(
        success?: true,
        data: data,
        error: nil,
      )
    rescue => error
      transformed_error = if error_transformer
        error_transformer.call(error)
      else
        default_error_transformer(error)
      end

      Response.new(
        success?: false,
        data: nil,
        error: transformed_error
      )
    end

    # Fallback transformation applied by `with_provider_response` when no
    # `error_transformer:` is given. Re-wraps an arbitrary rescue into a
    # `self.class::Error`, carrying over the error's `failure_code` (when
    # present and truthy) and, for Faraday errors, the response body as
    # `details`. Subclasses may override this to customise.
    def default_error_transformer(error)
      kwargs = if error.respond_to?(:failure_code) && error.failure_code
        { failure_code: error.failure_code }
      else
        {}
      end
      kwargs[:transient] = true if transient_error?(error)

      if error.is_a?(Faraday::Error)
        self.class::Error.new(
          error.message,
          details: error.response&.dig(:body),
          **kwargs
        )
      else
        self.class::Error.new(error.message, **kwargs)
      end
    end

    NETWORK_ERRORS = [
      Timeout::Error,
      SocketError,
      EOFError,
      Errno::ECONNRESET,
      Errno::ECONNREFUSED,
      Errno::ETIMEDOUT,
      Errno::EHOSTUNREACH,
      Errno::ENETUNREACH,
      Errno::EPIPE
    ].freeze

    # Whether repeating the same call later could succeed. Classified from the
    # exception type and HTTP status rather than the message: upstream 5xx,
    # timeouts, dropped connections and short-term rate limits are transient;
    # auth, not-found, bad-request and exhausted-quota responses fail the same
    # way on every retry.
    def transient_error?(error)
      return error.transient? if error.respond_to?(:transient?)

      case error
      when *NETWORK_ERRORS, Faraday::ServerError, Faraday::ConnectionFailed, Faraday::RequestTimeoutError
        true
      when Faraday::TooManyRequestsError
        !quota_exhausted?(error.response&.dig(:body))
      else
        anthropic_transient_error?(error)
      end
    end

    # OpenAI answers both a per-minute rate limit and an exhausted billing
    # quota with 429; only the rate limit clears on its own.
    def quota_exhausted?(body)
      body = JSON.parse(body) if body.is_a?(String) && body.present?
      return false unless body.is_a?(Hash)

      error = body["error"] || body[:error]
      return false unless error.is_a?(Hash)

      [ error["code"], error[:code], error["type"], error[:type] ].compact.map(&:to_s).include?("insufficient_quota")
    rescue JSON::ParserError
      false
    end

    # The anthropic gem raises its own error hierarchy rather than Faraday's.
    def anthropic_transient_error?(error)
      return false unless defined?(::Anthropic::Errors::APIError)

      case error
      when ::Anthropic::Errors::APIConnectionError, ::Anthropic::Errors::InternalServerError, ::Anthropic::Errors::RateLimitError
        true
      else
        false
      end
    end
end
