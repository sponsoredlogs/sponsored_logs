# frozen_string_literal: true

module SponsoredLogs
  module Env
    TRUTHY = %w[1 true yes on].freeze

    def self.activate?(env = ENV)
      truthy?(env["SPONSORED_LOGS"])
    end

    # Maps each SPONSORED_LOGS_* variable to its option key and a coercer. Only
    # variables actually present are applied, so the manual sponsor! path is
    # untouched. Add a new override by extending this table.
    #
    OPTION_MAP = {
      "SPONSORED_LOGS_PROBABILITY" => [:probability, ->(v) { Float(v) }],
      "SPONSORED_LOGS_HTML_PROBABILITY" => [:html_probability, ->(v) { Float(v) }],
      "SPONSORED_LOGS_INTERVAL" => [:interval, ->(v) { Float(v) }],
      "SPONSORED_LOGS_PERIODIC" => [:periodic, ->(v) { truthy?(v) }],
      "SPONSORED_LOGS_PREFIX" => [:ad_prefix, ->(v) { v }],
      "SPONSORED_LOGS_ADS_FILE" => [:ads_file, ->(v) { v }],
      "SPONSORED_LOGS_SELECTION" => [:selection, :to_sym.to_proc],
      "SPONSORED_LOGS_ASCII_ONLY" => [:ascii_only, ->(v) { truthy?(v) }],
      "SPONSORED_LOGS_HOUSE_ADS" => [:house_ads, ->(v) { truthy?(v) }],
      "SPONSORED_LOGS_PARTIAL_ADS" => [:partial_ads, ->(v) { truthy?(v) }],
      "SPONSORED_LOGS_COLOR" => [:color, ->(v) { color_mode(v) }]
    }.freeze

    # Map a raw SPONSORED_LOGS_COLOR value to a gilding mode symbol, falling
    # back to :auto for anything unrecognized (invalid never forces color).
    #
    def self.color_mode(value)
      symbol = value.to_s.strip.downcase.to_sym
      Configuration::COLOR_MODES.include?(symbol) ? symbol : :auto
    end

    def self.options(env = ENV)
      OPTION_MAP.each_with_object({}) do |(var, (key, coerce)), opts|
        opts[key] = coerce.call(env[var]) if env[var]
      end
    end

    def self.truthy?(value)
      return false if value.nil?

      TRUTHY.include?(value.strip.downcase)
    end
  end
end
