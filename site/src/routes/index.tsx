import { createFileRoute } from '@tanstack/react-router'

export const Route = createFileRoute('/')({ component: Home })

const GITHUB_URL = 'https://github.com/simonwong/speaker'
const RELEASES_URL = `${GITHUB_URL}/releases`
const PRIVACY_URL = `${GITHUB_URL}/blob/main/PRIVACY.md`

const steps = [
  {
    title: '按住 Fn 说话',
    body: '按住说话、松开结束，也可以短按开始、再短按结束。按 Esc 随时取消。',
  },
  {
    title: '识别并整理',
    body: '用豆包、OpenAI 或千问转成文字。需要时再交给文字模型精简或重写，这一步只发送文字。',
  },
  {
    title: '送达原输入位置',
    body: '松开按键时锁定输入位置，之后切换窗口不会改变送达位置。',
  },
]

const features = [
  {
    title: '快捷键可自定义',
    body: '默认 Fn，也可以改成组合键，或单独使用一侧的 Option、Control、Shift。',
  },
  {
    title: '不会输入到错误的位置',
    body: '原输入位置已变化、已关闭或无法确认时，结果留在浮层里，由你主动复制。',
  },
  {
    title: '自选语音识别',
    body: '豆包、OpenAI、千问三选一。OpenAI 和千问可选边录边传，或录完再上传。',
  },
  {
    title: '可选文本整理',
    body: '精简清理、完整重写、自定义模式，支持 DeepSeek、OpenAI、Kimi、GLM 和自定义接口。',
  },
  {
    title: '个人词库',
    body: '把人名和专业术语加入词库，识别和整理时都会参考你的写法。',
  },
  {
    title: '会话记录',
    body: '历史记录保存在本机，可搜索、复制、删除，保留时长由你设定。',
  },
]

const privacy = [
  '没有账号体系，没有共用的服务端。API Key 由你自己提供。',
  '原始音频只在内存中处理，不写入磁盘，只发送给你选择的识别服务。',
  '密码框等安全输入框不会自动送达，文字也不进入历史记录。',
  '自动送达后恢复你原来的剪贴板内容，只有主动点击复制时才会留下结果。',
]

const waveform = [6, 10, 16, 24, 14, 28, 20, 32, 18, 26, 12, 22, 30, 16, 10, 20, 14, 8]

function Home() {
  return (
    <>
      <header className="nav">
        <div className="container nav-inner">
          <a className="brand" href="/">
            <img src="/icon.png" width={28} height={28} alt="" />
            Speaker
          </a>
          <nav className="nav-links">
            <a href={GITHUB_URL}>GitHub</a>
            <a href={RELEASES_URL}>Releases</a>
          </nav>
        </div>
      </header>

      <main>
        <section className="hero container">
          <img className="hero-icon" src="/icon.png" width={112} height={112} alt="Speaker 应用图标" />
          <h1>按住 Fn，说话。</h1>
          <p className="lede">
            <span>Speaker 是 macOS 菜单栏语音输入工具。</span>
            <span>松开按键后，文字出现在你正在输入的位置。</span>
          </p>
          <div className="actions">
            <a className="button primary" href={RELEASES_URL}>
              下载公测版
            </a>
            <a className="button" href={GITHUB_URL}>
              查看 GitHub
            </a>
          </div>
          <p className="meta">macOS 14 及以上 · Apple 芯片 · MIT 开源</p>

          <div className="hud" role="img" aria-label="录音浮层示意">
            <span className="hud-dot" />
            <span className="hud-bars">
              {waveform.map((height, index) => (
                <i key={index} style={{ height }} />
              ))}
            </span>
            <kbd>Fn</kbd>
          </div>
        </section>

        <section className="container section">
          <h2>三步完成一次输入</h2>
          <ol className="steps">
            {steps.map((step, index) => (
              <li key={step.title}>
                <span className="step-index">{index + 1}</span>
                <h3>{step.title}</h3>
                <p>{step.body}</p>
              </li>
            ))}
          </ol>
        </section>

        <section className="container section">
          <h2>功能</h2>
          <ul className="features">
            {features.map((feature) => (
              <li key={feature.title}>
                <h3>{feature.title}</h3>
                <p>{feature.body}</p>
              </li>
            ))}
          </ul>
        </section>

        <section className="container section split">
          <div>
            <h2>隐私</h2>
            <p className="section-note">
              完整的数据处理说明见 <a href={PRIVACY_URL}>PRIVACY.md</a>。
            </p>
          </div>
          <ul className="plain-list">
            {privacy.map((item) => (
              <li key={item}>{item}</li>
            ))}
          </ul>
        </section>

        <section className="container section split">
          <div>
            <h2>安装</h2>
            <p className="section-note">
              需要你自己的豆包、OpenAI 或阿里千问 API Key。
            </p>
          </div>
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
        <div className="container footer-inner">
          <span>© {new Date().getFullYear()} Simon Wong · MIT License</span>
          <nav className="nav-links">
            <a href={GITHUB_URL}>GitHub</a>
            <a href={RELEASES_URL}>Releases</a>
            <a href={PRIVACY_URL}>隐私</a>
          </nav>
        </div>
      </footer>
    </>
  )
}
