require "test_helper"
require "ostruct"

class TestProvider < Provider
  TestError = Class.new(StandardError)

  def initialize(client)
    @client = client
  end

  def fetch_data
    with_provider_response do
      @client.get("/test")
    end
  end

  def fetch_data_with_error_transformer
    with_provider_response(error_transformer: ->(error) { TestError.new(error.message) }) do
      @client.get("/test")
    end
  end
end

class ProviderTest < ActiveSupport::TestCase
  setup do
    @client = mock
    @provider = TestProvider.new(@client)
  end

  test "returns success response with data" do
    @client.expects(:get).with("/test").returns({ some: "data" })

    response = @provider.fetch_data

    assert response.success?
    assert_equal({ some: "data" }, response.data)
  end

  test "returns failed response with error" do
    @client.expects(:get).with("/test").raises(StandardError.new("some error"))

    response = @provider.fetch_data

    assert_not response.success?
    assert_equal("some error", response.error.message)
  end

  test "provider can transform error" do
    @client.expects(:get).with("/test").raises(StandardError.new("some error"))

    response = @provider.fetch_data_with_error_transformer

    assert_not response.success?
    assert_equal("some error", response.error.message)
    assert_instance_of TestProvider::TestError, response.error
  end

  test "default_error_transformer preserves the failure_code when present" do
    source = Provider::Error.new("render failed", failure_code: :render_missing_binary)

    transformed = @provider.send(:default_error_transformer, source)

    assert_equal :render_missing_binary, transformed.failure_code
  end

  test "default_error_transformer drops a nil failure_code instead of passing it" do
    source = Provider::Error.new("render failed")

    transformed = @provider.send(:default_error_transformer, source)

    assert_nil transformed.failure_code
  end

  test "default_error_transformer preserves failure_code and response body for Faraday errors" do
    source = Faraday::ConnectionFailed.new("upstream failed")
    source.define_singleton_method(:failure_code) { :render_missing_binary }

    transformed = @provider.send(:default_error_transformer, source)

    assert_instance_of TestProvider::Error, transformed
    assert_equal "upstream failed", transformed.message
    assert_equal :render_missing_binary, transformed.failure_code
  end

  test "default_error_transformer extracts the response body into details for Faraday errors" do
    source = Faraday::ConnectionFailed.new("upstream failed")
    source.define_singleton_method(:response) { { body: { "error" => { "code" => "bad_pdf" } } } }

    transformed = @provider.send(:default_error_transformer, source)

    assert_equal({ "error" => { "code" => "bad_pdf" } }, transformed.details)
    assert_nil transformed.failure_code
  end

  test "default_error_transformer marks upstream outages, timeouts and dropped connections as transient" do
    transient_sources = [
      Faraday::ServerError.new("the server responded with status 502", { status: 502, body: "" }),
      Faraday::TimeoutError.new("timed out"),
      Faraday::ConnectionFailed.new("connection refused"),
      Net::ReadTimeout.new("read timeout"),
      Errno::ECONNRESET.new,
      Anthropic::Errors::APIConnectionError.new(url: URI("https://api.anthropic.com")),
      Anthropic::Errors::APITimeoutError.new(url: URI("https://api.anthropic.com")),
      Anthropic::Errors::InternalServerError.new(url: URI("https://api.anthropic.com"), status: 529, headers: {}, body: nil, request: nil, response: nil),
      Anthropic::Errors::RateLimitError.new(url: URI("https://api.anthropic.com"), status: 429, headers: {}, body: nil, request: nil, response: nil),
      Faraday::TooManyRequestsError.new("the server responded with status 429", { status: 429, body: { "error" => { "code" => "rate_limit_exceeded" } } }),
      Provider::Error.new("Could not parse JSON from response", transient: true)
    ]

    transient_sources.each do |source|
      transformed = @provider.send(:default_error_transformer, source)
      assert transformed.transient?, "expected #{source.class} to be transient"
    end
  end

  test "default_error_transformer leaves configuration, auth, quota and validation failures permanent" do
    permanent_sources = [
      Faraday::UnauthorizedError.new("the server responded with status 401", { status: 401, body: "" }),
      Faraday::ResourceNotFound.new("the server responded with status 404", { status: 404, body: "" }),
      Faraday::TooManyRequestsError.new("the server responded with status 429", { status: 429, body: { "error" => { "code" => "insufficient_quota" } } }),
      Faraday::BadRequestError.new("the server responded with status 400", { status: 400, body: "" }),
      Anthropic::Errors::AuthenticationError.new(url: URI("https://api.anthropic.com"), status: 401, headers: {}, body: nil, request: nil, response: nil),
      Anthropic::Errors::NotFoundError.new(url: URI("https://api.anthropic.com"), status: 404, headers: {}, body: nil, request: nil, response: nil),
      Provider::Error.new("No categories available for auto-categorization"),
      Provider::Error.new("Too many transactions to auto-categorize. Max is 25 per request."),
      ArgumentError.new("bad argument")
    ]

    permanent_sources.each do |source|
      transformed = @provider.send(:default_error_transformer, source)
      assert_not transformed.transient?, "expected #{source.class} to be permanent"
    end
  end

  test "with_provider_response reports a failed upstream call as transient" do
    @client.expects(:get).with("/test").raises(Faraday::ServerError.new("the server responded with status 503", { status: 503, body: "" }))

    response = @provider.fetch_data

    assert_not response.success?
    assert response.error.transient?
  end

  test "Error#as_json includes the failure_code" do
    error = Provider::Error.new("render failed", details: { hint: "install poppler-utils" }, failure_code: :render_missing_binary)

    assert_equal(
      { message: "render failed", details: { hint: "install poppler-utils" }, failure_code: :render_missing_binary },
      error.as_json
    )

    plain = Provider::Error.new("boom")
    assert_nil plain.as_json[:failure_code]
  end
end
