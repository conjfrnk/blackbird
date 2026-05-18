# Homebrew Cask

`blackbird.rb` is the Homebrew Cask formula for installing Blackbird via
`brew install --cask blackbird`.

## Local test

```sh
brew install --cask --no-quarantine ./packaging/homebrew/blackbird.rb
brew uninstall --cask blackbird
brew install --cask ./packaging/homebrew/blackbird.rb     # re-install with quarantine
```

`brew audit` and `brew style` should both pass:

```sh
brew audit --new-cask ./packaging/homebrew/blackbird.rb
brew style ./packaging/homebrew/blackbird.rb
```

## Submit to homebrew/cask

```sh
# 1. Fork github.com/Homebrew/homebrew-cask
# 2. Clone it locally, branch from master
git clone git@github.com:<you>/homebrew-cask.git
cd homebrew-cask
git checkout -b add-blackbird

# 3. Copy the cask in
cp /path/to/blackbird/packaging/homebrew/blackbird.rb Casks/b/blackbird.rb

# 4. Audit before pushing
brew audit --new --online --token-conflicts Casks/b/blackbird.rb
brew style Casks/b/blackbird.rb

# 5. Open the PR with title "Add blackbird"
```

## On every release

`scripts/publish-update.sh` generates and signs the appcast (via
`scripts/make-appcast.sh`). Once Blackbird is in `homebrew/cask`,
`livecheck` (Sparkle strategy) auto-detects new versions from the
appcast and the cask gets bumped by Homebrew's autobump bot — no
manual PR per release.

For the in-tree copy here, bump `version` and `sha256` when cutting a
release so contributors testing locally get the right artifact. The
sha256 can be obtained from `shasum -a 256 dist/Blackbird-<ver>.dmg`
after `scripts/cut-release.sh` produces the DMG.
