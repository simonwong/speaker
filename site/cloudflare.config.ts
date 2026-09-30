import { defineConfig } from "cf/config";

export default defineConfig({
	worker: {
		name: "speaker-site",
		compatibilityDate: "2026-09-01",
		compatibilityFlags: [
			"nodejs_compat",
		],
		entrypoint: "@tanstack/react-start/server-entry",
		workersDev: false,
		domains: [
			"speaker.simonwong.cn",
		],
	},
});
