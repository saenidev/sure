class Oauth::TokensController < Doorkeeper::TokensController
  before_action :refuse_idle_mcp_refresh_token, only: :create

  private

    # Doorkeeper refresh tokens never expire on their own. Each refresh issues a
    # new one, so refusing a refresh token older than the idle limit cuts off an
    # MCP client that has gone unused for that long.
    def refuse_idle_mcp_refresh_token
      return unless params[:grant_type] == "refresh_token"

      token = Doorkeeper.config.access_token_model.by_refresh_token(params[:refresh_token].to_s)
      return unless token && McpOauthClient.registered?(token.application)
      return if token.created_at > McpOauthClient::REFRESH_IDLE_TTL.ago

      token.revoke
      render json: { error: "invalid_grant", error_description: "The refresh token has expired." }, status: :bad_request
    end
end
