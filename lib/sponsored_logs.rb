# frozen_string_literal: true

require "logger"

require_relative "sponsored_logs/version"
require_relative "sponsored_logs/color"
require_relative "sponsored_logs/advertisers"
require_relative "sponsored_logs/identity"
require_relative "sponsored_logs/flight"
require_relative "sponsored_logs/banner"
require_relative "sponsored_logs/ads_file"
require_relative "sponsored_logs/surfaces"
require_relative "sponsored_logs/ledger/store/base"
require_relative "sponsored_logs/ledger/store/memory"
require_relative "sponsored_logs/ledger/store/redis"
require_relative "sponsored_logs/ledger/store/active_record"
require_relative "sponsored_logs/ledger/report"
require_relative "sponsored_logs/configuration"
require_relative "sponsored_logs/injector"
require_relative "sponsored_logs/html_comment"
require_relative "sponsored_logs/env"

module SponsoredLogs
  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration) if block_given?
      configuration
    end

    # Activate ad insertion, applying any settings from the options hash (see
    # Configuration#assign for the recognized keys). Settings can also be set
    # ahead of time with configure { |c| ... }.
    #
    def sponsor!(opts = {})
      configuration.assign(opts)

      Injector.install!
      @active = true

      start_periodic_thread if configuration.periodic

      self
    end

    def unsponsor!
      @active = false
      stop_periodic_thread
      self
    end

    # Activate from ENV if SPONSORED_LOGS is set, applying any
    # SPONSORED_LOGS_* overrides. No-op when the flag is absent, so the
    # manual sponsor!/unsponsor! path is entirely unaffected.
    #
    def sponsor_from_env!(env = ENV)
      return self unless Env.activate?(env)

      sponsor!(Env.options(env))
    end

    def active?
      @active == true
    end

    def maybe_emit(target: $stdout)
      return unless active?
      return unless rand < configuration.probability

      emit(target)
    end

    def emit(target = configuration.output)
      ad = Advertisers.pick(
        configuration.ads,
        mode: configuration.selection,
        counts: ledger.impression_counts
      )
      return if ad.nil?

      ledger.record(ad, surface: Surfaces::LOG)
      line = Advertisers.render(
        ad, configuration.ad_prefix,
        ascii_only: configuration.ascii_only,
        color: Color.gild?(target, mode: configuration.color)
      )

      if target.is_a?(Logger)
        # Raw << avoids re-triggering our own Logger#add patch (infinite loop).
        #
        target << "#{line}\n"
      else
        target.write("#{line}\n")
      end

      line
    end

    # HTML analog of maybe_emit, gated by its own html_probability knob because
    # page renders are rarer than per-puts log lines. surface: is forwarded to
    # the ledger so the controller (:page) and partial (:partial) hooks tally to
    # the right surface; it defaults to :page for existing callers.
    #
    def maybe_html_comment(surface: Surfaces::PAGE)
      return unless active?
      return unless rand < configuration.html_probability

      render_html_comment(surface: surface)
    end

    # Pick, record, and wrap one ad as a hardened HTML comment (nil when none is
    # eligible). Delegates to the shared HtmlComment core so the controller patch
    # and the partial hook reuse one path and one ledger. surface: records where
    # the impression served and defaults to :page.
    #
    def render_html_comment(surface: Surfaces::PAGE)
      HtmlComment.render(configuration, ledger, surface: surface)
    end

    # Rebuilt when the configured store changes, so swapping the store via
    # sponsor!(store:) takes effect immediately.
    #
    def ledger
      if @ledger.nil? || @ledger_store != configuration.store
        @ledger = Ledger::Report.new(configuration.store)
        @ledger_store = configuration.store
      end
      @ledger
    end

    # Accrued fake ad economics: per-ad impressions and spend, plus totals.
    # Spend is rounded to cents here; the ledger keeps the raw values.
    #
    # Every ad appears in exactly one group, by status:
    # - upcoming: :scheduled (window not started yet).
    # - finished: :ended (window passed) or :exhausted (impression cap reached).
    # - ads:      running campaigns (:active / :evergreen) that have served.
    #
    # Running rows are impression-driven (served ads only); upcoming and
    # finished also include configured ads that have not served, so scheduled
    # and completed campaigns still appear.
    #
    def report
      grouped = grouped_report_rows

      {
        impressions: ledger.total_impressions,
        impressions_by_surface: ledger.impressions_by_surface,
        spend: ledger.total_spend.round(2),
        ads: grouped[:running],
        upcoming: grouped[:upcoming],
        finished: grouped[:finished],
        advertisers: advertiser_rollup(grouped)
      }
    end

    # A formatted, log-friendly table of the current report, ready to print or
    # log. Ads are listed by descending spend.
    #
    def report_text
      data = report
      rows = data[:ads].sort_by { |ad| -ad[:spend] }
      width = rows.map { |ad| ad[:text].length }.push(4).max
      rule = "-" * (width + 30)

      lines = [format("%-#{width}s  %8s  %7s  %9s", "Ad", "Impr", "CPM", "Spend"), rule]
      rows.each { |ad| lines << format("%-#{width}s  %8d  %7.2f  %9.2f", ad[:text], ad[:impressions], ad[:cpm], ad[:spend]) }
      lines << rule
      lines << format("%-#{width}s  %8d  %7s  %9.2f", "TOTAL", data[:impressions], "", data[:spend])
      lines << surface_breakdown_line(data[:impressions_by_surface])
      lines.join("\n")
    end

    def reset_ledger!
      ledger.reset
      self
    end

    private

    # Map of ad id => normalized config metadata (text/weight/cpm/flight/cap),
    # used to enrich report rows and drive status.
    #
    def ad_metadata
      Advertisers.normalize(configuration.ads).to_h { |ad| [ad[:id], ad] }
    end

    # Partition every known ad (served or configured) into running / upcoming /
    # finished report rows by flight-and-cap status. Ads are keyed by stable id;
    # the human-readable text comes from the served ledger entry or config meta.
    #
    def grouped_report_rows
      now = Time.now
      metas = ad_metadata
      counts = ledger.impression_counts
      served = ledger.entries.to_h { |entry| [entry.id, entry] }

      grouped = Hash.new { |h, k| h[k] = [] }
      (served.keys + metas.keys).uniq.each do |id|
        meta = metas[id] || {}
        entry = served[id]
        bucket, row = report_bucket_for(meta, entry, now, counts[id].to_i)
        grouped[bucket] << row if bucket
      end

      grouped
    end

    # Classify one ad into its report bucket (:running / :upcoming / :finished)
    # and build its row. Text comes from the served ledger entry (latest copy)
    # or, for an unserved configured ad, its config meta. Running rows are
    # impression-driven, so an unserved running ad returns a nil bucket.
    #
    def report_bucket_for(meta, entry, now, count)
      text = entry ? entry.text : meta[:text]
      status = Advertisers.status(meta, now, count)
      row = report_row(text, meta, entry, status)

      case status
      when :scheduled then [:upcoming, row]
      when :ended, :exhausted then [:finished, row]
      else entry ? [:running, row] : [nil, row]
      end
    end

    # A single report row. Impressions/spend come from the ledger entry when the
    # ad has served, otherwise zero; window/cap come from config metadata.
    #
    def report_row(text, meta, entry, status)
      {
        advertiser: meta[:advertiser] || Advertisers::DEFAULT_ADVERTISER,
        text: text,
        impressions: entry ? entry.impressions : 0,
        cpm: entry ? entry.cpm : meta[:cpm].to_f,
        spend: entry ? entry.spend.round(2) : 0.0,
        starts_at: meta[:starts_at],
        ends_at: meta[:ends_at],
        cap: meta[:cap],
        status: status
      }
    end

    # A single "By surface" footer line for report_text, listing each surface's
    # impression total in the fixed Surfaces::ALL order, e.g.
    # "By surface: log 1240 | page 88 | partial 402 | unknown 0".
    #
    def surface_breakdown_line(by_surface)
      parts = Surfaces::ALL.map { |surface| "#{surface} #{by_surface.fetch(surface, 0)}" }
      "By surface: #{parts.join(" | ")}"
    end

    # Roll every report row up to its advertiser: total impressions, spend, and
    # ad count per advertiser account, sorted by spend descending.
    #
    def advertiser_rollup(grouped)
      by_advertiser = grouped.values.flatten.group_by { |row| row[:advertiser] }
      accounts = by_advertiser.map do |advertiser, ads|
        {
          advertiser: advertiser,
          ads: ads.size,
          impressions: ads.sum { |a| a[:impressions] },
          spend: ads.sum { |a| a[:spend] }.round(2)
        }
      end
      accounts.sort_by { |a| -a[:spend] }
    end

    def start_periodic_thread
      stop_periodic_thread
      @periodic_thread = Thread.new do
        loop do
          sleep(configuration.interval)
          break unless active? && configuration.periodic

          emit(configuration.output)
        end
      end
    end

    def stop_periodic_thread
      @periodic_thread&.kill
      @periodic_thread = nil
    end
  end
end

SponsoredLogs.sponsor_from_env!

require_relative "sponsored_logs/railtie" if defined?(Rails::Railtie)
require_relative "sponsored_logs/engine" if defined?(Rails::Engine)
