import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";
import RubyPlugin from "vite-plugin-ruby";

// Vite builds the Forecast V2 Inertia/React/TypeScript frontend only.
// Entrypoints live under app/frontend/entrypoints (sourceCodeDir in
// config/vite.json). The existing importmap/Propshaft/Tailwind pipeline keeps
// serving every non-forecast Rails surface.
export default defineConfig({
	plugins: [RubyPlugin(), react()],
});
