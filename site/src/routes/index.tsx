import { createFileRoute } from '@tanstack/react-router'
import { Footer, GITHUB_URL, PRIVACY_URL, RELEASE_NOTES_URL, Section } from '../components'

const SITE_URL = 'https://speaker.moonunder.app/'
// Redirects to the newest DMG; see src/server.ts.
const DOWNLOAD_URL = `${SITE_URL}download`
const OG_IMAGE_URL = `${SITE_URL}og.png`

const title = 'Speaker：Mac 语音输入工具，说话转文字，自带 API Key'
const description =
  'Speaker 是免费开源的 Mac 语音输入工具：在任意输入框按住 Fn 说话，松开后文字出现在光标处。支持豆包、OpenAI、阿里千问语音识别，使用你自己的 API Key，没有账号和服务端。适用于 macOS 14 及以上。'

type Faq = { question: string; answer: string }

type Comparison = { aspect: string; speaker: string; inputMethod: string; dictation: string }

// Categories, not named products: each cell must stay true across vendors.
const comparisons: Comparison[] = [
  {
    aspect: '怎么用',
    speaker: '任意输入框按快捷键，不换输入法',
    inputMethod: '先切换到这个输入法',
    dictation: '按系统听写快捷键',
  },
  {
    aspect: '语音交给谁',
    speaker: '你选的服务商：豆包、OpenAI 或千问',
    inputMethod: '输入法厂商',
    dictation: 'Apple',
  },
  {
    aspect: '费用',
    speaker: '软件免费；识别按用量付给服务商，豆包约 1 元/小时',
    inputMethod: '免费',
    dictation: '免费',
  },
  {
    aspect: '整理文字',
    speaker: '可选服务商，可写自己的指令',
    inputMethod: '取决于产品',
    dictation: '不支持',
  },
  {
    aspect: '准备工作',
    speaker: '要自己申请 API Key',
    inputMethod: '安装输入法',
    dictation: '系统自带',
  },
  {
    aspect: '开源',
    speaker: 'MIT',
    inputMethod: '否',
    dictation: '否',
  },
]

const faqs: Faq[] = [
  {
    question: 'Speaker 收费吗？',
    answer: '免费，MIT 开源。语音识别和文字整理的费用由你选择的服务商按用量收取。',
  },
  {
    question: '和豆包输入法、微信输入法有什么不同？',
    answer:
      'Speaker 不是输入法，不用切换输入法，按快捷键就能在任意输入框说话。它没有账号，也不经过 Speaker 的服务器。识别和整理可以分别选服务商，还能写自己的整理指令。代价是要自己申请 API Key，按用量付费。',
  },
  {
    question: '用豆包识别，一个月大概多少钱？',
    answer:
      '豆包流式语音识别模型 2.0 小时版按音频时长计费，标价 1 元/小时，按秒累计。每天说 30 分钟，一个月约 15 小时，约 15 元。在控制台点「试用」可领 20 小时额度，半年内有效。价格以火山引擎计费说明为准。',
  },
  {
    question: '和 macOS 自带的听写有什么不同？',
    answer:
      'Speaker 不用系统听写，而是用你选择的识别服务和你自己的 Key，另外支持个人词库、文字整理和本机历史记录。',
  },
  {
    question: '下载后能直接打开吗？',
    answer: '可以。安装包经过 Apple Developer ID 签名和公证，首次打开时确认一下即可。',
  },
  {
    question: '为什么需要辅助功能权限？',
    answer: '用于响应全局快捷键、确认当前输入位置，并把文字送入输入框。麦克风权限只用于录音。',
  },
]

const structuredData = {
  '@context': 'https://schema.org',
  '@graph': [
    {
      '@type': 'WebSite',
      '@id': `${SITE_URL}#website`,
      url: SITE_URL,
      name: 'Speaker',
      inLanguage: 'zh-CN',
    },
    {
      '@type': 'SoftwareApplication',
      '@id': `${SITE_URL}#app`,
      name: 'Speaker',
      description,
      url: SITE_URL,
      image: OG_IMAGE_URL,
      applicationCategory: 'UtilitiesApplication',
      operatingSystem: 'macOS 14 或更高版本',
      downloadUrl: DOWNLOAD_URL,
      releaseNotes: RELEASE_NOTES_URL,
      softwareRequirements: 'macOS 14 或更高版本，Apple 芯片或 Intel 芯片',
      inLanguage: 'zh-CN',
      isAccessibleForFree: true,
      license: 'https://opensource.org/licenses/MIT',
      author: { '@type': 'Person', name: 'Simon Wong', url: 'https://github.com/simonwong' },
      offers: { '@type': 'Offer', price: '0', priceCurrency: 'CNY' },
      sameAs: [GITHUB_URL],
    },
    {
      '@type': 'FAQPage',
      '@id': `${SITE_URL}#faq`,
      mainEntity: faqs.map((faq) => ({
        '@type': 'Question',
        name: faq.question,
        acceptedAnswer: { '@type': 'Answer', text: faq.answer },
      })),
    },
  ],
}

export const Route = createFileRoute('/')({
  head: () => ({
    meta: [
      { title },
      { name: 'description', content: description },
      { name: 'robots', content: 'index, follow' },
      { property: 'og:type', content: 'website' },
      { property: 'og:site_name', content: 'Speaker' },
      { property: 'og:locale', content: 'zh_CN' },
      { property: 'og:url', content: SITE_URL },
      { property: 'og:title', content: title },
      { property: 'og:description', content: description },
      { property: 'og:image', content: OG_IMAGE_URL },
      { property: 'og:image:type', content: 'image/png' },
      { property: 'og:image:width', content: '1200' },
      { property: 'og:image:height', content: '630' },
      { property: 'og:image:alt', content: 'Speaker：Mac 语音输入，说话代替打字' },
      { name: 'twitter:card', content: 'summary_large_image' },
      { name: 'twitter:title', content: title },
      { name: 'twitter:description', content: description },
      { name: 'twitter:image', content: OG_IMAGE_URL },
      { name: 'twitter:image:alt', content: 'Speaker：Mac 语音输入，说话代替打字' },
    ],
    links: [{ rel: 'canonical', href: SITE_URL }],
    scripts: [{ type: 'application/ld+json', children: JSON.stringify(structuredData) }],
  }),
  component: Home,
})

function Home() {
  return (
    <div className="page">
      <main>
        <section className="hero">
          <div className="brand">
            <img
              src="/icon-112.png"
              width={56}
              height={56}
              alt="Speaker 应用图标"
              fetchPriority="high"
              decoding="async"
            />
            Speaker
          </div>
          <h1>Mac 语音输入，说话代替打字</h1>
          <p className="lede">
            在任意输入框按住 <kbd>Fn</kbd> 说话，松开后文字出现在光标处。用你自己的 API Key，没有账号，没有服务端。
          </p>
          <div className="actions">
            <a className="button primary" href={DOWNLOAD_URL}>
              下载 Mac 版
            </a>
            <a className="button" href={GITHUB_URL}>
              GitHub
            </a>
          </div>
          <p className="meta">macOS 14 及以上 · Apple 芯片与 Intel 芯片 · 免费，MIT 开源</p>
        </section>

        <Section id="voice-to-text" title="语音转文字">
          <p>
            按住 <kbd>Fn</kbd> 说话、松开结束，也可以短按开始、再短按结束。快捷键可以改，按 <kbd>Esc</kbd> 取消。
          </p>
          <p>文字只送到录音结束时的输入框，之后切换窗口也不会送错。送不进去时，结果留在浮层里供你复制。</p>
          <p>人名和术语可以加入个人词库，识别时会参考你的写法。</p>
        </Section>

        <Section id="api-key" title="自带 API Key">
          <p>
            语音识别可选豆包、OpenAI、阿里千问；OpenAI 和千问可以边录边传，也可以录完再传。豆包需要先在火山引擎开通流式识别资源，
            步骤见<a href="/doubao">申请豆包 API Key</a>。
          </p>
          <p>文字整理可选 DeepSeek、OpenAI、Kimi、GLM 或自定义接口。</p>
          <p>Key 存在 macOS 钥匙串里，请求从你的 Mac 直接发给服务商。</p>
        </Section>

        <Section id="refine" title="自定义整理模式">
          <p>默认直接使用识别结果。也可以选精简清理、完整重写，或者写一段自己的指令。</p>
          <p>整理只发送文字，不发送音频；整理失败时保留识别结果。</p>
        </Section>

        <Section id="privacy" title="不经过我们的服务器">
          <p>Speaker 没有服务端。音频和文字只发给你选择的服务商。</p>
          <p>
            设置、个人词库和历史记录只存在这台 Mac 上，密码框里的内容不进历史。音频只在内存中处理，不写入磁盘。详见{' '}
            <a href={PRIVACY_URL}>隐私说明</a>。
          </p>
        </Section>

        <Section id="install" title="下载与安装">
          <ol className="install">
            <li>
              <a href={DOWNLOAD_URL}>下载最新的 DMG</a>，历史版本在 <a href={RELEASE_NOTES_URL}>GitHub Releases</a>。
            </li>
            <li>把 Speaker 拖到“应用程序”，然后打开。</li>
            <li>按引导授权麦克风和辅助功能。</li>
            <li>
              选择识别服务，填入 API Key。没有 Key 的话，先看<a href="/doubao">申请豆包 API Key</a>。之后的新版本可以在 App 内更新。
            </li>
          </ol>
        </Section>

        <Section id="compare" title="和其他语音输入方式比较">
          <div className="compare">
            <table>
              <thead>
                <tr>
                  <th scope="col">
                    <span className="visually-hidden">方面</span>
                  </th>
                  <th scope="col">Speaker</th>
                  <th scope="col">输入法自带的语音输入</th>
                  <th scope="col">macOS 听写</th>
                </tr>
              </thead>
              <tbody>
                {comparisons.map((row) => (
                  <tr key={row.aspect}>
                    <th scope="row">{row.aspect}</th>
                    <td>{row.speaker}</td>
                    <td>{row.inputMethod}</td>
                    <td>{row.dictation}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </Section>

        <Section id="faq" title="常见问题">
          <div className="faq">
            {faqs.map((faq) => (
              <div className="faq-item" key={faq.question}>
                <h3>{faq.question}</h3>
                <p>{faq.answer}</p>
              </div>
            ))}
          </div>
        </Section>
      </main>

      <Footer />
    </div>
  )
}
