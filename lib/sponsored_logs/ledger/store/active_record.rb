# frozen_string_literal: true

module SponsoredLogs
  module Ledger
    module Store
      # Persistent store backed by ActiveRecord, one row per ad keyed by the
      # stable ad id (the full text is stored alongside for reporting). For an
      # ad with no explicit id the id defaults to SHA256(text), so the ad_id
      # column holds exactly the digest the pre-0.4.0 text_digest column did.
      # Rows live in `sponsored_logs_impressions`; run the
      # `sponsored_logs:install` generator to create the migration.
      #
      # Per-surface counts live in one nullable integer column per surface on the
      # SAME row (impressions_log/_page/_partial/_unknown), so there is still
      # exactly one row per ad and the existing `impressions` total is untouched
      # (it stays the sum across surfaces). Migration: add those four columns as
      # `integer, null: false, default: 0`; a store that predates them still
      # records the per-ad total and simply reports an empty surface breakdown.
      #
      # ActiveRecord is required lazily, so it stays an optional dependency.
      # Pass model: to use your own class instead of the bundled one.
      #
      class ActiveRecord < Base
        # DB column holding each surface's per-ad tally, e.g. :log => impressions_log.
        #
        SURFACE_COLUMNS = Surfaces::ALL.to_h { |s| [s, :"impressions_#{s}"] }.freeze

        def initialize(model: nil)
          super()
          @model = model || build_default_model
        end

        def record(ad = nil, surface: Surfaces::UNKNOWN, **ad_kwargs)
          ad = Store.coerce_ad(ad, ad_kwargs)
          id = Identity.id_for(ad)
          column = SURFACE_COLUMNS.fetch(Surfaces.coerce(surface))

          # insert skips on conflict (INSERT ... ON CONFLICT DO NOTHING), so an
          # existing row keeps its impression count. Then atomically bump the
          # per-ad total AND the matching surface counter, and refresh cpm and
          # text, in a single UPDATE so a stable id whose copy was edited shows
          # the latest text (like the other stores).
          #
          @model.insert(
            { ad_id: id, text: ad[:text], cpm: ad[:cpm].to_f, impressions: 0 },
            unique_by: :ad_id
          )
          @model.where(ad_id: id).update_all(
            ["impressions = impressions + 1, #{column} = #{column} + 1, cpm = ?, text = ?",
             ad[:cpm].to_f, ad[:text].to_s]
          )
        end

        def snapshot
          @model.all.to_h do |row|
            [row.ad_id, { text: row.text, impressions: row.impressions.to_i, cpm: row.cpm.to_f }]
          end
        end

        def surface_snapshot
          @model.all.to_h do |row|
            tally = SURFACE_COLUMNS.each_with_object({}) do |(surface, column), acc|
              count = row.public_send(column).to_i if row.respond_to?(column)
              acc[surface] = count if count&.positive?
            end
            [row.ad_id, tally]
          end
        end

        def reset
          @model.delete_all
          self
        end

        private

        # Defined lazily so requiring this file never needs ActiveRecord loaded.
        #
        def build_default_model
          require "active_record"

          @default_model ||= Class.new(::ActiveRecord::Base) do
            self.table_name = "sponsored_logs_impressions"
          end
        rescue LoadError
          raise LoadError, "SponsoredLogs::Ledger::Store::ActiveRecord requires the " \
                           "`activerecord` gem. Add it to your Gemfile, or pass model: " \
                           "with your own ActiveRecord class."
        end
      end
    end
  end
end
