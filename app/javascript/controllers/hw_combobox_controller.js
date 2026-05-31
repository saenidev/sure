import HwComboboxController from "hotwire_combobox";

// Abort stale async searches so slower responses cannot overwrite newer input.
HwComboboxController.prototype._filterAsync = async function(inputType) {
  if (this._searchAbortController) {
    this._searchAbortController.abort();
  }
  this._searchAbortController = new AbortController();

  const query = {
    q: this._fullQuery,
    input_type: inputType,
    for_id: this.element.dataset.asyncId,
    callback_id: this._enqueueCallback()
  };

  const url = new URL(this.asyncSrcValue, window.location.origin);
  Object.entries(query).forEach(([key, value]) => {
    if (value != null) url.searchParams.set(key, value);
  });

  try {
    const response = await fetch(url.toString(), {
      headers: {
        "Accept": "text/vnd.turbo-stream.html, text/html, application/xhtml+xml",
        "X-Requested-With": "XMLHttpRequest",
        "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content
      },
      signal: this._searchAbortController.signal,
      credentials: "same-origin"
    });

    if (response.ok) {
      await Turbo.renderStreamMessage(await response.text());
    }
  } catch (error) {
    if (error.name !== "AbortError") throw error;
  }
};

export default HwComboboxController;
