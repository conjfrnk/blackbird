# Homebrew Cask

`blackbird.rb` is the Homebrew Cask formula for installing Blackbird via
`brew install --cask blackbird`.

## Local test

Homebrew refuses casks loaded from a file path ("Homebrew requires casks
to be in a tap"), so test through a throwaway tap:

```sh
brew tap-new conjfrnk/local
mkdir -p "$(brew --repo conjfrnk/local)/Casks"
cp packaging/homebrew/blackbird.rb "$(brew --repo conjfrnk/local)/Casks/"
brew install --cask conjfrnk/local/blackbird
brew uninstall --cask blackbird
```

`brew audit` and `brew style` should both pass:

```sh
brew audit --new --cask --online conjfrnk/local/blackbird
brew style --cask conjfrnk/local/blackbird
```

Remove the tap afterwards with `brew untap conjfrnk/local`.

## Submit to homebrew/cask

```sh
# 1. Fork github.com/Homebrew/homebrew-cask
# 2. Work in Homebrew's own checkout of the tap (audit only accepts
#    casks that live in a tap, not bare paths), pointing it at your fork
brew tap --force homebrew/cask
cd "$(brew --repo homebrew/cask)"
git remote add <you> git@github.com:<you>/homebrew-cask.git
git checkout -b add-blackbird

# 3. Copy the cask in
cp /path/to/blackbird/packaging/homebrew/blackbird.rb Casks/b/blackbird.rb

# 4. Audit before pushing
brew audit --new --cask --online blackbird
brew style --cask blackbird

# 5. Open the PR with title "Add blackbird"
```

## On every release

`scripts/publish-update.sh` generates and signs the appcast (via
`scripts/make-appcast.sh`) and bumps `version` and `sha256` in this
cask to the DMG it just verified, so there is nothing to edit by hand.

The cask's `livecheck` watches the appcast with the Sparkle strategy,
but the appcast carries a bare-integer build number, so the stock
strategy would report `"0.9.3,54"` (short version plus build) against
the cask's `version "0.9.3"`. The block therefore returns only
`short_version`; keep that in step with `version` if either changes.
Once Blackbird is in `homebrew/cask`, `livecheck` auto-detects new
versions and Homebrew's autobump bot bumps the cask — no manual PR per
release.
