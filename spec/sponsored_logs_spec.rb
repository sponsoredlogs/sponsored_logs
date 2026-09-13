# frozen_string_literal: true

require "stringio"
require "logger"
require "tempfile"
require "digest"

RSpec.describe SponsoredLogs do
  describe ".sponsor! and .unsponsor!" do
    it "toggles the active flag", :aggregate_failures do
      expect(described_class.active?).to be(false)

      described_class.sponsor!
      expect(described_class.active?).to be(true)

      described_class.unsponsor!
      expect(described_class.active?).to be(false)
    end

    it "installs the injector patches on first sponsor" do
      described_class.sponsor!
      expect(SponsoredLogs::Injector).to be_installed
    end

    it "applies inline configuration overrides", :aggregate_failures do
      described_class.sponsor!(probability: 0.5, interval: 7)

      expect(described_class.configuration.probability).to eq(0.5)
      expect(described_class.configuration.interval).to eq(7)
    end

    it "accepts an explicit options hash", :aggregate_failures do
      described_class.sponsor!({ probability: 0.25, ad_prefix: "YO:" })

      expect(described_class.configuration.probability).to eq(0.25)
      expect(described_class.configuration.ad_prefix).to eq("YO:")
    end
  end

  describe "Configuration#assign" do
    let(:config) { SponsoredLogs::Configuration.new }
    let(:sink) { StringIO.new }

    it "applies direct settings", :aggregate_failures do
      config.assign({ probability: 0.4, selection: :cpm }, warn_to: sink)

      expect(config.probability).to eq(0.4)
      expect(config.selection).to eq(:cpm)
    end

    it "accepts string keys" do
      config.assign({ "probability" => 0.6 }, warn_to: sink)
      expect(config.probability).to eq(0.6)
    end

    it "leaves unspecified settings untouched", :aggregate_failures do
      config.assign({ probability: 0.9 }, warn_to: sink)

      expect(config.probability).to eq(0.9)
      expect(config.ad_prefix).to eq("[AD]") # default preserved
    end

    it "warns on an unknown key rather than raising", :aggregate_failures do
      expect { config.assign({ bogus: 1 }, warn_to: sink) }.not_to raise_error
      expect(sink.string).to include("unknown setting")
      expect(sink.string).to include("bogus")
    end

    it "resolves ads_file into ads" do
      Tempfile.create(["ads", ".json"]) do |f|
        f.write('{"ads": [{"text": "FromFile", "weight": 1}]}')
        f.flush
        config.assign({ ads_file: f.path }, warn_to: sink)
      end

      expect(config.ads.first).to include(text: "FromFile", weight: 1.0, cpm: 0.0)
    end

    it "prefers an explicit ads list over ads_file" do
      config.assign({ ads: [{ text: "Inline", weight: 1 }], ads_file: "/no/such.json" }, warn_to: sink)

      expect(config.ads).to eq([{ text: "Inline", weight: 1 }])
    end
  end

  describe ".maybe_emit" do
    it "does nothing when inactive" do
      io = StringIO.new
      described_class.maybe_emit(target: io)
      expect(io.string).to be_empty
    end

    it "emits when active and the dice land in range" do
      io = StringIO.new
      described_class.sponsor!(probability: 1.0)

      described_class.maybe_emit(target: io)
      expect(io.string).to include("[AD]")
    end

    it "stays silent when probability is zero" do
      io = StringIO.new
      described_class.sponsor!(probability: 0.0)

      100.times { described_class.maybe_emit(target: io) }
      expect(io.string).to be_empty
    end
  end

  describe ".emit" do
    it "writes a tagged ad line to an IO target" do
      io = StringIO.new
      described_class.emit(io)
      expect(io.string).to match(/\A\[AD\] .+\n\z/)
    end

    it "returns the emitted line" do
      io = StringIO.new
      expect(described_class.emit(io)).to start_with("[AD]")
    end

    it "honors a custom ad_prefix" do
      io = StringIO.new
      described_class.sponsor!(ad_prefix: "SPONSORED:")
      described_class.emit(io)
      expect(io.string).to start_with("SPONSORED: ")
    end

    it "omits the prefix entirely when blank" do
      io = StringIO.new
      described_class.sponsor!(ad_prefix: "")
      described_class.emit(io)
      expect(io.string).not_to include("[AD]")
    end

    it "emits from a user-supplied ad list" do
      io = StringIO.new
      described_class.sponsor!(ads: [{ text: "Only ad in the pool", weight: 1 }])
      described_class.emit(io)
      expect(io.string).to eq("[AD] Only ad in the pool\n")
    end

    it "emits from an ads_file" do
      io = StringIO.new
      Tempfile.create(["ads", ".json"]) do |f|
        f.write('{"ads": [{"text": "From a file", "weight": 1}]}')
        f.flush
        described_class.sponsor!(ads_file: f.path)
      end
      described_class.emit(io)
      expect(io.string).to eq("[AD] From a file\n")
    end

    it "keeps the existing list when an ads_file fails to load" do
      io = StringIO.new
      described_class.sponsor!(ads: [{ text: "still here", weight: 1 }])
      described_class.sponsor!(ads_file: "/no/such.json") # warns, no-op on the list
      described_class.emit(io)
      expect(io.string).to eq("[AD] still here\n")
    end
  end

  describe ".emit log-injection hardening" do
    it "cannot forge a second log line from a newline in ad text", :aggregate_failures do
      io = StringIO.new
      described_class.sponsor!(ads: [{ text: "Legit copy\nERROR forged incident", weight: 1 }])
      described_class.emit(io)

      expect(io.string.count("\n")).to eq(1)
      expect(io.string).to end_with("\n")
      expect(io.string.chomp).not_to include("\n")
      expect(io.string).to include("ERROR forged incident")
    end

    it "cannot forge a second log line from a CRLF in ad text", :aggregate_failures do
      io = StringIO.new
      described_class.sponsor!(ads: [{ text: "Legit copy\r\nERROR forged incident", weight: 1 }])
      described_class.emit(io)

      expect(io.string.count("\n")).to eq(1)
      expect(io.string).not_to include("\r")
    end

    it "neutralizes escape and other control characters in ad text", :aggregate_failures do
      io = StringIO.new
      described_class.sponsor!(ads: [{ text: "Legit\e[31mcopy\u0000tail", weight: 1 }])
      described_class.emit(io)

      expect(io.string.chomp).not_to match(/[\u0000-\u001F\u007F]/)
      expect(io.string.count("\n")).to eq(1)
    end

    it "cannot forge a second log line from a U+2028 line separator", :aggregate_failures do
      io = StringIO.new
      described_class.sponsor!(ads: [{ text: "Legit copy\u2028ERROR forged incident", weight: 1 }])
      described_class.emit(io)

      expect(io.string).not_to include("\u2028")
      expect(io.string.count("\n")).to eq(1)
      expect(io.string).to include("ERROR forged incident")
    end

    it "cannot forge a second log line from a U+2029 paragraph separator", :aggregate_failures do
      io = StringIO.new
      described_class.sponsor!(ads: [{ text: "Legit copy\u2029ERROR forged incident", weight: 1 }])
      described_class.emit(io)

      expect(io.string).not_to include("\u2029")
      expect(io.string.count("\n")).to eq(1)
      expect(io.string).to include("ERROR forged incident")
    end
  end

  describe "configuration" do
    it "defaults ad_prefix to [AD]" do
      expect(described_class.configuration.ad_prefix).to eq("[AD]")
    end

    it "defaults ads to the built-in paid-plus-house list", :aggregate_failures do
      expect(described_class.configuration.ads).to eq(SponsoredLogs::Advertisers::DEFAULT_ADS)
      expect(described_class.configuration.ads.length).to eq(13)
    end

    it "defaults selection to :weight" do
      expect(described_class.configuration.selection).to eq(:weight)
    end
  end

  describe ".report" do
    it "starts empty", :aggregate_failures do
      described_class.reset_ledger!
      report = described_class.report

      expect(report[:impressions]).to eq(0)
      expect(report[:spend]).to eq(0.0)
      expect(report[:ads]).to eq([])
    end

    it "tallies impressions and accrues cpm-based spend", :aggregate_failures do
      described_class.reset_ledger!
      described_class.sponsor!(ads: [{ text: "Solo", weight: 1, cpm: 20.0 }])

      1000.times { described_class.emit(StringIO.new) }
      report = described_class.report

      expect(report[:impressions]).to eq(1000)
      # 1000 impressions / 1000 * $20 CPM = $20.00
      expect(report[:spend]).to be_within(0.0001).of(20.0)
      expect(report[:ads].first).to include(text: "Solo", impressions: 1000, cpm: 20.0)
      expect(report[:ads].first[:spend]).to be_within(0.0001).of(20.0)
    end

    it "reset_ledger! clears accrued totals" do
      described_class.sponsor!(ads: [{ text: "x", weight: 1, cpm: 5 }])
      described_class.emit(StringIO.new)
      described_class.reset_ledger!

      expect(described_class.report[:impressions]).to eq(0)
    end

    it "exposes an impressions_by_surface breakdown, with emit counted as :log", :aggregate_failures do
      described_class.reset_ledger!
      described_class.sponsor!(ads: [{ text: "Solo", weight: 1, cpm: 20.0 }])

      3.times { described_class.emit(StringIO.new) }
      report = described_class.report

      expect(report[:impressions_by_surface]).to eq(log: 3, page: 0, partial: 0, unknown: 0)
      expect(report[:impressions]).to eq(3)
    end

    it "lists scheduled ads under upcoming, even with zero impressions", :aggregate_failures do
      described_class.reset_ledger!
      described_class.sponsor!(ads: [
                                 { text: "Live now", weight: 1, cpm: 5 },
                                 { text: "Next month", weight: 1, cpm: 8, starts_at: "2999-01-01" }
                               ])
      described_class.configuration.store.record(text: "Live now", weight: 1, cpm: 5.0)

      report = described_class.report
      upcoming = report[:upcoming]

      expect(upcoming.map { |a| a[:text] }).to eq(["Next month"])
      expect(upcoming.first[:impressions]).to eq(0)
      expect(upcoming.first[:status]).to eq(:scheduled)
      expect(report[:ads].map { |a| a[:text] }).to eq(["Live now"])
    end

    it "rolls impressions and spend up by advertiser", :aggregate_failures do
      described_class.reset_ledger!
      described_class.sponsor!(ads: [
                                 { advertiser: "Acme", text: "Acme A", weight: 1, cpm: 10.0 },
                                 { advertiser: "Acme", text: "Acme B", weight: 1, cpm: 10.0 },
                                 { advertiser: "Globex", text: "Globex A", weight: 1, cpm: 20.0 }
                               ])
      1000.times { described_class.configuration.store.record(text: "Acme A", weight: 1, cpm: 10.0) }
      1000.times { described_class.configuration.store.record(text: "Acme B", weight: 1, cpm: 10.0) }
      1000.times { described_class.configuration.store.record(text: "Globex A", weight: 1, cpm: 20.0) }

      accounts = described_class.report[:advertisers]
      acme = accounts.find { |a| a[:advertiser] == "Acme" }
      globex = accounts.find { |a| a[:advertiser] == "Globex" }

      expect(acme[:ads]).to eq(2)
      expect(acme[:impressions]).to eq(2000)
      expect(acme[:spend]).to eq(20.0) # 2 * (1000/1000 * 10)
      expect(globex[:spend]).to eq(20.0)
      # Sorted by spend descending; Acme and Globex tie at 20 so both present.
      expect(accounts.map { |a| a[:advertiser] }).to contain_exactly("Acme", "Globex")
    end

    it "moves a capped-out ad into finished with :exhausted status", :aggregate_failures do
      described_class.reset_ledger!
      described_class.sponsor!(ads: [{ text: "Capped", weight: 1, cpm: 10, cap: 5 }])
      5.times { described_class.configuration.store.record(text: "Capped", weight: 1, cpm: 10.0) }

      report = described_class.report

      expect(report[:ads].map { |a| a[:text] }).not_to include("Capped")
      exhausted = report[:finished].find { |a| a[:text] == "Capped" }
      expect(exhausted).not_to be_nil
      expect(exhausted[:status]).to eq(:exhausted)
      expect(exhausted[:impressions]).to eq(5)
    end

    it "lists ended ads under finished, served or not", :aggregate_failures do
      described_class.reset_ledger!
      described_class.sponsor!(ads: [
                                 { text: "Ran and ended", weight: 1, cpm: 10, ends_at: "2000-01-01" },
                                 { text: "Never ran, ended", weight: 1, cpm: 10, ends_at: "2000-01-01" }
                               ])
      described_class.configuration.store.record(text: "Ran and ended", weight: 1, cpm: 10.0)

      finished = described_class.report[:finished]

      expect(finished.map { |a| a[:text] }).to contain_exactly("Ran and ended", "Never ran, ended")
      ran = finished.find { |a| a[:text] == "Ran and ended" }
      never = finished.find { |a| a[:text] == "Never ran, ended" }
      expect(ran[:impressions]).to eq(1)
      expect(never[:impressions]).to eq(0)
      expect(never[:status]).to eq(:ended)
    end

    it "enriches rows with flight window and status, grouping by status", :aggregate_failures do
      described_class.reset_ledger!
      described_class.sponsor!(ads: [
                                 { text: "Evergreen", weight: 1, cpm: 5 },
                                 { text: "Ended", weight: 1, cpm: 5, ends_at: "2000-01-01" }
                               ])
      # Force both to record regardless of liveness by writing to the store.
      described_class.configuration.store.record(text: "Evergreen", weight: 1, cpm: 5.0)
      described_class.configuration.store.record(text: "Ended", weight: 1, cpm: 5.0)

      report = described_class.report
      running = report[:ads].find { |a| a[:text] == "Evergreen" }
      ended = report[:finished].find { |a| a[:text] == "Ended" }

      expect(running[:status]).to eq(:evergreen)
      expect(running[:starts_at]).to be_nil
      expect(ended[:status]).to eq(:ended)
      expect(ended[:ends_at]).to be_a(Time)
    end

    it "rounds spend to cents", :aggregate_failures do
      described_class.reset_ledger!
      # 333 / 1000 * 13 = 4.329 -> rounds to 4.33
      described_class.sponsor!(ads: [{ text: "odd", weight: 1, cpm: 13.0 }])
      333.times { described_class.emit(StringIO.new) }
      report = described_class.report

      expect(report[:spend]).to eq(4.33)
      expect(report[:ads].first[:spend]).to eq(4.33)
    end
  end

  describe ".report_text" do
    it "renders a table with a header, rows, and a total", :aggregate_failures do
      described_class.reset_ledger!
      described_class.sponsor!(ads: [{ text: "Solo", weight: 1, cpm: 20.0 }])
      100.times { described_class.emit(StringIO.new) }

      text = described_class.report_text

      expect(text).to include("Ad")
      expect(text).to include("Impr")
      expect(text).to include("CPM")
      expect(text).to include("Spend")
      expect(text).to include("Solo")
      expect(text).to match(/TOTAL\s+100\s+2\.00/) # 100/1000 * 20 = 2.00
    end

    it "orders rows by descending spend" do
      described_class.reset_ledger!
      described_class.sponsor!(ads: [
                                 { text: "cheap", weight: 1, cpm: 1.0 },
                                 { text: "pricey", weight: 1, cpm: 99.0 }
                               ], selection: :cpm)
      1000.times { described_class.emit(StringIO.new) }

      text = described_class.report_text
      expect(text.index("pricey")).to be < text.index("cheap")
    end

    it "appends a per-surface breakdown line", :aggregate_failures do
      described_class.reset_ledger!
      described_class.sponsor!(ads: [{ text: "Solo", weight: 1, cpm: 20.0 }])
      5.times { described_class.emit(StringIO.new) }

      text = described_class.report_text

      expect(text).to include("By surface:")
      expect(text).to match(/By surface: log 5 \| page 0 \| partial 0 \| unknown 0/)
    end
  end

  describe "Advertisers" do
    it "provides exactly ten paid built-in ads" do
      expect(SponsoredLogs::Advertisers::PAID_ADS.length).to eq(10)
    end

    it "provides exactly three house ads" do
      expect(SponsoredLogs::Advertisers::HOUSE_ADS.length).to eq(3)
    end

    it "composes the default pool from paid plus house inventory", :aggregate_failures do
      expect(SponsoredLogs::Advertisers::DEFAULT_ADS.length).to eq(13)
      expect(SponsoredLogs::Advertisers::DEFAULT_ADS)
        .to eq(SponsoredLogs::Advertisers::PAID_ADS + SponsoredLogs::Advertisers::HOUSE_ADS)
    end

    def render(ads = nil, prefix: "[AD]", mode: :weight)
      if ads
        SponsoredLogs::Advertisers.render(SponsoredLogs::Advertisers.pick(ads, mode: mode), prefix)
      else
        SponsoredLogs::Advertisers.render(SponsoredLogs::Advertisers.pick, prefix)
      end
    end

    it "defaults to an [AD] tagged line" do
      expect(render).to start_with("[AD] ")
    end

    it "accepts a custom prefix" do
      expect(render(prefix: "YO:")).to start_with("YO: ")
    end

    it "samples from a supplied ad list" do
      expect(render([{ text: "Custom", weight: 1 }])).to eq("[AD] Custom")
    end

    it "falls back to defaults when the supplied list is empty", :aggregate_failures do
      expect(render([])).to start_with("[AD] ")
      expect(render([{ text: "", weight: 1 }])).to start_with("[AD] ")
    end

    it "falls back to defaults when every weight is zero" do
      zeroed = [{ text: "never", weight: 0 }]
      expect(render(zeroed)).not_to include("never")
    end

    it "never picks a zero-weighted ad when others are available" do
      pool = [
        { text: "picked", weight: 1 },
        { text: "skipped", weight: 0 }
      ]
      results = Array.new(200) { render(pool, prefix: "") }
      expect(results.uniq).to eq(["picked"])
    end

    it "honors relative weights", :aggregate_failures do
      pool = [
        { text: "common", weight: 9 },
        { text: "rare", weight: 1 }
      ]
      results = Array.new(3000) { render(pool, prefix: "") }
      common = results.count("common")

      # Expect roughly 90% common; assert a wide band to stay non-flaky.
      expect(common).to be > 2400
      expect(common).to be < 2999
    end

    it "picks by cpm in :cpm selection mode", :aggregate_failures do
      pool = [
        { text: "pricey", weight: 1, cpm: 90 },
        { text: "cheap", weight: 1, cpm: 10 }
      ]
      results = Array.new(3000) { render(pool, prefix: "", mode: :cpm) }
      pricey = results.count("pricey")

      expect(pricey).to be > 2400
      expect(pricey).to be < 2999
    end

    it "ignores cpm when in :weight mode" do
      pool = [
        { text: "high cpm low weight", weight: 0, cpm: 99 },
        { text: "picked", weight: 1, cpm: 1 }
      ]
      results = Array.new(200) { render(pool, prefix: "", mode: :weight) }
      expect(results.uniq).to eq(["picked"])
    end

    it "falls back to weights when :cpm mode has all-zero cpm" do
      pool = [
        { text: "picked", weight: 1, cpm: 0 },
        { text: "skipped", weight: 0, cpm: 0 }
      ]
      results = Array.new(200) { render(pool, prefix: "", mode: :cpm) }
      expect(results.uniq).to eq(["picked"])
    end

    it "never lets a non-finite weight poison weighted selection", :aggregate_failures do
      pool = [
        { text: "picked", weight: 1 },
        { text: "poison", weight: Float::NAN }
      ]
      results = Array.new(200) { render(pool, prefix: "") }
      expect(results.uniq).to eq(["picked"])
    end

    it "never lets a non-finite cpm poison :cpm selection", :aggregate_failures do
      pool = [
        { text: "picked", weight: 1, cpm: 5 },
        { text: "poison", weight: 1, cpm: Float::INFINITY }
      ]
      results = Array.new(200) { render(pool, prefix: "", mode: :cpm) }
      # Selection stays well-behaved: it always resolves to a real ad from the
      # pool and never stalls or emits a NaN-poisoned line.
      #
      expect(results).to all(satisfy { |line| %w[picked poison].include?(line) })
      expect(results).not_to include(nil)
    end

    it "keeps the :cpm-mode fallback robust when a non-finite cpm reaches selection", :aggregate_failures do
      # Defense-in-depth: coerce_number zeroes NaN upstream, so simulate a raw
      # NaN cpm slipping past normalization to prove the line-215 fallback
      # (cpm -> weight) still fires on a non-finite sum instead of handing NaN
      # to weighted_pick.
      #
      raw = [
        { advertiser: "A", text: "picked", weight: 1.0, cpm: Float::NAN,
          starts_at: nil, ends_at: nil, cap: nil, format: :text, box: :light },
        { advertiser: "B", text: "skipped", weight: 0.0, cpm: Float::NAN,
          starts_at: nil, ends_at: nil, cap: nil, format: :text, box: :light }
      ]
      allow(SponsoredLogs::Advertisers).to receive(:normalize).and_return(raw)

      results = Array.new(200) do
        SponsoredLogs::Advertisers.render(SponsoredLogs::Advertisers.pick(raw, mode: :cpm), "")
      end

      expect(results.uniq).to eq(["picked"])
      expect(results).not_to include(nil)
    end
  end

  describe "Advertisers.normalize" do
    it "defaults weight to 1 and cpm to 0" do
      expect(SponsoredLogs::Advertisers.normalize([{ text: "x" }]).first)
        .to include(text: "x", weight: 1.0, cpm: 0.0)
    end

    it "accepts string keys from parsed JSON" do
      expect(SponsoredLogs::Advertisers.normalize([{ "text" => "x", "weight" => 5, "cpm" => 12 }]).first)
        .to include(text: "x", weight: 5.0, cpm: 12.0)
    end

    it "clamps a negative weight to zero" do
      expect(SponsoredLogs::Advertisers.normalize([{ text: "x", weight: -3 }]).first)
        .to include(weight: 0.0)
    end

    it "defaults an unparseable weight to 1 and unparseable cpm to 0" do
      expect(SponsoredLogs::Advertisers.normalize([{ text: "x", weight: "nope", cpm: "bad" }]).first)
        .to include(weight: 1.0, cpm: 0.0)
    end

    it "zeroes a non-finite float weight and cpm", :aggregate_failures do
      ad = SponsoredLogs::Advertisers.normalize(
        [{ text: "x", weight: Float::NAN, cpm: Float::INFINITY }]
      ).first
      expect(ad[:weight]).to eq(0.0)
      expect(ad[:cpm]).to eq(0.0)
    end

    it "zeroes negative infinity" do
      expect(SponsoredLogs::Advertisers.normalize([{ text: "x", weight: -Float::INFINITY }]).first)
        .to include(weight: 0.0)
    end

    it "never stores a non-finite value from the strings NaN, Infinity, -Infinity", :aggregate_failures do
      ad = SponsoredLogs::Advertisers.normalize(
        [{ text: "x", weight: "NaN", cpm: "Infinity" }]
      ).first
      # These strings are unparseable as demand, so they fall to the defaults
      # (weight 1.0, cpm 0.0); the invariant is that the stored value is finite.
      #
      expect(ad[:weight]).to be_finite
      expect(ad[:cpm]).to be_finite
      expect(SponsoredLogs::Advertisers.normalize([{ text: "x", weight: "-Infinity" }]).first[:weight])
        .to be_finite
    end

    it "drops entries with blank text", :aggregate_failures do
      expect(SponsoredLogs::Advertisers.normalize([{ text: "  ", weight: 1 }])).to eq([])
      expect(SponsoredLogs::Advertisers.normalize(["a bare string"])).to eq([])
    end

    it "defaults flight bounds to nil", :aggregate_failures do
      ad = SponsoredLogs::Advertisers.normalize([{ text: "x" }]).first
      expect(ad[:starts_at]).to be_nil
      expect(ad[:ends_at]).to be_nil
    end

    it "parses string flight bounds into Time", :aggregate_failures do
      ad = SponsoredLogs::Advertisers.normalize(
        [{ text: "x", starts_at: "2026-01-01T00:00:00Z", ends_at: "2026-12-31T23:59:59Z" }]
      ).first
      expect(ad[:starts_at]).to be_a(Time)
      expect(ad[:ends_at]).to be_a(Time)
      expect(ad[:starts_at].year).to eq(2026)
    end

    it "accepts Time objects directly" do
      t = Time.now
      ad = SponsoredLogs::Advertisers.normalize([{ text: "x", starts_at: t }]).first
      expect(ad[:starts_at]).to be_within(1).of(t)
    end

    it "turns an unparseable flight bound into nil" do
      ad = SponsoredLogs::Advertisers.normalize([{ text: "x", starts_at: "not a date" }]).first
      expect(ad[:starts_at]).to be_nil
    end

    it "defaults cap to nil and parses a positive cap", :aggregate_failures do
      expect(SponsoredLogs::Advertisers.normalize([{ text: "x" }]).first[:cap]).to be_nil
      expect(SponsoredLogs::Advertisers.normalize([{ text: "x", cap: 250 }]).first[:cap]).to eq(250)
    end

    it "defaults advertiser to Unattributed and keeps a supplied name", :aggregate_failures do
      expect(SponsoredLogs::Advertisers.normalize([{ text: "x" }]).first[:advertiser]).to eq("Unattributed")
      expect(SponsoredLogs::Advertisers.normalize([{ text: "x", advertiser: "Acme" }]).first[:advertiser]).to eq("Acme")
    end

    it "treats a blank advertiser as Unattributed" do
      expect(SponsoredLogs::Advertisers.normalize([{ text: "x", advertiser: "  " }]).first[:advertiser]).to eq("Unattributed")
    end
  end

  describe "Advertisers flighting" do
    let(:now) { Time.utc(2026, 6, 15, 12, 0, 0) }

    def pick_text(ads, **opts)
      SponsoredLogs::Advertisers.render(SponsoredLogs::Advertisers.pick(ads, **opts), "")
    end

    it "excludes ads whose window has not started" do
      ads = [{ text: "future", weight: 1, starts_at: "2026-07-01T00:00:00Z" }]
      # Only live pool member is gone -> falls back to defaults, never "future".
      results = Array.new(50) { pick_text(ads, now: now) }
      expect(results).not_to include("future")
    end

    it "excludes ads whose window has ended" do
      ads = [{ text: "expired", weight: 1, ends_at: "2026-01-01T00:00:00Z" }]
      results = Array.new(50) { pick_text(ads, now: now) }
      expect(results).not_to include("expired")
    end

    it "includes ads inside their window" do
      ads = [
        { text: "live", weight: 1, starts_at: "2026-06-01T00:00:00Z", ends_at: "2026-07-01T00:00:00Z" }
      ]
      expect(pick_text(ads, now: now)).to eq("live")
    end

    it "treats missing bounds as open-ended", :aggregate_failures do
      expect(SponsoredLogs::Advertisers.live?({ starts_at: nil, ends_at: nil }, now)).to be(true)
    end

    it "picks only the live ad from a mixed pool" do
      ads = [
        { text: "live", weight: 1 },
        { text: "expired", weight: 1, ends_at: "2026-01-01T00:00:00Z" }
      ]
      results = Array.new(100) { pick_text(ads, now: now) }
      expect(results.uniq).to eq(["live"])
    end

    describe ".status" do
      it "is :evergreen with no bounds" do
        expect(SponsoredLogs::Advertisers.status({ starts_at: nil, ends_at: nil }, now)).to eq(:evergreen)
      end

      it "is :scheduled before the window" do
        ad = { starts_at: Time.utc(2026, 8, 1), ends_at: nil }
        expect(SponsoredLogs::Advertisers.status(ad, now)).to eq(:scheduled)
      end

      it "is :ended after the window" do
        ad = { starts_at: nil, ends_at: Time.utc(2026, 1, 1) }
        expect(SponsoredLogs::Advertisers.status(ad, now)).to eq(:ended)
      end

      it "is :active inside the window" do
        ad = { starts_at: Time.utc(2026, 6, 1), ends_at: Time.utc(2026, 7, 1) }
        expect(SponsoredLogs::Advertisers.status(ad, now)).to eq(:active)
      end

      it "is :exhausted when the cap is reached, overriding flight status" do
        ad = { starts_at: nil, ends_at: nil, cap: 100 }
        expect(SponsoredLogs::Advertisers.status(ad, now, 100)).to eq(:exhausted)
        expect(SponsoredLogs::Advertisers.status(ad, now, 99)).to eq(:evergreen)
      end
    end
  end

  describe "Advertisers impression caps" do
    let(:now) { Time.utc(2026, 6, 15, 12, 0, 0) }

    describe ".coerce_cap" do
      it "keeps a positive integer" do
        expect(SponsoredLogs::Advertisers.coerce_cap(500)).to eq(500)
      end

      it "parses a numeric string" do
        expect(SponsoredLogs::Advertisers.coerce_cap("500")).to eq(500)
      end

      it "treats nil, zero, negative, and garbage as unlimited (nil)", :aggregate_failures do
        expect(SponsoredLogs::Advertisers.coerce_cap(nil)).to be_nil
        expect(SponsoredLogs::Advertisers.coerce_cap(0)).to be_nil
        expect(SponsoredLogs::Advertisers.coerce_cap(-5)).to be_nil
        expect(SponsoredLogs::Advertisers.coerce_cap("nope")).to be_nil
      end
    end

    describe ".capped?" do
      it "is false when uncapped" do
        expect(SponsoredLogs::Advertisers.capped?({ cap: nil }, 10_000)).to be(false)
      end

      it "is true at or over the cap", :aggregate_failures do
        expect(SponsoredLogs::Advertisers.capped?({ cap: 100 }, 100)).to be(true)
        expect(SponsoredLogs::Advertisers.capped?({ cap: 100 }, 101)).to be(true)
        expect(SponsoredLogs::Advertisers.capped?({ cap: 100 }, 99)).to be(false)
      end
    end

    it "pick excludes an ad that has hit its cap" do
      ads = [
        { text: "capped", weight: 5, cap: 10 },
        { text: "open", weight: 1 }
      ]
      # Counts are keyed by ad id; a no-id ad's id is SHA256(text).
      #
      counts = { Digest::SHA256.hexdigest("capped") => 10 }
      results = Array.new(100) do
        SponsoredLogs::Advertisers.render(
          SponsoredLogs::Advertisers.pick(ads, now: now, counts: counts), ""
        )
      end
      expect(results.uniq).to eq(["open"])
    end

    it "pick still allows an ad under its cap" do
      ads = [{ text: "capped", weight: 1, cap: 10 }]
      counts = { Digest::SHA256.hexdigest("capped") => 9 }
      picked = SponsoredLogs::Advertisers.pick(ads, now: now, counts: counts)
      expect(picked[:text]).to eq("capped")
    end
  end

  describe "house ads" do
    let(:now) { Time.utc(2026, 6, 15, 12, 0, 0) }

    def house_texts
      SponsoredLogs::Advertisers::HOUSE_ADS.map { |ad| ad[:text] }
    end

    it "brands every house creative as SponsoredLogs with zero cpm", :aggregate_failures do
      SponsoredLogs::Advertisers::HOUSE_ADS.each do |ad|
        expect(ad[:advertiser]).to eq("SponsoredLogs")
        expect(ad[:cpm]).to eq(0.0)
        expect(ad[:weight]).to eq(1)
      end
    end

    it "can serve a house ad from the default rotation" do
      results = Array.new(2000) do
        SponsoredLogs::Advertisers.render(SponsoredLogs::Advertisers.pick(now: now), "")
      end
      expect(results & house_texts).not_to be_empty
    end

    it "rotates house ads roughly in proportion to weight (~3/13)", :aggregate_failures do
      # All 13 default entries are eligible and equally weighted, so house
      # creatives (3 of 13, ~23%) should appear near their share over a large
      # sample. Wide band keeps this non-flaky, matching the weight specs above.
      #
      described_class.sponsor!(house_ads: true)

      sample = 6500
      results = Array.new(sample) do
        SponsoredLogs::Advertisers.render(SponsoredLogs::Advertisers.pick(now: now), "")
      end
      house_count = (results & house_texts).sum { |text| results.count(text) }

      # Expected ~1500 (3/13). Assert a generous 12%-34% band.
      #
      expect(house_count).to be > (sample * 0.12)
      expect(house_count).to be < (sample * 0.34)
    end

    describe "rotation vs remnant floor (distinct code paths)" do
      before { described_class.sponsor!(house_ads: true) }

      it "picks a house creative from normal rotation without touching the floor", :aggregate_failures do
        # A fully-eligible pool holding a paid ad AND a house ad. Because the
        # pool is non-empty with eligible paid demand, the remnant floor (which
        # would rebuild the pool from HOUSE_ADS) is never reached -- yet a house
        # creative is still selectable because it competes in rotation.
        #
        paid = { advertiser: "Shopify", text: "paid demand", weight: 1, cpm: 22.0 }
        house = SponsoredLogs::Advertisers::HOUSE_ADS.first
        pool = [paid, house]

        # Seed the weighted pick to land on the house creative deterministically.
        #
        allow(SponsoredLogs::Advertisers).to receive(:weighted_pick) do |candidates, _key|
          candidates.find { |ad| house_texts.include?(ad[:text]) }
        end

        # If the floor were reached it would rebuild from HOUSE_ADS alone; assert
        # it is not by proving the fallback/floor tiers are never consulted.
        #
        expect(SponsoredLogs::Advertisers).not_to receive(:paid_default_pool)

        picked = SponsoredLogs::Advertisers.pick(pool, now: now)
        expect(picked).not_to be_nil
        expect(house_texts).to include(picked[:text])
        expect(picked[:advertiser]).to eq("SponsoredLogs")
      end

      it "serves a house ad from the remnant floor when both prior tiers are exhausted", :aggregate_failures do
        # Contrast with the rotation path: here the user pool AND the paid
        # default pool both yield nothing eligible (out of flight / capped), so
        # the pick can ONLY come from the HOUSE_ADS floor (advertisers.rb line
        # guarded by `empty_pool?(pool) && house_ads?`).
        #
        expired = [{ text: "expired", weight: 1, ends_at: "2000-01-01" }]
        allow(SponsoredLogs::Advertisers)
          .to receive(:paid_default_pool)
          .and_return([{ text: "capped", weight: 1, cap: 1 }])

        picked = SponsoredLogs::Advertisers.pick(expired, now: now, counts: { Digest::SHA256.hexdigest("capped") => 5 })
        expect(picked).not_to be_nil
        expect(house_texts).to include(picked[:text])
        expect(picked[:advertiser]).to eq("SponsoredLogs")
      end
    end

    it "leaves the earlier tiers untouched when house_ads is on (drop_house is a no-op)", :aggregate_failures do
      described_class.sponsor!(house_ads: true)

      # With the toggle on, drop_house must not strip house creatives from any
      # pool it filters -- turning the toggle on/off is the only lever that adds
      # or removes house ads from the selectable set.
      #
      normalized = SponsoredLogs::Advertisers.normalize(SponsoredLogs::Advertisers::DEFAULT_ADS)
      filtered = SponsoredLogs::Advertisers.drop_house(normalized)

      expect(filtered).to eq(normalized)
      expect(filtered.map { |ad| ad[:text] } & house_texts).to match_array(house_texts)
    end

    context "remnant floor (house_ads on)" do
      before { described_class.sponsor!(house_ads: true) }

      it "serves a house ad when the user pool is empty" do
        picked = SponsoredLogs::Advertisers.pick([], now: now)
        # An empty user pool falls back to DEFAULT_ADS, which already contains
        # house inventory; the pick must still resolve to a real creative.
        #
        expect(picked).not_to be_nil
      end

      it "serves a house ad when nothing paid is eligible", :aggregate_failures do
        # Force both the user pool and the paid default pool to be ineligible so
        # only the HOUSE_ADS remnant floor can answer.
        #
        expired = [{ text: "expired", weight: 1, ends_at: "2000-01-01" }]
        allow(SponsoredLogs::Advertisers)
          .to receive(:paid_default_pool)
          .and_return([{ text: "capped", weight: 1, cap: 1 }])

        picked = SponsoredLogs::Advertisers.pick(expired, now: now, counts: { Digest::SHA256.hexdigest("capped") => 5 })
        expect(picked).not_to be_nil
        expect(picked[:advertiser]).to eq("SponsoredLogs")
      end

      it "guarantees pick never returns nil when everything is out of flight" do
        expired = [{ text: "expired", weight: 1, ends_at: "2000-01-01" }]
        picked = SponsoredLogs::Advertisers.pick(expired, now: now)
        expect(picked).not_to be_nil
      end
    end

    context "toggle off (house_ads: false)" do
      before { described_class.sponsor!(house_ads: false) }

      it "excludes house ads from the default rotation" do
        results = Array.new(2000) do
          SponsoredLogs::Advertisers.render(SponsoredLogs::Advertisers.pick(now: now), "")
        end
        expect(results & house_texts).to be_empty
      end

      it "returns nil when no paid ad is eligible" do
        # User pool and paid default pool both ineligible; with the floor off,
        # pick must fall through to nil (original contract).
        #
        expired = [{ text: "expired", weight: 1, ends_at: "2000-01-01" }]
        allow(SponsoredLogs::Advertisers)
          .to receive(:paid_default_pool)
          .and_return([{ text: "capped", weight: 1, cap: 1 }])

        expect(
          SponsoredLogs::Advertisers.pick(expired, now: now, counts: { Digest::SHA256.hexdigest("capped") => 5 })
        ).to be_nil
      end

      it "still returns nil for an out-of-flight user pool" do
        expired = [{ text: "expired", weight: 1, ends_at: "2000-01-01" }]
        counts = { Digest::SHA256.hexdigest("expired") => 0 }
        # Every PAID default is also forced ineligible so only the floor could
        # save it. Counts are keyed by ad id (SHA256(text) for these no-id ads).
        #
        paid_counts = SponsoredLogs::Advertisers::PAID_ADS.to_h { |ad| [Digest::SHA256.hexdigest(ad[:text]), 1_000_000] }
        capped_pool = SponsoredLogs::Advertisers::PAID_ADS.map { |ad| ad.merge(cap: 1) }
        allow(SponsoredLogs::Advertisers).to receive(:paid_default_pool).and_return(capped_pool)

        expect(
          SponsoredLogs::Advertisers.pick(expired, now: now, counts: counts.merge(paid_counts))
        ).to be_nil
      end
    end

    it "records a served house ad in the ledger with zero spend", :aggregate_failures do
      described_class.reset_ledger!
      described_class.sponsor!(ads: SponsoredLogs::Advertisers::HOUSE_ADS, house_ads: true)

      1000.times { described_class.emit(StringIO.new) }
      report = described_class.report
      account = report[:advertisers].find { |a| a[:advertiser] == "SponsoredLogs" }

      expect(report[:impressions]).to eq(1000)
      expect(report[:spend]).to eq(0.0)
      expect(account).not_to be_nil
      expect(account[:spend]).to eq(0.0)
      expect(account[:impressions]).to eq(1000)
    end
  end

  describe "configuration house_ads" do
    it "defaults house_ads to true" do
      expect(described_class.configuration.house_ads).to be(true)
    end

    it "accepts house_ads via sponsor!" do
      described_class.sponsor!(house_ads: false)
      expect(described_class.configuration.house_ads).to be(false)
    ensure
      described_class.configuration.house_ads = true
    end

    it "loads house_ads from ENV as truthy", :aggregate_failures do
      expect(SponsoredLogs::Env.options({ "SPONSORED_LOGS_HOUSE_ADS" => "1" })[:house_ads]).to be(true)
      expect(SponsoredLogs::Env.options({ "SPONSORED_LOGS_HOUSE_ADS" => "0" })[:house_ads]).to be(false)
    end

    it "treats the documented truthy set as enabled, case-insensitively", :aggregate_failures do
      # Mirror Env::TRUTHY (%w[1 true yes on]); parsing lowercases and strips, so
      # mixed case and surrounding whitespace still enable.
      #
      %w[1 true yes on TRUE Yes ON].each do |raw|
        opts = SponsoredLogs::Env.options({ "SPONSORED_LOGS_HOUSE_ADS" => raw })
        expect(opts[:house_ads]).to be(true), "expected #{raw.inspect} to enable house_ads"
      end

      expect(SponsoredLogs::Env.options({ "SPONSORED_LOGS_HOUSE_ADS" => "  On  " })[:house_ads]).to be(true)
    end

    it "treats any non-truthy value as disabled", :aggregate_failures do
      # Anything outside the truthy set present in the environment coerces to
      # false (an explicit override), matching every other boolean env var.
      #
      ["0", "false", "no", "off", "", "nope", "2"].each do |raw|
        opts = SponsoredLogs::Env.options({ "SPONSORED_LOGS_HOUSE_ADS" => raw })
        expect(opts[:house_ads]).to be(false), "expected #{raw.inspect} to disable house_ads"
      end
    end

    it "leaves house_ads out of ENV options when unset" do
      expect(SponsoredLogs::Env.options({})).not_to have_key(:house_ads)
    end
  end

  describe "Advertisers ad-format coercion" do
    describe ".coerce_format" do
      it "keeps :text and :banner", :aggregate_failures do
        expect(SponsoredLogs::Advertisers.coerce_format(:text)).to eq(:text)
        expect(SponsoredLogs::Advertisers.coerce_format(:banner)).to eq(:banner)
      end

      it "coerces strings to symbols when recognized", :aggregate_failures do
        expect(SponsoredLogs::Advertisers.coerce_format("banner")).to eq(:banner)
        expect(SponsoredLogs::Advertisers.coerce_format("text")).to eq(:text)
      end

      it "defaults nil and garbage to :text", :aggregate_failures do
        expect(SponsoredLogs::Advertisers.coerce_format(nil)).to eq(:text)
        expect(SponsoredLogs::Advertisers.coerce_format(:bogus)).to eq(:text)
        expect(SponsoredLogs::Advertisers.coerce_format(123)).to eq(:text)
      end
    end

    describe ".coerce_box" do
      it "keeps :light, :heavy, and :double", :aggregate_failures do
        expect(SponsoredLogs::Advertisers.coerce_box(:light)).to eq(:light)
        expect(SponsoredLogs::Advertisers.coerce_box(:heavy)).to eq(:heavy)
        expect(SponsoredLogs::Advertisers.coerce_box(:double)).to eq(:double)
      end

      it "coerces recognized strings to symbols" do
        expect(SponsoredLogs::Advertisers.coerce_box("double")).to eq(:double)
      end

      it "defaults nil and garbage to :light", :aggregate_failures do
        expect(SponsoredLogs::Advertisers.coerce_box(nil)).to eq(:light)
        expect(SponsoredLogs::Advertisers.coerce_box("nope")).to eq(:light)
        expect(SponsoredLogs::Advertisers.coerce_box(:fancy)).to eq(:light)
      end
    end

    describe ".normalize_entry" do
      it "defaults format to :text and box to :light", :aggregate_failures do
        ad = SponsoredLogs::Advertisers.normalize([{ text: "x" }]).first
        expect(ad[:format]).to eq(:text)
        expect(ad[:box]).to eq(:light)
      end

      it "keeps a valid format and box", :aggregate_failures do
        ad = SponsoredLogs::Advertisers.normalize([{ text: "x", format: :banner, box: :heavy }]).first
        expect(ad[:format]).to eq(:banner)
        expect(ad[:box]).to eq(:heavy)
      end

      it "coerces an invalid format and box back to defaults", :aggregate_failures do
        ad = SponsoredLogs::Advertisers.normalize([{ text: "x", format: :nope, box: 7 }]).first
        expect(ad[:format]).to eq(:text)
        expect(ad[:box]).to eq(:light)
      end

      it "strips newlines and carriage returns from creative text", :aggregate_failures do
        ad = SponsoredLogs::Advertisers.normalize(
          [{ text: "Buy now\nERROR forged log line" }]
        ).first
        expect(ad[:text]).not_to include("\n")
        expect(ad[:text]).not_to include("\r")
      end

      it "strips other C0 control characters and DEL from creative text", :aggregate_failures do
        ad = SponsoredLogs::Advertisers.normalize(
          [{ text: "Buy\enow\ttoday\u0000\u007F" }]
        ).first
        expect(ad[:text]).not_to match(/[\u0000-\u001F\u007F]/)
      end

      it "preserves normal punctuation, em-dashes, and emoji", :aggregate_failures do
        ad = SponsoredLogs::Advertisers.normalize(
          [{ text: "Ship it -- fast, cheap & bold! 🚀📈" }]
        ).first
        expect(ad[:text]).to eq("Ship it -- fast, cheap & bold! 🚀📈")
      end
    end
  end

  describe "Advertisers.render :text format (backward compatibility)" do
    it "renders a text-format ad byte-identical to the current tagged line" do
      ad = { text: "Only ad in the pool", format: :text, box: :light }
      expect(SponsoredLogs::Advertisers.render(ad, "[AD]")).to eq("[AD] Only ad in the pool")
    end

    it "renders byte-identical when format is absent (implicit text)" do
      ad = { text: "Only ad in the pool" }
      expect(SponsoredLogs::Advertisers.render(ad, "[AD]")).to eq("[AD] Only ad in the pool")
    end

    it "renders byte-identical with a blank prefix (no tag)" do
      ad = { text: "Only ad in the pool", format: :text }
      expect(SponsoredLogs::Advertisers.render(ad, "")).to eq("Only ad in the pool")
    end

    it "honors a custom prefix unchanged" do
      ad = { text: "Buy now", format: :text }
      expect(SponsoredLogs::Advertisers.render(ad, "SPONSORED:")).to eq("SPONSORED: Buy now")
    end

    it "returns nil for a nil entry" do
      expect(SponsoredLogs::Advertisers.render(nil, "[AD]")).to be_nil
    end
  end

  describe "Advertisers.render :banner format" do
    def banner(text, prefix: "[AD]", box: :light, ascii_only: false)
      ad = { text: text, format: :banner, box: box }
      SponsoredLogs::Advertisers.render(ad, prefix, ascii_only: ascii_only)
    end

    it "renders a light box by default with the prefix in the top border", :aggregate_failures do
      out = banner("Hello there")
      lines = out.split("\n")

      expect(lines.first).to start_with("┌─ [AD] ─")
      expect(lines.first).to end_with("┐")
      expect(lines.last).to start_with("└─")
      expect(lines.last).to end_with("┘")
      expect(out).to include("│ Hello there")
    end

    it "aligns every line to the same visual width", :aggregate_failures do
      lines = banner("A short line").split("\n")
      widths = lines.map(&:length).uniq

      expect(widths.length).to eq(1)
    end

    it "pads a short body line with trailing spaces before the right border" do
      body = banner("Hi").split("\n").find { |l| l.start_with?("│") }
      expect(body).to match(/│ Hi\s+ │/)
    end

    it "word-wraps a long body onto multiple lines", :aggregate_failures do
      text = "word " * 40
      body_lines = banner(text.strip).split("\n").select { |l| l.start_with?("│") }

      expect(body_lines.length).to be > 1
      body_lines.each { |l| expect(l.length).to eq(body_lines.first.length) }
    end

    it "breaks a single word longer than the width mid-word" do
      long = "x" * 80
      body_lines = banner(long).split("\n").select { |l| l.start_with?("│") }
      expect(body_lines.length).to be >= 2
    end

    it "renders a heavy box with heavy glyphs", :aggregate_failures do
      out = banner("Premium impact", box: :heavy)
      lines = out.split("\n")

      expect(lines.first).to start_with("┏━ [AD] ━")
      expect(lines.first).to end_with("┓")
      expect(out).to include("┃ Premium impact")
      expect(lines.last).to start_with("┗━")
      expect(lines.last).to end_with("┛")
    end

    it "renders a double box with double glyphs", :aggregate_failures do
      out = banner("Maximum impact", box: :double)
      lines = out.split("\n")

      expect(lines.first).to start_with("╔═ [AD] ═")
      expect(lines.first).to end_with("╗")
      expect(out).to include("║ Maximum impact")
      expect(lines.last).to start_with("╚═")
      expect(lines.last).to end_with("╝")
    end

    it "embeds a custom prefix in the top border" do
      out = banner("Copy", prefix: "SPONSORED:")
      expect(out.split("\n").first).to start_with("┌─ SPONSORED: ─")
    end

    it "omits the prefix tag and its gap when the prefix is blank", :aggregate_failures do
      top = banner("Copy", prefix: "").split("\n").first

      expect(top).to start_with("┌──")
      expect(top).not_to include("[AD]")
      expect(top).not_to include(" ")
    end

    it "overrides a light box with ASCII borders when ascii_only is true", :aggregate_failures do
      out = banner("Copy", box: :light, ascii_only: true)
      lines = out.split("\n")

      expect(lines.first).to start_with("+- [AD] -")
      expect(lines.first).to end_with("+")
      expect(out).to include("| Copy")
      expect(lines.last).to start_with("+-")
      expect(lines.last).to end_with("+")
    end

    it "overrides heavy and double boxes with ASCII when ascii_only is true", :aggregate_failures do
      heavy = banner("Copy", box: :heavy, ascii_only: true)
      double = banner("Copy", box: :double, ascii_only: true)

      expect(heavy).not_to match(/[┏┓┗┛━┃]/)
      expect(double).not_to match(/[╔╗╚╝═║]/)
      expect(heavy.split("\n").first).to start_with("+-")
      expect(double.split("\n").first).to start_with("+-")
    end

    it "renders emoji and CJK copy without raising, keeping the frame intact", :aggregate_failures do
      out = banner("Buy now! 🎉 日本 中文 products 🔥")
      lines = out.split("\n")
      body_lines = lines.select { |l| l.start_with?("│") }

      expect(lines.first).to start_with("┌─ [AD] ─")
      expect(lines.first).to end_with("┐")
      expect(lines.last).to start_with("└─")
      expect(lines.last).to end_with("┘")
      expect(body_lines).not_to be_empty
      expect(out).to include("🎉")
      expect(out).to include("日本")
    end

    it "renders a complete light banner byte-for-byte" do
      expected = <<~BANNER.chomp
        ┌─ [AD] ───────────────────────────────────────────────────────┐
        │ Test message                                                 │
        └──────────────────────────────────────────────────────────────┘
      BANNER

      expect(banner("Test message")).to eq(expected)
    end
  end

  describe "Advertisers.wrap_text" do
    it "wraps on word boundaries within the width", :aggregate_failures do
      lines = SponsoredLogs::Advertisers.wrap_text("one two three four", 8)

      lines.each { |l| expect(l.length).to be <= 8 }
      expect(lines.join(" ")).to eq("one two three four")
    end

    it "breaks a word longer than the width mid-word", :aggregate_failures do
      lines = SponsoredLogs::Advertisers.wrap_text("abcdefghij", 4)

      expect(lines).to eq(%w[abcd efgh ij])
    end

    it "returns a single blank line for empty text" do
      expect(SponsoredLogs::Advertisers.wrap_text("", 10)).to eq([""])
    end
  end

  describe "configuration ascii_only" do
    it "defaults ascii_only to false" do
      expect(described_class.configuration.ascii_only).to be(false)
    end

    it "accepts ascii_only via sponsor!" do
      described_class.sponsor!(ascii_only: true)
      expect(described_class.configuration.ascii_only).to be(true)
    ensure
      described_class.configuration.ascii_only = false
    end

    it "loads ascii_only from ENV as truthy" do
      opts = SponsoredLogs::Env.options({ "SPONSORED_LOGS_ASCII_ONLY" => "1" })
      expect(opts[:ascii_only]).to be(true)
    end

    it "leaves ascii_only out of ENV options when unset" do
      expect(SponsoredLogs::Env.options({})).not_to have_key(:ascii_only)
    end
  end

  describe ".emit with banner ads" do
    it "emits a multi-line banner to an IO target", :aggregate_failures do
      io = StringIO.new
      described_class.sponsor!(ads: [{ text: "Banner ad", format: :banner, weight: 1 }])
      described_class.emit(io)

      expect(io.string).to include("\n")
      expect(io.string).to start_with("┌─ [AD] ─")
      expect(io.string).to include("│ Banner ad")
    end

    it "emits a multi-line banner to a Logger target" do
      buffer = StringIO.new
      logger = Logger.new(buffer)
      logger.formatter = ->(_s, _t, _p, msg) { "#{msg}\n" }
      described_class.sponsor!(ads: [{ text: "Logger banner", format: :banner, weight: 1 }])
      described_class.emit(logger)

      expect(buffer.string).to include("│ Logger banner")
    end

    it "respects ascii_only config when emitting a banner", :aggregate_failures do
      io = StringIO.new
      described_class.sponsor!(ads: [{ text: "Ascii banner", format: :banner, weight: 1 }], ascii_only: true)
      described_class.emit(io)

      expect(io.string).to start_with("+- [AD] -")
      expect(io.string).to include("| Ascii banner")
    ensure
      described_class.configuration.ascii_only = false
    end
  end

  # ANSI gold [AD] prefix: 256-color gold (\e[38;5;214m) wrapped around the
  # prefix, emitted only when it is safe to do so (a real TTY, NO_COLOR unset)
  # or forced via config. Non-TTY sinks stay byte-identical to the plain line.
  #
  let(:gold) { "\e[38;5;214m" }
  let(:reset) { "\e[0m" }

  describe SponsoredLogs::Color do
    describe ".colorize" do
      it "wraps text in 256-color gold when enabled" do
        expect(described_class.colorize("[AD]", enabled: true)).to eq("#{gold}[AD]#{reset}")
      end

      it "returns the input unchanged when disabled" do
        expect(described_class.colorize("[AD]", enabled: false)).to eq("[AD]")
      end
    end
  end

  describe ".emit ANSI gold prefix" do
    let(:ad) { [{ text: "Gilded impression", weight: 1 }] }

    it "gilds the prefix when the IO target is a TTY", :aggregate_failures do
      io = StringIO.new
      allow(io).to receive(:tty?).and_return(true)
      described_class.sponsor!(ads: ad)
      described_class.emit(io)

      expect(io.string).to include("#{gold}[AD]#{reset}")
      expect(io.string).to eq("#{gold}[AD]#{reset} Gilded impression\n")
    end

    it "emits a byte-identical plain line to a non-TTY IO", :aggregate_failures do
      io = StringIO.new # StringIO#tty? is false
      described_class.sponsor!(ads: ad)
      described_class.emit(io)

      expect(io.string).not_to include("\e[")
      expect(io.string).to eq("[AD] Gilded impression\n")
    end

    it "never gilds a Logger target", :aggregate_failures do
      buffer = StringIO.new
      logger = Logger.new(buffer)
      logger.formatter = ->(_s, _t, _p, msg) { "#{msg}\n" }
      described_class.sponsor!(ads: ad)
      described_class.emit(logger)

      expect(buffer.string).not_to include("\e[")
      expect(buffer.string).to include("[AD] Gilded impression")
    end

    it "stays plain on a TTY when NO_COLOR is set (:auto)", :aggregate_failures do
      io = StringIO.new
      allow(io).to receive(:tty?).and_return(true)
      described_class.sponsor!(ads: ad)
      stub_const("ENV", ENV.to_h.merge("NO_COLOR" => "1"))
      described_class.emit(io)

      expect(io.string).not_to include("\e[")
      expect(io.string).to eq("[AD] Gilded impression\n")
    end

    it "gilds on a TTY when NO_COLOR is empty (:auto)", :aggregate_failures do
      io = StringIO.new
      allow(io).to receive(:tty?).and_return(true)
      described_class.sponsor!(ads: ad)
      stub_const("ENV", ENV.to_h.merge("NO_COLOR" => ""))
      described_class.emit(io)

      expect(io.string).to include("#{gold}[AD]#{reset}")
    end

    it "gilds a non-TTY IO when color is :always" do
      io = StringIO.new # not a tty
      described_class.sponsor!(ads: ad, color: :always)
      described_class.emit(io)

      expect(io.string).to eq("#{gold}[AD]#{reset} Gilded impression\n")
    end

    it "gilds even when NO_COLOR is set if color is :always" do
      io = StringIO.new
      described_class.sponsor!(ads: ad, color: :always)
      stub_const("ENV", ENV.to_h.merge("NO_COLOR" => "1"))
      described_class.emit(io)

      expect(io.string).to include("#{gold}[AD]#{reset}")
    end

    it "never gilds a TTY when color is :never", :aggregate_failures do
      io = StringIO.new
      allow(io).to receive(:tty?).and_return(true)
      described_class.sponsor!(ads: ad, color: :never)
      described_class.emit(io)

      expect(io.string).not_to include("\e[")
      expect(io.string).to eq("[AD] Gilded impression\n")
    end
  end

  describe "configuration color" do
    it "defaults color to :auto" do
      expect(described_class.configuration.color).to eq(:auto)
    end

    it "accepts a valid color mode via sponsor!" do
      described_class.sponsor!(color: :always)
      expect(described_class.configuration.color).to eq(:always)
    end

    it "coerces an invalid color value to :auto" do
      described_class.sponsor!(color: :chartreuse)
      expect(described_class.configuration.color).to eq(:auto)
    end
  end

  describe "SPONSORED_LOGS_COLOR env parsing" do
    it "maps auto/always/never strings to the matching symbol", :aggregate_failures do
      expect(SponsoredLogs::Env.options({ "SPONSORED_LOGS_COLOR" => "always" })[:color]).to eq(:always)
      expect(SponsoredLogs::Env.options({ "SPONSORED_LOGS_COLOR" => "never" })[:color]).to eq(:never)
      expect(SponsoredLogs::Env.options({ "SPONSORED_LOGS_COLOR" => "auto" })[:color]).to eq(:auto)
    end

    it "coerces an invalid env value to :auto" do
      expect(SponsoredLogs::Env.options({ "SPONSORED_LOGS_COLOR" => "neon" })[:color]).to eq(:auto)
    end

    it "leaves color out of ENV options when unset" do
      expect(SponsoredLogs::Env.options({})).not_to have_key(:color)
    end
  end

  describe "Advertisers.render color" do
    it "gilds the prefix of a :text ad when color is on" do
      out = SponsoredLogs::Advertisers.render({ text: "Hi" }, "[AD]", color: true)
      expect(out).to eq("#{gold}[AD]#{reset} Hi")
    end

    it "leaves the :text prefix plain when color is off" do
      out = SponsoredLogs::Advertisers.render({ text: "Hi" }, "[AD]", color: false)
      expect(out).to eq("[AD] Hi")
    end
  end

  describe "Banner color" do
    def banner(text, prefix: "[AD]", box: :light, color: false)
      ad = { text: text, format: :banner, box: box }
      SponsoredLogs::Advertisers.render(ad, prefix, color: color)
    end

    it "gilds the prefix tag in the top border when color is on", :aggregate_failures do
      top = banner("Copy", color: true).split("\n").first

      expect(top).to include("#{gold}[AD]#{reset}")
      expect(top).to start_with("┌─ #{gold}[AD]#{reset} ─")
      expect(top).to end_with("┐")
    end

    it "keeps the visible box aligned when the prefix is gilded", :aggregate_failures do
      colored = banner("Alignment check", color: true).split("\n")
      plain = banner("Alignment check", color: false).split("\n")

      # Strip the zero-width escapes; the visible frame must match the plain one
      # exactly, byte-for-byte, so the gold codes cost the border no columns.
      #
      visible = colored.map { |line| line.gsub(/\e\[[0-9;]*m/, "") }
      expect(visible).to eq(plain)
    end

    it "keeps the visible box aligned when the prefix is gilded (heavy)", :aggregate_failures do
      colored = banner("Alignment check", box: :heavy, color: true).split("\n")
      plain = banner("Alignment check", box: :heavy, color: false).split("\n")

      # Strip the zero-width escapes; the heavy frame must match the plain one
      # exactly, byte-for-byte, so the gold codes cost the border no columns.
      #
      visible = colored.map { |line| line.gsub(/\e\[[0-9;]*m/, "") }
      expect(visible).to eq(plain)
    end

    it "keeps the visible box aligned when the prefix is gilded (double)", :aggregate_failures do
      colored = banner("Alignment check", box: :double, color: true).split("\n")
      plain = banner("Alignment check", box: :double, color: false).split("\n")

      # Strip the zero-width escapes; the double frame must match the plain one
      # exactly, byte-for-byte, so the gold codes cost the border no columns.
      #
      visible = colored.map { |line| line.gsub(/\e\[[0-9;]*m/, "") }
      expect(visible).to eq(plain)
    end
  end
end
