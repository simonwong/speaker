import { createFileRoute } from '@tanstack/react-router'
import { PRIVACY_URL, RELEASE_NOTES_URL, SITE_URL } from '../components'
import { DOWNLOAD_URL, type HomeCopy, HomePage, homeHead } from '../home'

const copy: HomeCopy = {
  lang: 'en',
  title: 'Speaker: Free, Open-Source Voice Typing and Dictation for Mac',
  description:
    'Speaker is a free, open-source dictation app for Mac. Hold Fn in any text field, speak, and release to type at the cursor. Bring your own OpenAI, Qwen, or Doubao API key, or use Apple on-device speech recognition on macOS 26. No account, no server. macOS 14 or later.',
  ogImage: `${SITE_URL}og-en.png`,
  ogImageAlt: 'Speaker: voice typing for Mac. Talk instead of type.',
  priceCurrency: 'USD',
  requirements: 'macOS 14 or later on Apple silicon or Intel; Apple speech recognition requires macOS 26',
  iconAlt: 'Speaker app icon',
  otherLanguage: { lang: 'zh-CN', label: '简体中文' },
  headline: (
    <>
      Voice typing for Mac.
      <br />
      Talk instead of type.
    </>
  ),
  lede: (
    <>
      Hold <kbd>Fn</kbd> in any text field and speak. Release, and the text appears at the cursor. Use your own API key or
      Apple on-device recognition. No account, no server.
    </>
  ),
  downloadLabel: 'Download for Mac',
  meta: 'macOS 14 or later · Apple silicon and Intel · Free and open source (MIT) · Interface in Simplified Chinese',
  sections: [
    {
      id: 'voice-to-text',
      title: 'Speech to text in any app',
      body: (
        <>
          <p>
            Hold <kbd>Fn</kbd> while you talk and release to finish, or tap once to start and again to stop. The shortcut is
            configurable, and <kbd>Esc</kbd> cancels.
          </p>
          <p>
            Text goes only to the field that was focused when recording ended, so switching windows afterwards never sends
            it to the wrong place. If Speaker cannot type into that field, the result stays in an overlay for you to copy.
          </p>
          <p>
            While text is being refined, you can choose to use the raw transcript instead. The menu bar keeps your five most
            recent results, one click to copy.
          </p>
          <p>Add names and technical terms to your personal dictionary so recognition spells them your way.</p>
        </>
      ),
    },
    {
      id: 'api-key',
      title: 'Choose your speech recognition',
      body: (
        <>
          <p>
            Cloud recognition: OpenAI, Alibaba Qwen, or Doubao (ByteDance). OpenAI and Qwen can stream while you speak or
            upload once you finish. Doubao requires a Volcengine account; see the{' '}
            <a href="/doubao" hrefLang="zh-CN">
              Doubao setup guide
            </a>{' '}
            (in Chinese).
          </p>
          <p>
            On macOS 26 and later you can choose Apple speech recognition instead. It runs on your Mac, needs no API key, and
            your audio never leaves the device. Download the language model in Settings before first use.
          </p>
          <p>Optional text refinement works with DeepSeek, OpenAI, Kimi, GLM, or any compatible custom endpoint.</p>
          <p>Keys are stored in the macOS Keychain, and requests go straight from your Mac to the provider.</p>
        </>
      ),
    },
    {
      id: 'refine',
      title: 'Custom refinement modes',
      body: (
        <>
          <p>
            By default Speaker types the recognition result as is. You can also pick concise cleanup, full rewrite, or write
            your own instruction.
          </p>
          <p>
            Refinement sends text only, never audio. If it fails, you still get the recognition result. Mixed-language speech
            keeps each part in the language you spoke it in.
          </p>
        </>
      ),
    },
    {
      id: 'privacy',
      title: 'No servers of ours in between',
      body: (
        <>
          <p>
            Speaker has no backend. Audio and text go only to the providers you choose. With Apple speech recognition, audio
            stays on your Mac.
          </p>
          <p>
            Settings, your dictionary, and history are stored only on this Mac. Text typed into password fields is never
            saved. Audio is processed in memory and never written to disk. See the{' '}
            <a href={PRIVACY_URL}>privacy notes</a>.
          </p>
        </>
      ),
    },
    {
      id: 'install',
      title: 'Download and install',
      body: (
        <ol className="install">
          <li>
            <a href={DOWNLOAD_URL}>Download the latest DMG</a>. Older versions are on{' '}
            <a href={RELEASE_NOTES_URL}>GitHub Releases</a>.
          </li>
          <li>Drag Speaker to Applications and open it.</li>
          <li>Follow the setup to grant Microphone and Accessibility access.</li>
          <li>Choose a recognition service and paste its API key, or download the model for Apple speech recognition.</li>
          <li>Try it in the practice field on the last setup step. Later versions update from inside the app.</li>
        </ol>
      ),
    },
  ],
  compare: {
    title: 'Speaker vs. macOS Dictation',
    aspectLabel: 'Aspect',
    columns: ['Speaker', 'macOS Dictation'],
    rows: [
      ['How to start', 'Shortcut in any text field', 'System dictation shortcut'],
      ['Who hears your voice', 'The provider you pick, or Apple on-device', 'Apple'],
      ['Cost', 'App is free; cloud recognition is billed by your provider; Apple on-device is free', 'Free'],
      ['Text cleanup', 'Your choice of provider and instructions', 'Not available'],
      ['Dictionary and history', 'Yes, stored on your Mac', 'No'],
      ['Open source', 'MIT', 'No'],
    ],
  },
  faqTitle: 'FAQ',
  faqs: [
    {
      question: 'Is Speaker free?',
      answer:
        'Yes. Speaker is free and open source under the MIT license. Cloud recognition and refinement are billed by the provider you choose, based on usage. Apple speech recognition runs on your Mac at no cost.',
    },
    {
      question: 'Can I use it without an API key?',
      answer:
        'On macOS 26 and later, choose Apple speech recognition. It runs on device and needs no key; download the language model and start talking. On macOS 14 and 15 you need an OpenAI, Qwen, or Doubao key.',
    },
    {
      question: 'Is the app available in English?',
      answer:
        'The interface is currently in Simplified Chinese only. Recognition is not limited to Chinese: OpenAI and Qwen support many languages, Doubao handles Chinese and English, and Apple speech recognition uses the first supported language in your system preferences.',
    },
    {
      question: 'How is it different from macOS Dictation?',
      answer:
        'macOS Dictation always uses Apple recognition. Speaker lets you pick OpenAI, Qwen, Doubao, or Apple on-device recognition, and adds a personal dictionary, text refinement, and local history.',
    },
    {
      question: 'Pressing Fn opens the emoji picker or switches input source. What do I do?',
      answer:
        'macOS has assigned another action to the Fn (globe) key. Speaker detects this and offers to open Keyboard settings, where you can set "Press 🌐 key to" to "Do Nothing". You can also pick a different shortcut in Speaker.',
    },
    {
      question: 'Will macOS let me open it?',
      answer: 'Yes. Speaker is signed with an Apple Developer ID and notarized by Apple. Confirm once on first launch.',
    },
    {
      question: 'Why does it need Accessibility access?',
      answer:
        'To respond to the global shortcut, check where you are typing, and insert text into that field. Microphone access is used only for recording.',
    },
  ],
}

export const Route = createFileRoute('/en')({
  head: () => homeHead(copy),
  component: () => <HomePage copy={copy} />,
})
