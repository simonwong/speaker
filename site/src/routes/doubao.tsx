import { createFileRoute } from '@tanstack/react-router'
import { Footer, Section } from '../components'

const PAGE_URL = 'https://speaker.moonunder.app/doubao'
const CONSOLE_OVERVIEW_URL = 'https://console.volcengine.com/speech/new/overview?projectName=default'
const CONSOLE_API_KEYS_URL =
  'https://console.volcengine.com/speech/new/setting/apikeys?projectName=default'
const QUICK_START_URL = 'https://docs.volcengine.com/docs/DoubaoVoice/QuickStartNewConsole?lang=zh'
const PRICING_URL = 'https://docs.volcengine.com/docs/6561/1359370?lang=zh'
const FREE_QUOTA_URL = 'https://docs.volcengine.com/docs/6561/1359369?lang=zh'

const title = '申请豆包语音 API Key · Speaker'
const description =
  '在火山引擎豆包语音控制台开通流式语音识别模型 2.0、复制 API Key，并在 Speaker 中完成连接检查。包含常见报错和费用估算。'

export const Route = createFileRoute('/doubao')({
  head: () => ({
    meta: [
      { title },
      { name: 'description', content: description },
      { name: 'robots', content: 'index, follow' },
      { property: 'og:type', content: 'article' },
      { property: 'og:site_name', content: 'Speaker' },
      { property: 'og:locale', content: 'zh_CN' },
      { property: 'og:url', content: PAGE_URL },
      { property: 'og:title', content: title },
      { property: 'og:description', content: description },
    ],
    links: [{ rel: 'canonical', href: PAGE_URL }],
  }),
  component: DoubaoGuide,
})

function DoubaoGuide() {
  return (
    <div className="page">
      <main>
        <section className="hero compact">
          <a className="back" href="/">
            ← Speaker
          </a>
          <h1>申请豆包语音 API Key</h1>
          <p className="lede">Speaker 只需要一个 API Key，不需要 APP ID、Access Token 或 AK/SK。</p>
        </section>

        <Section id="steps" title="步骤">
          <ol className="install">
            <li>注册并登录火山引擎，完成实名认证。新账号认证后才能开通服务。</li>
            <li>
              打开<a href={CONSOLE_OVERVIEW_URL}>豆包语音控制台</a>，开通「豆包流式语音识别模型 2.0」。可以一键开通全部模型，也可以只开通这一项。
            </li>
            <li>
              在左侧「<a href={CONSOLE_API_KEYS_URL}>API Key 管理</a>」复制 API Key。控制台会自动创建一个默认 Key，也可以新建一个。
            </li>
            <li>
              打开 Speaker 设置 → 语音识别，服务商选「豆包语音」，粘贴 Key 并保存。「流式资源」保持「流式模型 2.0 · 小时版（推荐）」。
            </li>
            <li>点「检查连接」。显示连接成功后就可以用了。</li>
          </ol>
          <p className="note">
            控制台的入口名称可能调整，以火山引擎<a href={QUICK_START_URL}>快速入门</a>为准。
          </p>
        </Section>

        <Section id="errors" title="检查连接失败">
          <div className="faq">
            <div className="faq-item">
              <h3>提示这个 Key 没有开通某个流式资源</h3>
              <p>
                Speaker 里选的资源和控制台开通的不一致。到控制台开通提示里的那一项，或者在「流式资源」里改选你开通的版本，比如并发版或 1.0。
              </p>
            </div>
            <div className="faq-item">
              <h3>提示 API Key 无效</h3>
              <p>
                多半是复制成了 APP ID、Access Token，或者旧版控制台的凭据。回到「API Key 管理」重新复制，粘贴时注意不要带空格。
              </p>
            </div>
          </div>
        </Section>

        <Section id="cost" title="费用">
          <p>
            流式语音识别模型 2.0 小时版按音频时长计费，标价 1 元/小时，按秒累计。每天说 30 分钟，一个月约 15 小时，约 15 元。
          </p>
          <p>
            点控制台的「试用」可领 20 小时额度，半年内有效。检查连接只发送 0.4 秒静音。价格和额度摘自火山引擎
            <a href={PRICING_URL}>计费说明</a>和<a href={FREE_QUOTA_URL}>计费概述</a>（2026 年 10 月查阅），以官方页面为准。
          </p>
        </Section>
      </main>

      <Footer />
    </div>
  )
}
