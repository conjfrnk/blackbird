cask "blackbird" do
  version "0.8.1"
  sha256 "88a3c705a65822414c0cdd72bd52a52104cfaee06f7ea20acd90a38297863d8a"

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
