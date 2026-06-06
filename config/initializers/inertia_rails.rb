# frozen_string_literal: true

# Forecast V2 runs as a route-scoped Inertia/Vite/React page inside the existing
# Sure Rails app. The rest of Sure keeps using importmap/Turbo/Stimulus.
#
# The Inertia asset version is derived from the Vite build manifest digest so the
# client performs a full reload whenever a deploy ships new compiled assets,
# instead of silently running stale JavaScript against a newer server.
InertiaRails.configure do |config|
  # Opt in to the Inertia 4.0 protocol behavior now: always include an `errors`
  # hash on responses (empty when there are no validation errors). Silences the
  # transitional deprecation warning and keeps the client contract stable.
  config.always_include_errors_hash = true

  # Serialize the initial page as a `<script type="application/json">` element
  # rather than a `data-page` attribute on the root div. The installed
  # `@inertiajs/core` client (v3.3.x) reads the initial page ONLY from that
  # script element (`getInitialPageFromDOM`); with the gem's default
  # attribute-based rendering the React root never hydrates ("Cannot read
  # properties of null (reading 'component')"). Keeping these aligned is what
  # makes the route actually mount in the browser (spike system test A7).
  config.use_script_element_for_initial_page = true

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
