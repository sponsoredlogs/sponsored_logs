# frozen_string_literal: true

module SponsoredLogs
  class Configuration
    attr_accessor :probability, :html_probability, :periodic, :interval, :output, :ad_prefix, :ads, :selection, :store,
                  :report_page, :ascii_only, :house_ads, :partial_ads
    attr_reader :color

    # Gilding modes for the [AD] prefix. :auto gilds only on a NO_COLOR-clear
    # TTY; :always forces gold (overriding NO_COLOR); :never stays plain.
    #
    COLOR_MODES = %i[auto always never].freeze

    # Settings that map 1:1 onto an accessor. ads/ads_file are handled
    # separately because they interact (ads wins; ads_file loads into ads).
    #
    DIRECT_KEYS = %i[probability html_probability periodic interval output ad_prefix selection store report_page
                     ascii_only house_ads partial_ads color].freeze
    KNOWN_KEYS = (DIRECT_KEYS + %i[ads ads_file]).freeze

    def initialize
      @probability = 0.001
      @html_probability = 0.05
      @periodic = false
      @interval = 30
      @output = $stdout
      @ad_prefix = "[AD]"
      @ads = Advertisers::DEFAULT_ADS
      @selection = :weight
      @store = Ledger::Store::Memory.new
      @report_page = false
      @ascii_only = false
      @house_ads = true
      @partial_ads = false
      @color = :auto
    end

    # Coerce any unrecognized gilding mode back to :auto so a stray value never
    # forces or suppresses color unexpectedly.
    #
    def color=(value)
      symbol = value.to_s.strip.downcase.to_sym
      @color = COLOR_MODES.include?(symbol) ? symbol : :auto
    end

    # Apply a hash of settings. Symbol or string keys are accepted; unknown
    # keys warn rather than raise. Only keys actually present are applied, so
    # partial updates leave everything else intact.
    #
    def assign(opts = {}, warn_to: $stderr)
      opts = normalize_keys(opts)

      opts.each_key do |key|
        next if KNOWN_KEYS.include?(key)

        warn_to.puts("[sponsored_logs] unknown setting: #{key.inspect}; ignored.")
      end

      DIRECT_KEYS.each do |key|
        public_send("#{key}=", opts[key]) if opts.key?(key)
      end

      assign_ads(opts, warn_to: warn_to)
      self
    end

    private

    def assign_ads(opts, warn_to:)
      if opts.key?(:ads)
        self.ads = opts[:ads]
      elsif opts.key?(:ads_file)
        loaded = AdsFile.load(opts[:ads_file], warn_to: warn_to)
        self.ads = loaded unless loaded.nil?
      end
    end

    def normalize_keys(opts)
      opts.each_with_object({}) { |(k, v), acc| acc[k.to_sym] = v }
    end
  end
end
