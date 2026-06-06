// Base Vite entrypoint for the Forecast V2 Inertia/React/TypeScript frontend.
//
// This wiring slice (A1) only proves that the Vite + React + TypeScript +
// Inertia toolchain compiles, typechecks, and builds inside the existing Rails
// app. The real `/forecast` Inertia page tree, entrypoint, and read-model props
// are added in later slices (A2/A4). Keeping a single minimal entrypoint here
// lets `bin/vite build` produce a manifest without committing throwaway UI.

// Touching the runtime/client deps keeps them in the build graph and lets
// `npm run typecheck` validate that React + Inertia types resolve.
import { createInertiaApp } from "@inertiajs/react";
import { createElement } from "react";

export const inertiaToolchainReady: boolean =
  typeof createInertiaApp === "function" && typeof createElement === "function";
