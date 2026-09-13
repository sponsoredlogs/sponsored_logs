# frozen_string_literal: true

module SponsoredLogs
  module Ledger
    module Store
      class Redis < Base
        DEFAULT_NAMESPACE = "sponsored_logs"

        def initialize(client: nil, namespace: DEFAULT_NAMESPACE)
          super()
          @client = client || build_default_client
          @namespace = namespace
          @impressions_key = "#{namespace}:impressions"
          @cpm_key = "#{namespace}:cpm"
          @text_key = "#{namespace}:text"
        end

        def record(ad = nil, surface: Surfaces::UNKNOWN, **ad_kwargs)
          ad = Store.coerce_ad(ad, ad_kwargs)
          id = Identity.id_for(ad)
          surface = Surfaces.coerce(surface)
          @client.hincrby(@impressions_key, id, 1)
          @client.hincrby(surface_key(surface), id, 1)
          @client.hset(@cpm_key, id, ad[:cpm].to_f)
          @client.hset(@text_key, id, ad[:text].to_s)
        end

        def snapshot
          impressions = @client.hgetall(@impressions_key)
          cpm = @client.hgetall(@cpm_key)
          text = @client.hgetall(@text_key)

          impressions.each_with_object({}) do |(id, count), acc|
            acc[id] = { text: text[id], impressions: count.to_i, cpm: cpm[id].to_f }
          end
        end

        def surface_snapshot
          Surfaces::ALL.each_with_object({}) do |surface, acc|
            @client.hgetall(surface_key(surface)).each do |id, count|
              (acc[id] ||= {})[surface] = count.to_i
            end
          end
        end

        def reset
          @client.del(@impressions_key, @cpm_key, @text_key, *Surfaces::ALL.map { |s| surface_key(s) })
          self
        end

        private

        # One impressions hash per surface, so a surface tally increments
        # atomically the same way the per-ad total does (HINCRBY), never a
        # read-modify-write.
        #
        def surface_key(surface)
          "#{@namespace}:impressions:#{surface}"
        end

        # Lazy-require keeps redis an optional dependency.
        #
        def build_default_client
          require "redis"
          ::Redis.new
        rescue LoadError
          raise LoadError, "SponsoredLogs::Ledger::Store::Redis requires the `redis` gem. " \
                           "Add it to your Gemfile, or pass a client: to the constructor."
        end
      end
    end
  end
end
