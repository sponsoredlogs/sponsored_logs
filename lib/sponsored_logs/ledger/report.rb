# frozen_string_literal: true

module SponsoredLogs
  module Ledger
    # Computes impression/spend figures over a store adapter. The store holds
    # raw tallies; Report derives totals and per-ad entries from #snapshot.
    # Spend for an ad is impressions / 1000.0 * cpm (cost per mille).
    #
    class Report
      Entry = Struct.new(:id, :text, :impressions, :cpm, :spend, keyword_init: true)

      def initialize(store)
        @store = store
      end

      def record(ad = nil, surface: Surfaces::UNKNOWN, **ad_kwargs)
        ad = Store.coerce_ad(ad, ad_kwargs)
        @store.record(ad, surface: surface)
      end

      def total_impressions
        @store.snapshot.sum { |_id, data| data[:impressions] }
      end

      def total_spend
        @store.snapshot.sum { |_id, data| spend_for(data[:impressions], data[:cpm]) }
      end

      def entries
        @store.snapshot.map do |id, data|
          Entry.new(
            id: id,
            text: data[:text],
            impressions: data[:impressions],
            cpm: data[:cpm].to_f,
            spend: spend_for(data[:impressions], data[:cpm])
          )
        end
      end

      # Map of ad id => recorded impressions, for cap enforcement.
      #
      def impression_counts
        @store.snapshot.transform_values { |data| data[:impressions] }
      end

      # Aggregate impressions by surface across all ads, as { log:, page:,
      # partial:, unknown: } with every known surface present (zero-filled).
      # Derived from the store's optional per-surface breakdown; a store that
      # predates surfaces (no #surface_snapshot) reports all zeros rather than
      # raising, so custom duck-typed stores keep working.
      #
      def impressions_by_surface
        totals = Surfaces::ALL.to_h { |surface| [surface, 0] }
        return totals unless @store.respond_to?(:surface_snapshot)

        @store.surface_snapshot.each_value do |tally|
          tally.each { |surface, count| totals[Surfaces.coerce(surface)] += count.to_i }
        end
        totals
      end

      def reset
        @store.reset
        self
      end

      private

      def spend_for(impressions, cpm)
        impressions / 1000.0 * cpm.to_f
      end
    end
  end
end
