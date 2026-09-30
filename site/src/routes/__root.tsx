import { HeadContent, Outlet, Scripts, createRootRoute } from '@tanstack/react-router'
import type { ReactNode } from 'react'
import appCss from '../styles.css?url'

const siteUrl = 'https://speaker.simonwong.cn'
const title = 'Speaker：说话代替打字的 macOS 语音输入工具'
const description =
  'Speaker 是开源的 macOS 语音输入工具，把你说的话转成文字，送到正在输入的位置。语音识别支持豆包、OpenAI、阿里千问，使用你自己的 API Key，没有账号和服务端，可自定义整理模式。'
const image = `${siteUrl}/og.png`

const structuredData = {
  '@context': 'https://schema.org',
  '@type': 'SoftwareApplication',
  name: 'Speaker',
  description,
  url: siteUrl,
  image,
  applicationCategory: 'UtilitiesApplication',
  operatingSystem: 'macOS 14 或更高版本',
  inLanguage: 'zh-CN',
  license: 'https://opensource.org/licenses/MIT',
  downloadUrl: 'https://github.com/simonwong/speaker/releases',
  codeRepository: 'https://github.com/simonwong/speaker',
  author: { '@type': 'Person', name: 'Simon Wong', url: 'https://github.com/simonwong' },
  offers: { '@type': 'Offer', price: '0', priceCurrency: 'USD' },
}

export const Route = createRootRoute({
  head: () => ({
    meta: [
      { charSet: 'utf-8' },
      { name: 'viewport', content: 'width=device-width, initial-scale=1' },
      { title },
      { name: 'description', content: description },
      { name: 'robots', content: 'index, follow' },
      { property: 'og:type', content: 'website' },
      { property: 'og:site_name', content: 'Speaker' },
      { property: 'og:locale', content: 'zh_CN' },
      { property: 'og:url', content: `${siteUrl}/` },
      { property: 'og:title', content: title },
      { property: 'og:description', content: description },
      { property: 'og:image', content: image },
      { property: 'og:image:width', content: '512' },
      { property: 'og:image:height', content: '512' },
      { name: 'twitter:card', content: 'summary' },
      { name: 'twitter:title', content: title },
      { name: 'twitter:description', content: description },
      { name: 'twitter:image', content: image },
    ],
    links: [
      { rel: 'stylesheet', href: appCss },
      { rel: 'icon', type: 'image/png', href: '/favicon.png' },
      { rel: 'apple-touch-icon', href: '/apple-touch-icon.png' },
      { rel: 'canonical', href: `${siteUrl}/` },
    ],
    scripts: [{ type: 'application/ld+json', children: JSON.stringify(structuredData) }],
  }),
  shellComponent: RootDocument,
  component: Outlet,
})

function RootDocument({ children }: { children: ReactNode }) {
  return (
    <html lang="zh-CN">
      <head>
        <HeadContent />
      </head>
      <body>
        {children}
        <Scripts />
      </body>
    </html>
  )
}
