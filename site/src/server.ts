import { createStartHandler, defaultStreamHandler } from '@tanstack/react-start/server'

// The site moved from speaker.simonwong.cn. The old host stays bound to this
// Worker only to send visitors and search engines to the same path here, so
// every request, static files included, reaches this handler first.
const CANONICAL_HOST = 'speaker.moonunder.app'
const RETIRED_HOSTS = new Set(['speaker.simonwong.cn'])

const renderPage = createStartHandler(defaultStreamHandler)

// The DMG name carries its version and build number, so /download looks up
// the latest published release instead of linking a fixed file. Pre-releases
// are excluded by GitHub's "latest". Any failure falls back to the release page.
const LATEST_RELEASE_API = 'https://api.github.com/repos/simonwong/speaker/releases/latest'
const LATEST_RELEASE_PAGE = 'https://github.com/simonwong/speaker/releases/latest'

interface ReleaseAsset {
  name: string
  browser_download_url: string
}

async function latestDMG(): Promise<string> {
  try {
    const response = await fetch(LATEST_RELEASE_API, {
      headers: { accept: 'application/vnd.github+json', 'user-agent': 'speaker-site' },
      // Shared by every visitor to the same edge, which keeps the
      // unauthenticated GitHub API within its rate limit.
      cf: { cacheTtl: 600, cacheEverything: true },
    } as RequestInit)
    if (!response.ok) return LATEST_RELEASE_PAGE
    const release = (await response.json()) as { assets?: ReleaseAsset[] }
    const dmg = release.assets?.find((asset) => asset.name.endsWith('.dmg'))
    return dmg?.browser_download_url.startsWith('https://github.com/')
      ? dmg.browser_download_url
      : LATEST_RELEASE_PAGE
  } catch {
    return LATEST_RELEASE_PAGE
  }
}

interface Env {
  ASSETS: { fetch(request: Request): Promise<Response> }
}

export default {
  async fetch(request: Request, env: Env) {
    const url = new URL(request.url)
    if (RETIRED_HOSTS.has(url.hostname)) {
      url.protocol = 'https:'
      url.hostname = CANONICAL_HOST
      url.port = ''
      return Response.redirect(url.toString(), 301)
    }
    if (url.pathname === '/download') {
      return Response.redirect(await latestDMG(), 302)
    }
    const asset = await env.ASSETS.fetch(request)
    if (asset.status !== 404) return asset
    return renderPage(request)
  },
}
