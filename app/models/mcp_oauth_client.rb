# OAuth clients created by MCP dynamic registration (public, read_write only).
# They get short access tokens and refresh them; a refresh token left unused
# for REFRESH_IDLE_TTL stops working, so a forgotten client loses access.
module McpOauthClient
  ACCESS_TOKEN_TTL = 1.hour
  REFRESH_IDLE_TTL = 30.days

  def self.registered?(application)
    application.present? &&
      !application.confidential? &&
      application.scopes.to_a == [ "read_write" ] &&
      application.name != MobileDevice::OAUTH_APPLICATION_NAME
  end
end
