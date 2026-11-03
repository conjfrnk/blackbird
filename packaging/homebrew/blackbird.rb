cask "blackbird" do
  version "0.9.4"
  sha256 "7d01f10271d300cc74e52a7e180a5e41a65e66c07ba4adbcdad061a9bea5ecd8"

  url "https://github.com/conjfrnk/blackbird/releases/download/v#{version}/Blackbird-#{version}.dmg"
  name "Blackbird"
  desc "Minimal, native terminal emulator"
  homepage "https://blackbird-terminal.com/"

  livecheck do
    url "https://blackbird-terminal.com/appcast.xml"
    # Plain :sparkle reports "<short>,<build>" ("0.9.3,54") because
    # sparkle:version is a bare integer; `version` here is the short
    # version alone (publish-update.sh seds it), so report just that.
    strategy :sparkle, &:short_version
  end

  auto_updates true
  depends_on macos: :sonoma

  app "Blackbird.app"

  zap trash: [
    # Written by the app itself, not by the installer.
    "~/.local/share/blackbird",  # shell-integration bootstrap
    "~/.local/state/blackbird",  # ssh terminfo-wrapper cache
    # Globbed because Apple's tic files it under the hex dir 78/, other
    # ncurses under x/.
    "~/.terminfo/*/xterm-kitty", # KittyTerminfo.swift
    "~/Library/Caches/dev.conjfrnk.blackbird",
    "~/Library/HTTPStorages/dev.conjfrnk.blackbird",
    "~/Library/Logs/Blackbird",
    "~/Library/Preferences/dev.conjfrnk.blackbird.plist",
    "~/Library/Saved Application State/dev.conjfrnk.blackbird.savedState",
  ]
end
