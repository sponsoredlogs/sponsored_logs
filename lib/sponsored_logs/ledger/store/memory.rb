# frozen_string_literal: true

module SponsoredLogs
  module Ledger
    module Store
      # Default adapter. Keeps impression counts and CPMs in memory, keyed by the
      # stable ad id (text stored alongside for display). Not persisted across
      # process restarts. A mutex guards writes so the periodic thread and
      # request threads can record concurrently.
      #
      class Memory < Base
        def initialize
          super
          @mutex = Mutex.new
          @impressions = Hash.new(0)
          @surfaces = Hash.new { |h, id| h[id] = Hash.new(0) }
          @cpm = {}
          @text = {}
        end

        def record(ad = nil, surface: Surfaces::UNKNOWN, **ad_kwargs)
          ad = Store.coerce_ad(ad, ad_kwargs)
          id = Identity.id_for(ad)
          surface = Surfaces.coerce(surface)

          @mutex.synchronize do
            @impressions[id] += 1
            @surfaces[id][surface] += 1
            @cpm[id] = ad[:cpm].to_f
            @text[id] = ad[:text].to_s
          end
        end

        def snapshot
          @mutex.synchronize do
            @impressions.each_with_object({}) do |(id, count), acc|
              acc[id] = { text: @text[id], impressions: count, cpm: @cpm[id].to_f }
            end
          end
        end

        def surface_snapshot
          @mutex.synchronize do
            @surfaces.each_with_object({}) do |(id, tally), acc|
              acc[id] = tally.dup
            end
          end
        end

        def reset
          @mutex.synchronize do
            @impressions = Hash.new(0)
            @surfaces = Hash.new { |h, id| h[id] = Hash.new(0) }
            @cpm = {}
            @text = {}
          end
          self
        end
      end
    end
  end
end
