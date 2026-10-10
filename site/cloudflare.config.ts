import { bindings, defineConfig } from "cf/config";

export default defineConfig({
	worker: {
		name: "speaker-site",
		compatibilityDate: "2026-09-01",
		compatibilityFlags: [
			"nodejs_compat",
		],
		entrypoint: "./src/server.ts",
		env: {
			ASSETS: bindings.assets(),
		},
		// The retired domain must redirect static files too, so the Worker
		// sees every request and serves assets itself through ASSETS.
		assets: {
			runWorkerFirst: true,
		},
		workersDev: false,
		domains: [
			"speaker.moonunder.app",
			// Retired host; src/server.ts redirects it to speaker.moonunder.app.
			"speaker.simonwong.cn",
		],
	},
});
