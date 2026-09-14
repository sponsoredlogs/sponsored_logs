# frozen_string_literal: true

module SponsoredLogs
  module Ledger
    module Store
      # Reconcile the two record call forms into one ad hash: a positional hash
      # (record(ad, ...)) wins, otherwise the brace-less keywords (record(id:,
      # text:, ...)) are used. Adapters call this so both the historical
      # keyword form and the explicit-hash form resolve identically.
      #
      def self.coerce_ad(ad, ad_kwargs)
        ad.nil? ? ad_kwargs : ad
      end

      # Contract for ledger store adapters. Subclass this (or duck-type the
      # three methods) and pass an instance via config.store to persist
      # impressions wherever you like -- Redis, a database, a file, and so on.
      #
      # Ledger::Report computes spend and the report on top of #snapshot, so an
      # adapter only has to store and return raw tallies.
      #
      class Base
        # Record a single impression for the given normalized ad hash
        # ({ id:, text:, weight:, cpm: }). Called once per emitted message.
        # Tallies are keyed by the stable ad id (SponsoredLogs::Advertisers
        # Identity.id_for), not the mutable text, so editing copy never resets
        # a count.
        #
        # surface: names where the impression was served (:log, :page, :partial)
        # and defaults to :unknown so pre-surface callers and duck-typed stores
        # keep working unchanged. Adapters keep a per-(id, surface) tally in
        # ADDITION to the per-ad total, never instead of it.
        #
        # The ad may be passed as a positional hash (record(ad, surface:)) OR as
        # brace-less keywords (record(id:, text:, cpm:)); the latter is the long-
        # standing call form the specs and pickers use, so **ad_kwargs captures
        # it and adapters coerce via Store.coerce_ad. Keeping both forms working
        # is what preserves the pre-surface contract under Ruby 3 kwargs rules.
        #
        def record(_ad = nil, surface: Surfaces::UNKNOWN, **_ad_kwargs)
          raise NotImplementedError, "#{self.class}#record must be implemented"
        end

        # Return the current tallies as { id => { text: String, impressions:
        # Integer, cpm: Float } }. Text is a display value here, not the key;
        # the ledger derives everything else from this. This shape is the stable
        # contract; per-surface data lives in #surface_snapshot, never here.
        #
        def snapshot
          raise NotImplementedError, "#{self.class}#snapshot must be implemented"
        end

        # Return the per-surface breakdown as { id => { surface => impressions } }.
        # Summing an ad's surface counts yields the same total #snapshot reports
        # for that ad. Optional: adapters that predate surfaces may omit it, so
        # callers must tolerate a store that does not respond to it.
        #
        def surface_snapshot
          raise NotImplementedError, "#{self.class}#surface_snapshot must be implemented"
        end

        # Clear all stored impressions.
        #
        def reset
          raise NotImplementedError, "#{self.class}#reset must be implemented"
        end
      end
    end
  end
end
