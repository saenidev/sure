# Pin npm packages by running ./bin/importmap

pin "application"
pin "@hotwired/turbo-rails", to: "turbo.min.js", preload: true
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin "hotwire_combobox", to: "hotwire_combobox.esm.js", preload: [ "authenticated" ]
pin_all_from "app/javascript/controllers", under: "controllers", preload: [ "authenticated" ]
pin_all_from "app/components", under: "controllers", to: "", preload: [ "authenticated" ]
pin_all_from "app/javascript/services", under: "services", to: "services", preload: [ "authenticated" ]
pin_all_from "app/javascript/utils", under: "utils", to: "utils", preload: [ "authenticated" ]
pin "utils/sankey_zoom", to: "utils/sankey_zoom.mjs", preload: [ "authenticated" ]
# Forecast workspace preview engine (phase 4): pure .mjs modules shared with
# the node --test parity suite (test/javascript).
pin "forecast/preview_engine", to: "forecast/preview_engine.mjs", preload: [ "authenticated" ]
pin "forecast/form_params", to: "forecast/form_params.mjs", preload: [ "authenticated" ]
pin "forecast/save_pipeline", to: "forecast/save_pipeline.mjs", preload: [ "authenticated" ]
pin "@github/hotkey", to: "@github--hotkey.js", preload: [ "authenticated" ] # @3.1.1
pin "@simonwep/pickr", to: "@simonwep--pickr.js", preload: [ "authenticated" ] # @1.9.1

# D3 packages
pin "d3", preload: [ "authenticated" ] # @7.9.0
pin "d3-array", to: "shims/d3-array-default.js", preload: [ "authenticated" ]
pin "d3-axis", preload: [ "authenticated" ] # @3.0.0
pin "d3-brush", preload: [ "authenticated" ] # @3.0.0
pin "d3-chord", preload: [ "authenticated" ] # @3.0.1
pin "d3-color", preload: [ "authenticated" ] # @3.1.0
pin "d3-contour", preload: [ "authenticated" ] # @4.0.2
pin "d3-delaunay", preload: [ "authenticated" ] # @6.0.4
pin "d3-dispatch", preload: [ "authenticated" ] # @3.0.1
pin "d3-drag", preload: [ "authenticated" ] # @3.0.0
pin "d3-dsv", preload: [ "authenticated" ] # @3.0.1
pin "d3-ease", preload: [ "authenticated" ] # @3.0.1
pin "d3-fetch", preload: [ "authenticated" ] # @3.0.1
pin "d3-force", preload: [ "authenticated" ] # @3.0.0
pin "d3-format", preload: [ "authenticated" ] # @3.1.0
pin "d3-geo", preload: [ "authenticated" ] # @3.1.1
pin "d3-hierarchy", preload: [ "authenticated" ] # @3.1.2
pin "d3-interpolate", preload: [ "authenticated" ] # @3.0.1
pin "d3-path", preload: [ "authenticated" ] # @3.1.0
pin "d3-polygon", preload: [ "authenticated" ] # @3.0.1
pin "d3-quadtree", preload: [ "authenticated" ] # @3.0.1
pin "d3-random", preload: [ "authenticated" ] # @3.0.1
pin "d3-scale", preload: [ "authenticated" ] # @4.0.2
pin "d3-scale-chromatic", preload: [ "authenticated" ] # @3.1.0
pin "d3-selection", preload: [ "authenticated" ] # @3.0.0
pin "d3-shape", to: "shims/d3-shape-default.js", preload: [ "authenticated" ]
pin "d3-time", preload: [ "authenticated" ] # @3.1.0
pin "d3-time-format", preload: [ "authenticated" ] # @4.1.0
pin "d3-timer", preload: [ "authenticated" ] # @3.0.1
pin "d3-transition", preload: [ "authenticated" ] # @3.0.1
pin "d3-zoom", preload: [ "authenticated" ] # @3.0.0
pin "delaunator", preload: [ "authenticated" ] # @5.0.1
pin "internmap", preload: [ "authenticated" ] # @2.0.3
pin "robust-predicates", preload: [ "authenticated" ] # @3.0.2
pin "@floating-ui/dom", to: "@floating-ui--dom.js", preload: [ "authenticated" ] # @1.7.0
pin "@floating-ui/core", to: "@floating-ui--core.js", preload: [ "authenticated" ] # @1.7.0
pin "@floating-ui/utils", to: "@floating-ui--utils.js", preload: [ "authenticated" ] # @0.2.9
pin "@floating-ui/utils/dom", to: "@floating-ui--utils--dom.js", preload: [ "authenticated" ] # @0.2.9
pin "d3-sankey", preload: [ "authenticated" ] # @0.12.3
pin "d3-array-src", to: "d3-array.js", preload: [ "authenticated" ]
pin "d3-shape-src", to: "d3-shape.js", preload: [ "authenticated" ]
