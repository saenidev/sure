require "test_helper"

class PwaControllerTest < ActionDispatch::IntegrationTest
  test "manifest responds successfully for html accept headers" do
    get "/manifest", headers: { "Accept" => "text/html" }

    assert_response :success
    assert_equal "application/manifest+json", response.media_type
    assert_includes response.body, '"start_url": "/"'
  end

  test "service worker responds successfully with forgery protection enabled" do
    previous_forgery_setting = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true

    get "/service-worker", headers: { "Accept" => "*/*" }

    assert_response :success
    assert_equal "application/javascript", response.media_type
    assert_includes response.body, "self.addEventListener('fetch'"
  ensure
    ActionController::Base.allow_forgery_protection = previous_forgery_setting
  end
end
