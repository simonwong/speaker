import { createStartHandler, defaultStreamHandler } from '@tanstack/react-start/server'
import { langForPath } from './components'

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

// One Analytics Engine data point per /download request, with no cookie and
// nothing that identifies the visitor: the page language, the Referer host
// without its path or query, and the UTC date. IP address and User-Agent are
// never written. Analytics Engine adds its own write timestamp.
interface DownloadDataset {
  writeDataPoint(point: { blobs?: string[]; doubles?: number[]; indexes?: string[] }): void
}

const SITE_HOSTS = new Set([CANONICAL_HOST, ...RETIRED_HOSTS])

// zh or en from an explicit ?lang= link, else from the path of a page on this
// site; unknown for other referrers or none.
function downloadLanguage(url: URL, referrer: URL | null): string {
  const lang = url.searchParams.get('lang')
  if (lang === 'zh' || lang === 'en') return lang
  if (referrer && SITE_HOSTS.has(referrer.hostname)) {
    return langForPath(referrer.pathname) === 'en' ? 'en' : 'zh'
  }
  return 'unknown'
}

function recordDownload(dataset: DownloadDataset | undefined, request: Request, url: URL) {
  if (!dataset || request.method !== 'GET') return
  try {
    let referrer: URL | null = null
    try {
      const header = request.headers.get('referer')
      referrer = header ? new URL(header) : null
    } catch {}
    dataset.writeDataPoint({
      blobs: [
        downloadLanguage(url, referrer),
        referrer?.hostname ?? '',
        new Date().toISOString().slice(0, 10),
      ],
      doubles: [1],
      indexes: ['download'],
    })
  } catch {
    // Counting never blocks the download.
  }
}

interface Env {
  ASSETS: { fetch(request: Request): Promise<Response> }
  DOWNLOADS?: DownloadDataset
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
      recordDownload(env.DOWNLOADS, request, url)
      return Response.redirect(await latestDMG(), 302)
    }
    const asset = await env.ASSETS.fetch(request)
    if (asset.status !== 404) return asset
    return renderPage(request)
  },
}
