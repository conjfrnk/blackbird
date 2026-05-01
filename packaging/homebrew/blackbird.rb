cask "blackbird" do
  version "0.2.0"
  sha256 "30ea5b476964846dc95aa9e885634e96f9386b57d675a73db4075c10354679c5"

  url "https://github.com/conjfrnk/blackbird/releases/download/v#{version}/Blackbird-#{version}.dmg",
      verified: "github.com/conjfrnk/blackbird/"
  name "Blackbird"
  desc "Minimal, native terminal emulator for macOS"
  homepage "https://blackbird-terminal.com/"

  livecheck do
    url "https://blackbird-terminal.com/appcast.xml"
    strategy :sparkle
  end

  auto_updates true
  depends_on macos: ">= :sonoma"

  app "Blackbird.app"

  zap trash: [
    "~/Library/Logs/Blackbird",
    "~/Library/Preferences/dev.conjfrnk.blackbird.plist",
    "~/Library/Saved Application State/dev.conjfrnk.blackbird.savedState",
    "~/Library/HTTPStorages/dev.conjfrnk.blackbird",
    "~/Library/Caches/dev.conjfrnk.blackbird",
  ]
end
