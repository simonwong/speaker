import { createFileRoute } from '@tanstack/react-router'
import { PRIVACY_URL, RELEASE_NOTES_URL, SITE_URL } from '../components'
import { DOWNLOAD_URL, type HomeCopy, HomePage, homeHead } from '../home'

const copy: HomeCopy = {
  lang: 'zh-CN',
  title: 'Speaker：Mac 语音转文字 App，免费开源的语音输入工具',
  description:
    'Speaker 是免费开源的 Mac 语音转文字 App：在任意输入框按住 Fn 说话，松开后文字直接出现在光标处。语音识别可选豆包、OpenAI、阿里千问，macOS 26 上还能用不需要 Key 的 Apple 本机识别。没有账号，不用订阅，适用于 macOS 14 及以上。',
  keywords:
    '语音转文字,语音转文字 App,语音转文字软件,Mac 语音转文字,Mac 语音输入,语音输入软件,AI 语音输入,语音打字,语音识别软件,豆包语音识别,开源',
  ogImage: `${SITE_URL}og.png`,
  ogImageAlt: 'Speaker：Mac 语音转文字，说话代替打字',
  priceCurrency: 'CNY',
  requirements: 'macOS 14 或更高版本，Apple 芯片或 Intel 芯片；Apple 语音识别需要 macOS 26',
  iconAlt: 'Speaker 应用图标',
  otherLanguage: { lang: 'en', label: 'English' },
  headline: 'Mac 语音转文字，说话代替打字',
  lede: (
    <>
      在任意输入框按住 <kbd>Fn</kbd> 说话，松开后文字出现在光标处。用你自己的 API Key 或 Apple 本机识别，没有账号，没有服务端。
    </>
  ),
  downloadLabel: '下载 Mac 版',
  meta: 'macOS 14 及以上 · Apple 芯片与 Intel 芯片 · 免费，MIT 开源',
  sections: [
    {
      id: 'voice-to-text',
      title: '在任意 App 里语音输入',
      body: (
        <>
          <p>
            按住 <kbd>Fn</kbd> 说话、松开结束，也可以短按开始、再短按结束。快捷键可以改，按 <kbd>Esc</kbd> 取消。
          </p>
          <p>文字只送到录音结束时的输入框，之后切换窗口也不会送错。送不进去时，结果留在浮层里供你复制。</p>
          <p>
            等整理时可以点「直接用识别结果」跳过整理。菜单栏的「最近结果」列出最近 5 条，点一下就能复制。
          </p>
          <p>人名和术语可以加入个人词库，识别时会参考你的写法。</p>
        </>
      ),
    },
    {
      id: 'api-key',
      title: '选择识别服务',
      body: (
        <>
          <p>
            语音识别可选豆包、OpenAI、阿里千问；OpenAI 和千问可以边录边传，也可以录完再传。豆包需要先在火山引擎开通流式识别资源，
            步骤见<a href="/doubao">申请豆包 API Key</a>。
          </p>
          <p>
            macOS 26 及以上还可以选 Apple 语音识别：在本机识别，不需要 Key，录音不离开这台 Mac。首次使用前在设置里下载语言模型。
          </p>
          <p>文字整理可选 DeepSeek、OpenAI、Kimi、GLM 或自定义接口。</p>
          <p>Key 存在 macOS 钥匙串里，请求从你的 Mac 直接发给服务商。</p>
        </>
      ),
    },
    {
      id: 'refine',
      title: '自定义整理模式',
      body: (
        <>
          <p>默认直接使用识别结果。也可以选精简清理、完整重写，或者写一段自己的指令。</p>
          <p>整理只发送文字，不发送音频；整理失败时保留识别结果。中英混说时，整理不会把英文翻译成中文。</p>
        </>
      ),
    },
    {
      id: 'privacy',
      title: '不经过我们的服务器',
      body: (
        <>
          <p>Speaker 没有服务端。音频和文字只发给你选择的服务商；用 Apple 语音识别时，录音不离开这台 Mac。</p>
          <p>
            设置、个人词库和历史记录只存在这台 Mac 上，密码框里的内容不进历史。音频只在内存中处理，不写入磁盘。详见{' '}
            <a href={PRIVACY_URL}>隐私说明</a>。
          </p>
        </>
      ),
    },
    {
      id: 'install',
      title: '下载与安装',
      body: (
        <ol className="install">
          <li>
            <a href={DOWNLOAD_URL}>下载最新的 DMG</a>，历史版本在 <a href={RELEASE_NOTES_URL}>GitHub Releases</a>。
          </li>
          <li>把 Speaker 拖到“应用程序”，然后打开。</li>
          <li>按引导授权麦克风和辅助功能。</li>
          <li>
            选择识别服务，填入 API Key；用 Apple 语音识别则下载语言模型。没有 Key 的话，先看
            <a href="/doubao">申请豆包 API Key</a>。
          </li>
          <li>在引导最后一步的练习框里试一次。之后的新版本可以在 App 内更新。</li>
        </ol>
      ),
    },
  ],
  compare: {
    title: '和其他语音转文字 App 比较',
    aspectLabel: '方面',
    columns: ['Speaker', '其他语音转文字 App'],
    rows: [
      ['怎么用', '任意输入框按快捷键，文字直接出现在光标处', '多数在 App 里录音或导入音频，转写后再复制'],
      ['语音交给谁', '你选的服务商：豆包、OpenAI 或千问；也可以用 Apple 本机识别', '通常是 App 厂商的服务器'],
      [
        '费用',
        '软件免费；云端识别按用量付给服务商，豆包约 1 元/小时；Apple 本机识别免费',
        '通常有免费额度，超出后按月或按年付费',
      ],
      ['账号', '不需要', '通常需要注册登录'],
      ['识别模型', '自己选', '厂商决定'],
      ['整理文字', '可选服务商，可写自己的指令', '取决于产品'],
      ['准备工作', '申请 API Key，或下载 Apple 语音识别的语言模型', '注册账号'],
      ['开源', 'MIT', '多数不开源'],
    ],
  },
  faqTitle: '常见问题',
  faqs: [
    {
      question: 'Speaker 收费吗？',
      answer:
        '免费，MIT 开源。云端语音识别和文字整理的费用由你选择的服务商按用量收取；Apple 语音识别在本机运行，不产生费用。',
    },
    {
      question: '不想申请 API Key，能用吗？',
      answer:
        'macOS 26 及以上可以选 Apple 语音识别，在本机运行，不需要 Key，下载语言模型后就能用。macOS 14 和 15 需要豆包、OpenAI 或千问的 Key。',
    },
    {
      question: '和豆包输入法、微信输入法有什么不同？',
      answer:
        'Speaker 不是输入法，不用切换输入法，按快捷键就能在任意输入框说话。它没有账号，也不经过 Speaker 的服务器。识别和整理可以分别选服务商，还能写自己的整理指令。',
    },
    {
      question: '用豆包识别，一个月大概多少钱？',
      answer:
        '豆包流式语音识别模型 2.0 小时版按音频时长计费，标价 1 元/小时，按秒累计。每天说 30 分钟，一个月约 15 小时，约 15 元。在控制台点「试用」可领 20 小时额度，半年内有效。价格以火山引擎计费说明为准。',
    },
    {
      question: '能识别英文和中英混说吗？',
      answer:
        '豆包默认使用中英文模型，中英混说可以直接识别；OpenAI 和千问支持多种语言；Apple 语音识别使用系统首选语言里第一个支持的语言。App 界面目前只有简体中文。',
    },
    {
      question: '和其他语音转文字 App 有什么不同？',
      answer:
        '常见的语音转文字 App 通常要注册账号、开会员，音频发到厂商的服务器，转写完再复制出来。Speaker 免费开源，没有账号；识别服务自己选，按用量直接付给服务商，或者用 Apple 本机识别；文字直接出现在光标处，不用复制粘贴。',
    },
    {
      question: '按 Fn 时弹出表情或切换了输入法怎么办？',
      answer:
        '这是系统给 🌐 键设置了其他功能。Speaker 会在引导和设置里提示，点「打开键盘设置」，把「按下 🌐 键时」改为「不执行任何操作」；也可以在 Speaker 里换一个快捷键。',
    },
    {
      question: '下载后能直接打开吗？',
      answer: '可以。安装包经过 Apple Developer ID 签名和公证，首次打开时确认一下即可。',
    },
    {
      question: '为什么需要辅助功能权限？',
      answer: '用于响应全局快捷键、确认当前输入位置，并把文字送入输入框。麦克风权限只用于录音。',
    },
  ],
}

export const Route = createFileRoute('/')({
  head: () => homeHead(copy),
  component: () => <HomePage copy={copy} />,
})
