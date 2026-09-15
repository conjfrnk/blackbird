cask "blackbird" do
  version "0.9.0"
  sha256 "85de3ca220254b4e1351388e170275f86011853890bfac72b3699c5f29d6a10f"

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
