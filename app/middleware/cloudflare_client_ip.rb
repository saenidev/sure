require "ipaddr"

# Behind a Cloudflare Tunnel every request reaches Rails from the tunnel and
# Traefik on the private Docker network, and Traefik drops the client address
# Cloudflare forwarded. Rails then sees one private IP for everyone, so the
# per-IP Rack::Attack throttles lump all visitors together (a guesser can lock
# everyone out of /sessions) and session IPs record the proxy.
#
# Cloudflare sends the visitor's address in CF-Connecting-IP. Trust it only when
# the request came from a private address, i.e. through the local proxy chain;
# a request arriving straight from the internet keeps its own address.
class CloudflareClientIp
  HEADER = "HTTP_CF_CONNECTING_IP".freeze

  def initialize(app)
    @app = app
  end

  def call(env)
    client_ip = env[HEADER].to_s.strip
    if client_ip.present? && private_address?(env["REMOTE_ADDR"]) && valid_address?(client_ip)
      env["REMOTE_ADDR"] = client_ip
      env.delete("HTTP_X_FORWARDED_FOR")
    end

    @app.call(env)
  end

  private
    def private_address?(address)
      ip = IPAddr.new(address.to_s)
      ip.private? || ip.loopback?
    rescue IPAddr::Error
      false
    end

    def valid_address?(address)
      IPAddr.new(address)
      true
    rescue IPAddr::Error
      false
    end
end
