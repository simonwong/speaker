cask "speaker" do
  version "0.9.0,207"
  sha256 "1469ca6ffe64612cca1eb85d1eed00c2647e95f953b9af5c053f5782d275a833"

  url "https://github.com/simonwong/speaker/releases/download/v#{version.csv.first}/Speaker-#{version.csv.first}-#{version.csv.second}.dmg"
  name "Speaker"
  desc "Voice input that turns speech into text in any app"
  homepage "https://speaker.moonunder.app/"

  livecheck do
    url "https://github.com/simonwong/speaker/releases/latest/download/appcast.xml"
    strategy :sparkle
  end

  auto_updates true
  depends_on macos: :sonoma

  app "Speaker.app"

  uninstall quit: "app.moonunder.speaker"

  # Keychain items and the login item cannot be removed here; see PRIVACY.md.
  zap trash: [
    "~/Library/Application Support/com.local.speaker",
    "~/Library/Application Support/Speaker",
    "~/Library/Caches/app.moonunder.speaker",
    "~/Library/Caches/cn.simonwong.speaker",
    "~/Library/Caches/com.local.speaker",
    "~/Library/Caches/Speaker",
    "~/Library/Preferences/app.moonunder.speaker.plist",
    "~/Library/Preferences/cn.simonwong.speaker.plist",
    "~/Library/Preferences/com.local.speaker.plist",
    "~/Library/Saved Application State/app.moonunder.speaker.savedState",
    "~/Library/Saved Application State/cn.simonwong.speaker.savedState",
    "~/Library/Saved Application State/com.local.speaker.savedState",
  ]
end
