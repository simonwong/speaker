import type { ReactNode } from 'react'
import {
  Footer,
  GITHUB_URL,
  HOME_URLS,
  type Lang,
  RELEASE_NOTES_URL,
  SITE_URL,
  Section,
  homeAlternates,
} from './components'

// Redirects to the newest DMG; see src/server.ts.
export const DOWNLOAD_URL = `${SITE_URL}download`

// The repository doubles as the tap; the cask is Casks/speaker.rb.
export const BREW_INSTALL = [
  'brew tap simonwong/speaker https://github.com/simonwong/speaker',
  'brew install --cask simonwong/speaker/speaker',
].join('\n')

export type Faq = { question: string; answer: string }

export type HomeCopy = {
  lang: Lang
  title: string
  description: string
  keywords?: string
  ogImage: string
  ogImageAlt: string
  priceCurrency: string
  requirements: string
  iconAlt: string
  otherLanguage: { lang: Lang; label: string }
  headline: ReactNode
  lede: ReactNode
  downloadLabel: string
  meta: string
  sections: { id: string; title: string; body: ReactNode }[]
  compare: {
    title: string
    aspectLabel: string
    columns: string[]
    // Categories, not named products: each cell must stay true across vendors.
    rows: string[][]
  }
  faqTitle: string
  faqs: Faq[]
}

const OG_LOCALES: Record<Lang, string> = { 'zh-CN': 'zh_CN', en: 'en_US' }

function structuredData(copy: HomeCopy) {
  const url = HOME_URLS[copy.lang]
  return {
    '@context': 'https://schema.org',
    '@graph': [
      {
        '@type': 'WebSite',
        '@id': `${SITE_URL}#website`,
        url: SITE_URL,
        name: 'Speaker',
        inLanguage: ['zh-CN', 'en'],
      },
      {
        '@type': 'SoftwareApplication',
        '@id': `${url}#app`,
        name: 'Speaker',
        description: copy.description,
        url,
        image: copy.ogImage,
        applicationCategory: 'UtilitiesApplication',
        operatingSystem: 'macOS 14+',
        downloadUrl: DOWNLOAD_URL,
        releaseNotes: RELEASE_NOTES_URL,
        softwareRequirements: copy.requirements,
        inLanguage: copy.lang,
        isAccessibleForFree: true,
        license: 'https://opensource.org/licenses/MIT',
        author: { '@type': 'Person', name: 'Simon Wong', url: 'https://github.com/simonwong' },
        offers: { '@type': 'Offer', price: '0', priceCurrency: copy.priceCurrency },
        sameAs: [GITHUB_URL],
      },
      {
        '@type': 'FAQPage',
        '@id': `${url}#faq`,
        inLanguage: copy.lang,
        mainEntity: copy.faqs.map((faq) => ({
          '@type': 'Question',
          name: faq.question,
          acceptedAnswer: { '@type': 'Answer', text: faq.answer },
        })),
      },
    ],
  }
}

export function homeHead(copy: HomeCopy) {
  const url = HOME_URLS[copy.lang]
  const otherLocale = OG_LOCALES[copy.otherLanguage.lang]
  return {
    meta: [
      { title: copy.title },
      { name: 'description', content: copy.description },
      ...(copy.keywords ? [{ name: 'keywords', content: copy.keywords }] : []),
      { name: 'robots', content: 'index, follow' },
      { property: 'og:type', content: 'website' },
      { property: 'og:site_name', content: 'Speaker' },
      { property: 'og:locale', content: OG_LOCALES[copy.lang] },
      { property: 'og:locale:alternate', content: otherLocale },
      { property: 'og:url', content: url },
      { property: 'og:title', content: copy.title },
      { property: 'og:description', content: copy.description },
      { property: 'og:image', content: copy.ogImage },
      { property: 'og:image:type', content: 'image/png' },
      { property: 'og:image:width', content: '1200' },
      { property: 'og:image:height', content: '630' },
      { property: 'og:image:alt', content: copy.ogImageAlt },
      { name: 'twitter:card', content: 'summary_large_image' },
      { name: 'twitter:title', content: copy.title },
      { name: 'twitter:description', content: copy.description },
      { name: 'twitter:image', content: copy.ogImage },
      { name: 'twitter:image:alt', content: copy.ogImageAlt },
    ],
    links: [{ rel: 'canonical', href: url }, ...homeAlternates],
    scripts: [{ type: 'application/ld+json', children: JSON.stringify(structuredData(copy)) }],
  }
}

export function HomePage({ copy }: { copy: HomeCopy }) {
  const other = copy.otherLanguage
  return (
    <div className="page">
      <main>
        <section className="hero">
          <div className="topbar">
            <div className="brand">
              <img
                src="/icon-112.png"
                width={56}
                height={56}
                alt={copy.iconAlt}
                fetchPriority="high"
                decoding="async"
              />
              Speaker
            </div>
            <a className="language" href={HOME_URLS[other.lang]} hrefLang={other.lang} lang={other.lang}>
              {other.label}
            </a>
          </div>
          <h1>{copy.headline}</h1>
          <p className="lede">{copy.lede}</p>
          <div className="actions">
            <a className="button primary" href={DOWNLOAD_URL}>
              {copy.downloadLabel}
            </a>
            <a className="button" href={GITHUB_URL}>
              GitHub
            </a>
          </div>
          <p className="meta">{copy.meta}</p>
        </section>

        {copy.sections.map((section) => (
          <Section key={section.id} id={section.id} title={section.title}>
            {section.body}
          </Section>
        ))}

        <Section id="compare" title={copy.compare.title}>
          <div className="compare">
            <table>
              <thead>
                <tr>
                  <th scope="col">
                    <span className="visually-hidden">{copy.compare.aspectLabel}</span>
                  </th>
                  {copy.compare.columns.map((column) => (
                    <th scope="col" key={column}>
                      {column}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {copy.compare.rows.map(([aspect, ...cells]) => (
                  <tr key={aspect}>
                    <th scope="row">{aspect}</th>
                    {cells.map((cell, index) => (
                      <td key={index}>{cell}</td>
                    ))}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </Section>

        <Section id="faq" title={copy.faqTitle}>
          <div className="faq">
            {copy.faqs.map((faq) => (
              <div className="faq-item" key={faq.question}>
                <h3>{faq.question}</h3>
                <p>{faq.answer}</p>
              </div>
            ))}
          </div>
        </Section>
      </main>

      <Footer lang={copy.lang} />
    </div>
  )
}
