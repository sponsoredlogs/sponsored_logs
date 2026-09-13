# frozen_string_literal: true

module SponsoredLogs
  # The surfaces an impression can be served on. Ads now render in three places
  # (log lines, whole HTML pages, and individual partials); the ledger tallies
  # impressions per (ad, surface) so the report can break totals down by where
  # each impression was served. :unknown is the safe fallback for any caller
  # that records without naming a surface, which keeps the pre-surface record
  # contract working unchanged.
  #
  module Surfaces
    module_function

    LOG = :log
    PAGE = :page
    PARTIAL = :partial
    UNKNOWN = :unknown

    # Every surface a stored tally may be keyed by, in report display order.
    # UNKNOWN is last: it only holds impressions from legacy/duck-typed callers.
    #
    ALL = [LOG, PAGE, PARTIAL, UNKNOWN].freeze

    # Map an arbitrary value to a known surface symbol, defaulting anything
    # unrecognized (nil, typos, stray strings) to UNKNOWN. Accepts symbols or
    # strings so both keyword args and persisted string keys coerce the same.
    #
    def coerce(value)
      symbol = value.to_s.strip.downcase.to_sym
      ALL.include?(symbol) ? symbol : UNKNOWN
    end
  end
end
