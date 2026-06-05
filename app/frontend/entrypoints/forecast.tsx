// Forecast V2 Inertia/React/TypeScript entrypoint (spike slice A4).
//
// This is the single Vite entrypoint for the route-scoped Forecast V2 Inertia
// workspace. It boots a React root and resolves Inertia pages from
// `app/frontend/pages/Forecast/*` only. There is deliberately NO app-wide
// store: the server owns canonical plan truth and each page/component owns just
// its ephemeral interaction state (selected period, hover, etc.), per the
// Forecast V2 Inertia path rules.
//
// The existing importmap/Stimulus pipeline keeps serving every non-forecast
// Rails surface; this entrypoint is loaded only by the dedicated
// `forecast_inertia` layout.

import { createInertiaApp } from "@inertiajs/react";
import type { ResolvedComponent } from "@inertiajs/react";
import { createElement } from "react";
import { createRoot } from "react-dom/client";

type PageModule = { default: ResolvedComponent };

// Eagerly import the Forecast page tree so Vite emits a stable, build-time
// chunk graph (the spike needs `bin/vite build` to emit the page chunk).
const pages = import.meta.glob<PageModule>("../pages/Forecast/**/*.tsx", {
	eager: true,
});

createInertiaApp({
	// The Rails-rendered <title> already reflects the page; keep it as-is so we
	// do not duplicate or fight the server-owned document title.
	title: (title) => title,

	resolve: (name) => {
		const page = pages[`../pages/Forecast/${name.replace(/^Forecast\//, "")}.tsx`];

		if (!page) {
			throw new Error(`Inertia page not found: app/frontend/pages/Forecast/${name}`);
		}

		return page;
	},

	// React 18+ root: render into the Inertia mount element. No global store,
	// no Redux/Zustand provider — props flow from the server through Inertia.
	setup({ el, App, props }) {
		createRoot(el).render(createElement(App, props));
	},
});
