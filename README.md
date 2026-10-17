<p align="center">
  <img src="Resources/icon-256.png" width="128" alt="algobuddy icon">
</p>

<h1 align="center">algobuddy</h1>

A macOS menu bar app that watches your Algorand participation accounts and warns you before it costs you money.

**No node access. No token. No credentials of any kind.** Paste an address and it works, because everything it shows is public chain data.

<p align="center">
  <img src="docs/panel.png" width="360" alt="The algobuddy panel showing an online, earning account">
</p>

## What it watches

- **Participation keys**: countdown to `vote-last-valid`, warning at 14 days
- **Heartbeat challenge**: every 1000 rounds roughly 1 online account in 32 is challenged and must prove liveness within ~9 minutes. algobuddy computes this locally from the block seed and your address, and alerts if you're failing one
- **Absenteeism**: how much silence the protocol allows before suspension
- **Eligibility**: Online but not incentive-eligible, or a balance outside the 30,000 to 70M ALGO payout window
- **Proposals and payouts**: blocks and ALGO over 24h and 7d

## Install

Requires **macOS 14 or later** and a Swift 6 toolchain (`xcode-select --install` if you've never built anything).

```bash
git clone https://github.com/mrcointreau/algobuddy.git
cd algobuddy
make install
```

That compiles on your machine and installs to `/Applications`. Building locally means Gatekeeper never gets involved: the quarantine attribute is only applied to downloaded files.

Then open it, paste an Algorand address, and optionally tick **Open at login** in the General pane of Settings.

## Updating

The General pane of Settings (⌘,) has a **Check for Updates** button. It asks GitHub for the latest release tag, compares it with the running version, and tells you which is newer. That request goes to `api.github.com`, carries nothing about you, and happens only when you click: there is no background check. Nothing is downloaded or run, so updating is still yours to do:

```bash
cd algobuddy
git pull
make install
```

That quits the running app, rebuilds from the new source, and reinstalls; open it again from `/Applications`. Your settings survive. Because every build carries a fresh ad-hoc signature, macOS may ask for notification permission again after an update.

## Uninstall

If you ticked **Open at login**, untick it first: only the app itself can withdraw that registration, so doing it afterwards means clearing a leftover entry in System Settings instead.

```bash
make uninstall   # quits it and removes the app, keeping your settings
make purge       # the same, and also forgets the addresses, settings and HTTP cache
```

## Configuration

Everything lives in Settings (⌘,), in four panes, and the window reopens on the pane you used last:

- **General**: open at login, notifications (on by default), the running build, and a manual check for a newer release
- **Accounts**: the addresses to watch, added and removed a row at a time, each with an optional name of up to 32 characters. There's no limit on how many; each one adds a request to every poll. With more than one, the panel lists them with their totals, and each opens its own page. A name labels its account in the panel and in notifications, and stays visible when values are hidden (⌘P). Names are stored on your Mac and never sent anywhere
- **Menu Bar**: which metrics to show, with a live width estimate. A wide menu bar item isn't shortened on a notched display, it's hidden entirely
- **Data Source**: algod and indexer URLs, defaulting to a public provider. Point them at your own node if you'd rather not have a third party see which addresses you watch. algobuddy sends no token, so your node must serve the API without one, as public providers do

## What it deliberately doesn't do

- **Need your node.** It reads public chain data, from a public provider by default, so it never asks for SSH, a tunnel, a VPN or an exposed endpoint, and never asks you to change `config.json` or install anything on the machine running algod. Pointing it at an algod you run is a choice for privacy, not a requirement.
- **Hold keys.** It signs nothing and submits nothing.
- **Store secrets.** There are none to store.
- **Update itself.** The update check reads a version number and shows you a link. It downloads no code and runs nothing; `make install` stays a command you type.

The cost is that it can't tell you your node is down until the chain notices, which in practice is the next challenge, roughly a day. The benefit is that installing it risks nothing.

## Licence

MIT. See [LICENSE](LICENSE).
