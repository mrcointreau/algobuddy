# Changelog

## [1.4.0](https://github.com/mrcointreau/algobuddy/compare/v1.3.0...v1.4.0) (2026-10-17)


### Features

* **app:** draw the Algorand mark for ALGO amounts ([#38](https://github.com/mrcointreau/algobuddy/issues/38)) ([34cea0c](https://github.com/mrcointreau/algobuddy/commit/34cea0c954f5abd2be345218245cd06f4931acec))
* **keys:** name the 320-round lead and the last valid round ([#39](https://github.com/mrcointreau/algobuddy/issues/39)) ([92bf359](https://github.com/mrcointreau/algobuddy/commit/92bf359b3da2684f8f397096f50dcce18beb29f9))
* **settings:** add toolbar panes and bordered text fields ([#36](https://github.com/mrcointreau/algobuddy/issues/36)) ([a44d5e1](https://github.com/mrcointreau/algobuddy/commit/a44d5e18b0017da1fb4bd564712fdb40fc3ab676))


### Bug Fixes

* **app:** keep a stale account row at its height ([#47](https://github.com/mrcointreau/algobuddy/issues/47)) ([1a9f05c](https://github.com/mrcointreau/algobuddy/commit/1a9f05c2321e3facbf491f9d498e762fd95aee0e))
* **app:** keep the menu bar width and mask the round when hiding ([#44](https://github.com/mrcointreau/algobuddy/issues/44)) ([21330a1](https://github.com/mrcointreau/algobuddy/commit/21330a1ae4a508cc2af56cedd010845072fb5dda))
* **core:** decode the Not Participating account status ([#43](https://github.com/mrcointreau/algobuddy/issues/43)) ([44ad866](https://github.com/mrcointreau/algobuddy/commit/44ad866b7d09feb6f606165fc03e271453745e29))
* keep a stale row's age current and test the menu bar in core ([#46](https://github.com/mrcointreau/algobuddy/issues/46)) ([8eccc38](https://github.com/mrcointreau/algobuddy/commit/8eccc3867f2a6b4809a88d6ac451f178ebb7d2c2))
* name the menu bar item for VoiceOver and harden polling ([#41](https://github.com/mrcointreau/algobuddy/issues/41)) ([c1c86f6](https://github.com/mrcointreau/algobuddy/commit/c1c86f6ba9ba4e14d951d36037fe66fcb4a8c828))

## [1.3.0](https://github.com/mrcointreau/algobuddy/compare/v1.2.0...v1.3.0) (2026-10-16)


### Features

* **app:** let each watched address carry an optional name ([#29](https://github.com/mrcointreau/algobuddy/issues/29)) ([d079337](https://github.com/mrcointreau/algobuddy/commit/d0793372c6001087bc30abc84b1576cc37188965))


### Bug Fixes

* **alerts:** stop severity flapping and endless reminders ([#19](https://github.com/mrcointreau/algobuddy/issues/19)) ([83f4c80](https://github.com/mrcointreau/algobuddy/commit/83f4c80ea05cf0020996fc2a7dd93828bbe640ac))
* **app:** align earning and key expiry with the alert rules ([#28](https://github.com/mrcointreau/algobuddy/issues/28)) ([4433f68](https://github.com/mrcointreau/algobuddy/commit/4433f6889d92cce5dd615a02618158e3af6f1b97))
* **app:** keep the menu bar item one width while data loads ([#33](https://github.com/mrcointreau/algobuddy/issues/33)) ([c4ba52a](https://github.com/mrcointreau/algobuddy/commit/c4ba52a6a541546eda0cfe06c42a95f821247dc5))
* **app:** keep the panel height steady while refreshing ([#30](https://github.com/mrcointreau/algobuddy/issues/30)) ([625ddbe](https://github.com/mrcointreau/algobuddy/commit/625ddbeee6dd91f49734fdc74fb3271d7fce82b7))
* **app:** keep the panel under its menu bar item ([#31](https://github.com/mrcointreau/algobuddy/issues/31)) ([d454acd](https://github.com/mrcointreau/algobuddy/commit/d454acd41ef53ece11957680f501875a3d149193))
* **app:** respect notification permission ([#26](https://github.com/mrcointreau/algobuddy/issues/26)) ([0d97a39](https://github.com/mrcointreau/algobuddy/commit/0d97a395f9278368960f41e1b2656e5c12019020))
* **app:** steady list rows, address notes and panel resizes ([#35](https://github.com/mrcointreau/algobuddy/issues/35)) ([8a906e6](https://github.com/mrcointreau/algobuddy/commit/8a906e6c37377a3e85381a53a375560edb98cf16))
* **core:** anchor the round clock and ignore short samples ([#34](https://github.com/mrcointreau/algobuddy/issues/34)) ([03bc60c](https://github.com/mrcointreau/algobuddy/commit/03bc60c8fbdfe57ab79f1a5ba54c0a5958630b8e))
* **core:** name failed requests and mark partial totals ([#27](https://github.com/mrcointreau/algobuddy/issues/27)) ([13ecb4c](https://github.com/mrcointreau/algobuddy/commit/13ecb4cfa1fdf9ca1b23c7599a5569e285e7ff22))
* **core:** use a private URL session with a request deadline ([#23](https://github.com/mrcointreau/algobuddy/issues/23)) ([659e998](https://github.com/mrcointreau/algobuddy/commit/659e9985b2e046f3cbe75cd0ef821ce5d32aed91))
* **poller:** fetch proposals without delaying account alerts ([#24](https://github.com/mrcointreau/algobuddy/issues/24)) ([5bf6c20](https://github.com/mrcointreau/algobuddy/commit/5bf6c2056c38b1219d59a981b68513d72fa7a8bd))
* **poller:** ignore indexer rounds beyond the chain tip ([#21](https://github.com/mrcointreau/algobuddy/issues/21)) ([ba8ef0a](https://github.com/mrcointreau/algobuddy/commit/ba8ef0aa3ca83a53db8e38ff4f2664f79c594499))
* **poller:** keep failed accounts visible and alert on them ([#22](https://github.com/mrcointreau/algobuddy/issues/22)) ([850c4bb](https://github.com/mrcointreau/algobuddy/commit/850c4bbfe2c6302b29caa16e47f691ba14261682))
* **poller:** show proposals as soon as they arrive ([#32](https://github.com/mrcointreau/algobuddy/issues/32)) ([0c39bc3](https://github.com/mrcointreau/algobuddy/commit/0c39bc3b49d85c527fc4fa04f1d7be2ee3a91f3c))
* **settings:** validate URLs, apply removals, scroll the form ([#25](https://github.com/mrcointreau/algobuddy/issues/25)) ([3c0317e](https://github.com/mrcointreau/algobuddy/commit/3c0317eded408d41b72367588cfac6e3893cd561))

## [1.2.0](https://github.com/mrcointreau/algobuddy/compare/v1.1.0...v1.2.0) (2026-10-06)


### Features

* **app:** present a portfolio of accounts in panel and menu bar ([#16](https://github.com/mrcointreau/algobuddy/issues/16)) ([31907db](https://github.com/mrcointreau/algobuddy/commit/31907dbe20f6326bf2fa02058ac8f67ec65b3751))
* **app:** watch several accounts from Settings and the panel ([#17](https://github.com/mrcointreau/algobuddy/issues/17)) ([02472a7](https://github.com/mrcointreau/algobuddy/commit/02472a7471493640acbcabcdad777bac4d60ea96))
* **core:** watch multiple addresses in one poller ([#14](https://github.com/mrcointreau/algobuddy/issues/14)) ([a111c06](https://github.com/mrcointreau/algobuddy/commit/a111c06fd91e9a46eab13ee0ae3cb2c9af0f5089))

## [1.1.0](https://github.com/mrcointreau/algobuddy/compare/v1.0.1...v1.1.0) (2026-08-21)


### Features

* **settings:** add a manual check for updates ([#8](https://github.com/mrcointreau/algobuddy/issues/8)) ([5ccf532](https://github.com/mrcointreau/algobuddy/commit/5ccf532596be7bafa6199292dd327b1493de612c))

## [1.0.1](https://github.com/mrcointreau/algobuddy/compare/v1.0.0...v1.0.1) (2026-08-21)


### Bug Fixes

* **absence:** keep ratio consistent with isAbsent at zero lag ([2b2090d](https://github.com/mrcointreau/algobuddy/commit/2b2090d50a45135f959b8c56f94b0e59d033baff))
* **absence:** keep ratio consistent with isAbsent at zero lag ([85c6a60](https://github.com/mrcointreau/algobuddy/commit/85c6a60869b3b6586799104a5a96ce3a4729247d))

## 1.0.0 (2026-08-20)


### Features

* initial commit ([55ecac1](https://github.com/mrcointreau/algobuddy/commit/55ecac12ed0a93463d36ead086bc77ddea04a337))

## Changelog

Notable changes to algobuddy. Entries are generated from [Conventional Commit](https://www.conventionalcommits.org) subjects by release-please; versions follow [Semantic Versioning](https://semver.org).
