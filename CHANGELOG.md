# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **The page is inventory now.** For too long the exchange sold one surface: log lines. HTML responses now carry host-read `[AD]` placements in their comment layer (`<!-- [AD] ... -->`), drawing from the same campaigns and settling to the same ledger as your logs. One book of business, two surfaces. New `html_probability` config (default `0.05`, its own dial because a page render is a rarer, higher-value event than a per-line log impression) and `SPONSORED_LOGS_HTML_PROBABILITY` env var; in Rails the controller surface wires itself on and stays dark until sponsoring is active. Brand safety holds: a crafted creative can't break out of its comment and into live markup, since every `--` run is defused so no placement escapes its slot. This is tier 1, the page; the per-component surface is next ([#23](https://github.com/sponsoredlogs/sponsored_logs/pull/23))
- **A page is not one placement, it is many.** Tier 2 opens the per-partial surface: every rendered partial is a component, and every component is inventory. A rendered partial now carries an optional `<!-- [AD] ... -->` comment, so component-dense pages fill at the component level. Same campaigns, same ledger as logs and pages. Opt-in and off by default behind a new `partial_ads` flag (and `SPONSORED_LOGS_PARTIAL_ADS`), because tier 2 is a bolder buy than the page. A conservative guard decorates only ordinary HTML element markup and skips script bodies, JSON blobs, SVG documents, and trivial fragments, so a placement never lands where it would corrupt the payload. Engine-agnostic by construction: the hook reads the rendered output string, so ERB, HAML, and Slim are billed identically ([#24](https://github.com/sponsoredlogs/sponsored_logs/pull/24))

## [0.4.0] - 2026-09-10

### Added

- **Identity is a moat.** Copy is a draft, not an account — an advertiser that rewrites its line is not a new advertiser. Every ad takes an optional `id`; set it and impressions, spend, and cap ride through a mid-flight rewrite, omit it and `id` falls back to a content hash of the text so nothing already booked moves. Two advertisers can even run the same line as separate books. Works in the JSON ads file

### Changed

- **The ledger settles by account, not by copy.** The store snapshot is now `{ id => {text:, impressions:, cpm:} }` — text rides along as a label so the Command Center still reads in plain English, but caps and reporting key on `id` end to end. Custom stores must return the new shape
- **`text_digest` retires; `ad_id` takes the desk.** The ActiveRecord ledger keys on `ad_id`, which for a no-id ad is exactly the old text digest, so existing rows line up untouched. Existing installs rerun `rails g sponsored_logs:install` (or rename the column and its unique index). The Redis store keys on `id` too, so existing Redis tallies reset once on upgrade

## [0.3.1] - 2026-09-10

### Fixed

- **Fill integrity is a moat.** A `NaN` bid is not demand — it's a tourist. It used to slip past the guard into `weighted_pick` and stall the whole rotation. Now non-finite bids (`NaN`, `±Infinity`) bill at zero where they belong, and the exchange keeps clearing. We don't let bad actors set the price
- **Brand safety is table stakes.** A creative that forges its own `ERROR` line isn't a placement — it's fraud with ambitions. Control characters, DEL, and the sneaky Unicode separators (U+2028/U+2029) now collapse to a space before serving. Punctuation, em-dashes, and emoji survive. The exploit does not

## [0.3.0] - 2026-09-07

### Fixed

- Marketing site: sponsor placements in the demo terminal are now delivered reliably. Renamed inventory-bearing CSS classes so client-side ad blockers can no longer suppress the platform's own impressions, and corrected the log-line layout so each placement occupies its own row ([#4](https://github.com/sponsoredlogs/sponsored_logs/pull/4))

### Added

- Brand-safe gilding of the `[AD]` prefix: on a live terminal the tag now renders in premium 256-color gold (`\e[38;5;214m … \e[0m`), turning a plain tag into an above-the-fold trust signal. The escape codes are zero-width, so banner borders stay byte-for-byte aligned. Gilding is delivered only to a real TTY with color enabled — files, pipes, and `Logger` sinks receive the byte-identical plain line, and the [`NO_COLOR`](https://no-color.org) convention (any non-empty value) suppresses `:auto`. New `color` config option and `SPONSORED_LOGS_COLOR` env var accept `:auto` (default — TTY + `NO_COLOR`-clear), `:always` (force gold, overrides `NO_COLOR`), or `:never` (plain everywhere); unrecognized values settle to `:auto`
- Self-sponsoring house ads — remnant fill so no impression goes to waste. The built-in list splits into `Advertisers::PAID_ADS` (the ten real-brand creatives) and `Advertisers::HOUSE_ADS` (three SponsoredLogs creatives at `weight: 1`, `cpm: 0.0`); `Advertisers::DEFAULT_ADS` is now their sum (13 rows). House ads compete in the default rotation (~3-in-13) and act as the final remnant floor when no paid creative is eligible (empty/capped/out-of-flight/zero-weight pool), so `pick` returns a creative rather than `nil`. They bill at zero and roll up to a `"SponsoredLogs"` advertiser account with zero spend. New `house_ads` config toggle (default `true`) and `SPONSORED_LOGS_HOUSE_ADS` env var govern house inventory everywhere: turning it off excludes house ads from rotation and retires the floor, restoring the original `pick`-returns-`nil`-when-exhausted contract
- Activated sponsor inventory across the project's own documentation surface: the README and this changelog now carry host-read placements between sections. Premium above-the-fold attention should not go unmonetized simply because it happens to be ours
- Per-ad `format: :banner` — premium box-drawn, multi-line placement that turns a single log line into a full above-the-fold impression unit. The `ad_prefix` embeds in the top border; the ~60-column body word-wraps (long words break mid-word so nothing overflows the frame). Inventory is optimized for standard-width Latin creative — emoji/CJK copy renders wider than one cell and may shift the right border, with `ascii_only` as the portable fallback
- Per-ad `box` impact tier for banners: `:light` (standard), `:heavy` (premium impact), or `:double` (maximum impact); unrecognized tiers settle to `:light`
- Global `ascii_only` config (and `SPONSORED_LOGS_ASCII_ONLY` env var) that overrides every box tier with the portable `+`/`-`/`|` glyph set for log sinks that mangle Unicode
- Per-ad `advertiser` field so creatives roll up to an advertiser account — the multi-tenant yield layer the exchange has been waiting for; defaults to `"Unattributed"` when omitted, and the built-in ads carry real brand names ([#1](https://github.com/sponsoredlogs/sponsored_logs/pull/1))
- `report[:advertisers]` rollup: per-advertiser impressions, spend, and ad count, sorted by spend so top accounts surface first ([#1](https://github.com/sponsoredlogs/sponsored_logs/pull/1))
- Dashboard "Advertiser accounts" table and an Advertiser column on the campaign tables ([#1](https://github.com/sponsoredlogs/sponsored_logs/pull/1))
- Share-of-impressions donut alongside the share-of-spend donut; both cap at the top 7 non-zero advertisers and fold the remainder into an "Other" slice ([#1](https://github.com/sponsoredlogs/sponsored_logs/pull/1))

### Changed

- Charts now aggregate by advertiser instead of per-ad, so labels are advertiser names rather than ad copy ([#1](https://github.com/sponsoredlogs/sponsored_logs/pull/1))
- The gold gradient now accents the totals card values (the spend/impressions bar chart it previously filled has been removed as redundant with the share-of-spend donut) ([#1](https://github.com/sponsoredlogs/sponsored_logs/pull/1))

### Removed

- Redundant "Spend by advertiser" bar chart (superseded by the share-of-spend donut) and the now-unused bar-chart helper ([#1](https://github.com/sponsoredlogs/sponsored_logs/pull/1))
- Support for Ruby 3.1: dropped from the CI matrix, `required_ruby_version` raised to `>= 3.2`, and RuboCop's `TargetRubyVersion` aligned to match. Rails 8.1 no longer resolves on 3.1 ([#3](https://github.com/sponsoredlogs/sponsored_logs/pull/3))

## [0.2.0] - 2026-09-06

### Added

- The "Command Center" — a dark-mode revenue dashboard styled to match the project banner (navy gradient, gold/cyan accents, monospace numerics, terminal chrome). Stop grepping your revenue; start visualizing it
- Share-of-spend donut chart, so yield concentration is legible at a glance
- Delivery-to-goal pacing bars that track each campaign against its impression cap — governance is a feature

### Changed

- Refreshed the dashboard screenshot in the README to reflect the Command Center
- Reordered the README to lead with the Agentic Advantage, and sprinkled emoji throughout — the machine audience deserves a warm welcome

> `[AD]` This release cycle sponsored by **ShipFaster CI** — because your
> changelog should ship as fast as your excuses. shipfaster.dev/logs

## [0.1.0] - 2026-09-06

### Added

- Initial platform launch: opt-in activation of log inventory via `SponsoredLogs.sponsor!`, which prepends override modules onto `Kernel#puts` and `Logger#add` to serve placements alongside your telemetry
- Two-stage auction: weighted or CPM-based (`selection: :cpm`) message selection, so the highest bidder wins more inventory
- Per-ad campaign controls — `weight`, `cpm`, flighting (`starts_at` / `ends_at`), and a lifetime impression `cap` (frequency governance)
- Bring-your-own-demand pools, inline (`ads:`) or from a JSON file (`ads_file:`)
- Full-funnel attribution: `SponsoredLogs.report` for structured revenue data, plus a formatted `SponsoredLogs.report_text` table
- Pluggable, cloud-agnostic impression storage: `Ledger::Store::Memory` (default), `Ledger::Store::Redis`, and `Ledger::Store::ActiveRecord` (with an `install` generator)
- Mountable Rails report engine (`SponsoredLogs::Engine`) exposing an HTML dashboard and JSON API, gated by `config.report_page`
- Running / upcoming / finished campaign grouping with flight status badges
- Activation and configuration via environment variables (`SPONSORED_LOGS`, `SPONSORED_LOGS_*`) and a Railtie for zero-friction Rails onboarding
- GitHub Actions CI across Ruby 3.1–4.0 and RuboCop — excellence is a discipline, not a moment

### Notes

- Requires Ruby >= 3.1

[Unreleased]: https://github.com/sponsoredlogs/sponsored_logs/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/sponsoredlogs/sponsored_logs/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/sponsoredlogs/sponsored_logs/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/sponsoredlogs/sponsored_logs/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/sponsoredlogs/sponsored_logs/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/sponsoredlogs/sponsored_logs/releases/tag/v0.1.0
