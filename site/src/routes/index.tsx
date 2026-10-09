import { createFileRoute } from '@tanstack/react-router'
import type { ReactNode } from 'react'

const SITE_URL = 'https://speaker.simonwong.cn/'
const GITHUB_URL = 'https://github.com/simonwong/speaker'
const DOWNLOAD_URL = `${GITHUB_URL}/releases/latest`
const RELEASE_NOTES_URL = `${GITHUB_URL}/releases`
const PRIVACY_URL = `${GITHUB_URL}/blob/main/PRIVACY.md`
const OG_IMAGE_URL = `${SITE_URL}og.png`

const title = 'Speaker：Mac 语音输入工具，说话转文字，自带 API Key'
const description =
  'Speaker 是免费开源的 Mac 语音输入工具：在任意输入框按住 Fn 说话，松开后文字出现在光标处。支持豆包、OpenAI、阿里千问语音识别，使用你自己的 API Key，没有账号和服务端。适用于 macOS 14 及以上。'

type Faq = { question: string; answer: string }

const faqs: Faq[] = [
  {
    question: 'Speaker 收费吗？',
    answer:
      'Speaker 免费，代码以 MIT 许可证开源。语音识别和文字整理使用你自己的 API Key，费用由所选服务商按用量收取。',
  },
  {
    question: '支持哪些语音识别服务？',
    answer:
      '支持豆包、OpenAI 和阿里千问。豆包语音识别需要先在火山引擎控制台开通对应的流式识别资源；OpenAI 和千问可以选择边录边传，或录完再上传整段音频。',
  },
  {
    question: '和 macOS 自带的听写有什么不同？',
    answer:
      'Speaker 不调用系统听写，而是把音频发给你选择的识别服务，用的是你自己的 Key。你可以添加个人词库，选择是否让文字模型整理结果，也可以在本机搜索历史记录。',
  },
  {
    question: '下载后能直接打开吗？',
    answer:
      '可以。安装包使用 Apple Developer ID 签名并经过 Apple 公证。macOS 首次打开时会提示这是从互联网下载的 App，确认即可，不需要右键打开，也不需要在终端移除隔离属性。',
  },
  {
    question: '为什么要授予辅助功能权限？',
    answer:
      '辅助功能权限用于监听你设置的全局快捷键、识别并验证当前输入位置，以及在输入框允许读取时核实文字是否送达。麦克风权限只用于录音。',
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

function Section({ id, title, children }: { id: string; title: string; children: ReactNode }) {
  return (
    <section className="block" id={id} aria-labelledby={`${id}-title`}>
      <h2 id={`${id}-title`}>{title}</h2>
      {children}
    </section>
  )
}

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
            Speaker 是 macOS 菜单栏里的语音输入工具。在任意应用的输入框里按住 <kbd>Fn</kbd> 说话，松开后，语音转成的文字出现在光标处。识别和整理用你自己的
            API Key，没有账号，也没有服务端。
          </p>
          <div className="actions">
            <a className="button primary" href={DOWNLOAD_URL}>
              下载 Mac 版
            </a>
            <a className="button" href={GITHUB_URL}>
              在 GitHub 查看源代码
            </a>
          </div>
          <p className="meta">
            macOS 14 及以上 · Apple 芯片与 Intel 芯片 · 免费，MIT 开源
          </p>
        </section>

        <Section id="voice-to-text" title="语音转文字">
          <p>
            按住 <kbd>Fn</kbd> 说话、松开结束，也可以短按一次开始、再短按一次结束。快捷键可以自己改，按{' '}
            <kbd>Esc</kbd> 随时取消。
          </p>
          <p>
            录音结束时，Speaker 记下当时的输入位置，之后切换窗口也不会把文字送错地方。原输入位置无法确认时，结果留在浮层里等你复制。
          </p>
          <p>把人名和术语加入个人词库，识别时会参考你的写法。</p>
        </Section>

        <Section id="api-key" title="自带 API Key">
          <p>
            语音识别可选豆包、OpenAI、阿里千问。OpenAI 和千问可以边录边传，也可以录完再上传。文字整理可选
            DeepSeek、OpenAI、Kimi、GLM 或自定义接口。
          </p>
          <p>Key 由你自己提供，存在 macOS 钥匙串里。请求从你的 Mac 直接发给服务商，不经过任何中转，费用由服务商按用量收取。</p>
        </Section>

        <Section id="refine" title="自定义整理模式">
          <p>
            默认直接使用识别结果。也可以选择精简清理、完整重写，或者写一段自己的指令，让文字模型按你的要求整理。
          </p>
          <p>整理只发送文字，不发送音频。整理失败时保留原始识别结果。</p>
        </Section>

        <Section id="privacy" title="数据留在本机">
          <p>没有账号，没有服务端。设置、个人词库和历史记录只保存在这台 Mac 上。</p>
          <p>
            音频只在内存中处理，不写入磁盘，只发送给你选择的识别服务。完整说明见{' '}
            <a href={PRIVACY_URL}>Speaker 隐私说明</a>。
          </p>
        </Section>

        <Section id="install" title="下载与安装">
          <ol className="install">
            <li>
              在 <a href={DOWNLOAD_URL}>GitHub Releases 最新版本页</a>下载{' '}
              <code>Speaker-&lt;版本&gt;-&lt;构建号&gt;.dmg</code>。
            </li>
            <li>打开 DMG，把 Speaker 拖到“应用程序”。装过旧版的话，先退出旧版再替换。</li>
            <li>
              从“应用程序”打开 Speaker，按引导授权麦克风和辅助功能。辅助功能需要在“系统设置 → 隐私与安全性 →
              辅助功能”里打开 Speaker。
            </li>
            <li>选择语音识别服务并保存 API Key。用豆包时，选择已开通的资源后点“检查连接”。</li>
          </ol>
        </Section>

        <Section id="updates" title="签名、公证与自动更新">
          <p>
            Speaker 使用 Apple Developer ID 签名，并经过 Apple 公证。同一个安装包支持 Apple 芯片和
            Intel 芯片的 Mac。
          </p>
          <p>
            新版本在 App 内更新：在“设置 → 关于”点“检查更新…”，或在“通用”里打开“自动检查更新”。安装更新前，Speaker
            会校验更新包的 Ed25519 签名。各版本的变更见 <a href={RELEASE_NOTES_URL}>Speaker 更新记录</a>。
          </p>
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

      <footer className="footer">
        <span>© {new Date().getFullYear()} Simon Wong · MIT</span>
        <nav className="links" aria-label="项目链接">
          <a href={GITHUB_URL}>GitHub</a>
          <a href={`${GITHUB_URL}/releases`}>更新记录</a>
          <a href={PRIVACY_URL}>隐私说明</a>
        </nav>
      </footer>
    </div>
  )
}
