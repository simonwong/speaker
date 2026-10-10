import { createStartHandler, defaultStreamHandler } from '@tanstack/react-start/server'

// The site moved from speaker.simonwong.cn. The old host stays bound to this
// Worker only to send visitors and search engines to the same path here, so
// every request, static files included, reaches this handler first.
const CANONICAL_HOST = 'speaker.moonunder.app'
const RETIRED_HOSTS = new Set(['speaker.simonwong.cn'])

const renderPage = createStartHandler(defaultStreamHandler)

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
    const asset = await env.ASSETS.fetch(request)
    if (asset.status !== 404) return asset
    return renderPage(request)
  },
}
