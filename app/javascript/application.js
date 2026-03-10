// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import "@hotwired/turbo-rails";
import "controllers";

Turbo.StreamActions.redirect = function () {
  // Use "replace" to avoid adding form submission to browser history
  Turbo.visit(this.target, { action: "replace" });
};

// Service worker registration temporarily disabled to avoid stale cached assets and auth flow issues.
