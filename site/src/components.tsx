import type { ReactNode } from 'react'

export const SITE_URL = 'https://speaker.moonunder.app/'
export const GITHUB_URL = 'https://github.com/simonwong/speaker'
export const RELEASE_NOTES_URL = `${GITHUB_URL}/releases`
export const PRIVACY_URL = `${GITHUB_URL}/blob/main/PRIVACY.md`

export type Lang = 'zh-CN' | 'en'

// The home page exists in both languages; every other page is Chinese only.
export const HOME_URLS: Record<Lang, string> = {
  'zh-CN': SITE_URL,
  en: `${SITE_URL}en`,
}

// Search engines need the same hreflang set on every page in the group,
// including a link to the page itself. Unmatched languages get English.
export const homeAlternates = [
  { rel: 'alternate', hrefLang: 'zh', href: HOME_URLS['zh-CN'] },
  { rel: 'alternate', hrefLang: 'en', href: HOME_URLS.en },
  { rel: 'alternate', hrefLang: 'x-default', href: HOME_URLS.en },
]

export function langForPath(pathname: string): Lang {
  return pathname === '/en' || pathname.startsWith('/en/') ? 'en' : 'zh-CN'
}

export function Section({ id, title, children }: { id: string; title: string; children: ReactNode }) {
  return (
    <section className="block" id={id} aria-labelledby={`${id}-title`}>
      <h2 id={`${id}-title`}>{title}</h2>
      {children}
    </section>
  )
}

const footerCopy: Record<Lang, { nav: string; releases: string; privacy: string }> = {
  'zh-CN': { nav: '项目链接', releases: '更新记录', privacy: '隐私说明' },
  en: { nav: 'Project links', releases: 'Releases', privacy: 'Privacy' },
}

export function Footer({ lang = 'zh-CN' }: { lang?: Lang }) {
  const copy = footerCopy[lang]
  return (
    <footer className="footer">
      <span>© {new Date().getFullYear()} Simon Wong · MIT</span>
      <nav className="links" aria-label={copy.nav}>
        <a href={GITHUB_URL}>GitHub</a>
        <a href={RELEASE_NOTES_URL}>{copy.releases}</a>
        <a href={PRIVACY_URL}>{copy.privacy}</a>
      </nav>
    </footer>
  )
}
