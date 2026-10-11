// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import "@hotwired/turbo-rails";
import "controllers";

// Fix Back after a frame visit with data-turbo-action (the period picker).
// Turbo promotes it to a page visit that renders nothing, because turbo_rails'
// frame layout has none of the page's data-turbo-track assets, so Turbo never
// records the new URL as rendered. Back to the old URL is then a same-page
// no-op, and navigating away caches this page under the old URL. Record it on
// turbo:load, after the promoted visit has cached the previous page under the
// old URL, and only when a frame on the page now shows that URL: Turbo 8.0.13
// also promotes a frame that loads after the page it was on has gone. Drop
// this once hotwired/turbo#1569 ships.
document.addEventListener("turbo:load", ({ detail: { url } }) => {
  const frames = document.querySelectorAll("turbo-frame[src]");
  const frameShowsUrl = [...frames].some(
    (frame) => new URL(frame.src, document.baseURI).href === url,
  );
  if (frameShowsUrl) {
    Turbo.session.view.lastRenderedLocation = Turbo.session.history.location;
  }
});

Turbo.StreamActions.redirect = function () {
  // Use "replace" to avoid adding form submission to browser history
  Turbo.visit(this.target, { action: "replace" });
};

// Register service worker for PWA offline support
if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('/service-worker')
      .then(registration => {
        console.log('Service Worker registered with scope:', registration.scope);
      })
      .catch(error => {
        console.log('Service Worker registration failed:', error);
      });
  });
}
