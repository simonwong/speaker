import { createFileRoute } from '@tanstack/react-router'

export const Route = createFileRoute('/')({ component: Home })

const GITHUB_URL = 'https://github.com/simonwong/speaker'
const RELEASES_URL = `${GITHUB_URL}/releases`
const PRIVACY_URL = `${GITHUB_URL}/blob/main/PRIVACY.md`

const points = [
  {
    title: '自带 Key',
    body: [
      '语音识别可选豆包、OpenAI、阿里千问，文本整理可选 DeepSeek、OpenAI、Kimi、GLM 或自定义接口。',
      'Key 由你自己提供，请求从你的 Mac 直接发给服务商，不经过任何中转。',
    ],
  },
  {
    title: '纯本地',
    body: [
      '没有账号，没有服务端。设置、个人词库和历史记录只保存在这台 Mac 上。',
      '音频只在内存中处理，不写入磁盘，只发送给你选择的识别服务。',
    ],
  },
  {
    title: '语音转文字',
    body: [
      '在任意应用的输入框里按下快捷键说话，结束后文字出现在光标处。',
      '把人名和术语加入个人词库，识别时会参考你的写法。原输入位置无法确认时，结果留在浮层里等你复制。',
    ],
  },
  {
    title: '自定义模式',
    body: [
      '默认直接使用识别结果。也可以选择精简清理、完整重写，或者写一段自己的指令，让文字模型按你的要求整理。',
      '整理只发送文字，不发送音频。整理失败时保留原始识别结果。',
    ],
  },
]

function Home() {
  return (
    <div className="page">
      <main>
        <section className="hero">
          <div className="brand">
            <img src="/icon.png" width={56} height={56} alt="Speaker 应用图标" />
            Speaker
          </div>
          <h1>说话代替打字</h1>
          <p className="lede">
            Speaker 是 macOS 上的语音输入工具，把你说的话转成文字，送到正在输入的位置。识别和整理用你自己的
            API Key，没有账号和服务端，整理方式可以自己定义。
          </p>
          <div className="actions">
            <a className="button primary" href={RELEASES_URL}>
              下载公测版
            </a>
            <a className="button" href={GITHUB_URL}>
              GitHub
            </a>
          </div>
          <p className="meta">macOS 14 及以上 · Apple 芯片 · MIT 开源</p>
        </section>

        {points.map((point) => (
          <section className="block" key={point.title}>
            <h2>{point.title}</h2>
            {point.body.map((paragraph) => (
              <p key={paragraph}>{paragraph}</p>
            ))}
          </section>
        ))}

        <section className="block">
          <h2>安装</h2>
          <ol className="install">
            <li>
              在 <a href={RELEASES_URL}>GitHub Releases</a> 下载最新的{' '}
              <code>Speaker-&lt;版本&gt;-arm64.dmg</code>，打开后把 Speaker 拖到“应用程序”。
            </li>
            <li>
              公测版使用自签证书，未经 Apple 公证。首次启动前移除这个 App 的隔离属性：
              <pre>
                <code>xattr -dr com.apple.quarantine /Applications/Speaker.app</code>
              </pre>
            </li>
            <li>启动后按引导授权麦克风和辅助功能，选择识别服务并保存 API Key。</li>
          </ol>
        </section>
      </main>

      <footer className="footer">
        <span>© {new Date().getFullYear()} Simon Wong · MIT</span>
        <nav className="links">
          <a href={GITHUB_URL}>GitHub</a>
          <a href={RELEASES_URL}>Releases</a>
          <a href={PRIVACY_URL}>隐私</a>
        </nav>
      </footer>
    </div>
  )
}
