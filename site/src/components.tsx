import type { ReactNode } from 'react'

export const GITHUB_URL = 'https://github.com/simonwong/speaker'
export const RELEASE_NOTES_URL = `${GITHUB_URL}/releases`
export const PRIVACY_URL = `${GITHUB_URL}/blob/main/PRIVACY.md`

export function Section({ id, title, children }: { id: string; title: string; children: ReactNode }) {
  return (
    <section className="block" id={id} aria-labelledby={`${id}-title`}>
      <h2 id={`${id}-title`}>{title}</h2>
      {children}
    </section>
  )
}

export function Footer() {
  return (
    <footer className="footer">
      <span>© {new Date().getFullYear()} Simon Wong · MIT</span>
      <nav className="links" aria-label="项目链接">
        <a href={GITHUB_URL}>GitHub</a>
        <a href={RELEASE_NOTES_URL}>更新记录</a>
        <a href={PRIVACY_URL}>隐私说明</a>
      </nav>
    </footer>
  )
}
