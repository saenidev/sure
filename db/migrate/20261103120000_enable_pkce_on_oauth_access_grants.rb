# Doorkeeper only verifies PKCE when these columns exist; without them
# force_pkce checks a challenge was sent but never checks the verifier.
class EnablePkceOnOauthAccessGrants < ActiveRecord::Migration[8.1]
  def change
    add_column :oauth_access_grants, :code_challenge, :string, null: true
    add_column :oauth_access_grants, :code_challenge_method, :string, null: true
  end
end
