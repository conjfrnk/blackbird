cask "blackbird" do
  version "0.9.2"
  sha256 "3909c7a1189403fadf0d1577b21d1ec73ddff60a539cd753094f8d485bc6a58c"

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
    # Written by the app itself, not by the installer:
    "~/.terminfo/x/xterm-kitty",        # KittyTerminfo.swift
    "~/.local/share/blackbird",         # shell-integration bootstrap
    "~/.local/state/blackbird",         # ssh terminfo-wrapper cache
  ]
end
