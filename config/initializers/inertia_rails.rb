# frozen_string_literal: true

# Forecast V2 runs as a route-scoped Inertia/Vite/React page inside the existing
# Sure Rails app. The rest of Sure keeps using importmap/Turbo/Stimulus.
#
# The Inertia asset version is derived from the Vite build manifest digest so the
# client performs a full reload whenever a deploy ships new compiled assets,
# instead of silently running stale JavaScript against a newer server.
InertiaRails.configure do |config|
  config.version = lambda do
    paths = ViteRuby.instance.config.manifest_paths
    next nil if paths.blank?

    digest = paths.sort.map { |path| Digest::SHA256.hexdigest(File.read(path)) }.join
    Digest::SHA256.hexdigest(digest)
  rescue StandardError
    # In development the manifest may not exist yet (dev server serves assets
    # directly). Falling back to nil keeps Inertia working without forcing a
    # reload loop.
    nil
  end
end
