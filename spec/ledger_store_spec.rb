# frozen_string_literal: true

RSpec.describe SponsoredLogs::Ledger::Store::Base do
  it "raises NotImplementedError for the contract methods", :aggregate_failures do
    base = described_class.new
    expect { base.record({}) }.to raise_error(NotImplementedError)
    expect { base.snapshot }.to raise_error(NotImplementedError)
    expect { base.reset }.to raise_error(NotImplementedError)
  end
end

RSpec.describe SponsoredLogs::Ledger::Store::Memory do
  let(:store) { described_class.new }

  it "records impressions and cpm, keyed by id with text as a value", :aggregate_failures do
    2.times { store.record(id: "a", text: "Ad A", weight: 1, cpm: 10.0) }
    store.record(id: "b", text: "Ad B", weight: 1, cpm: 5.0)

    expect(store.snapshot).to eq(
      "a" => { text: "Ad A", impressions: 2, cpm: 10.0 },
      "b" => { text: "Ad B", impressions: 1, cpm: 5.0 }
    )
  end

  it "records a per-surface tally alongside the per-ad total", :aggregate_failures do
    store.record({ id: "a", text: "Ad A", weight: 1, cpm: 10.0 }, surface: :log)
    store.record({ id: "a", text: "Ad A", weight: 1, cpm: 10.0 }, surface: :page)
    store.record({ id: "a", text: "Ad A", weight: 1, cpm: 10.0 }, surface: :log)

    expect(store.snapshot["a"][:impressions]).to eq(3)
    expect(store.surface_snapshot).to eq("a" => { log: 2, page: 1 })
  end

  it "coerces an unknown surface to :unknown in the tally" do
    store.record({ id: "a", text: "Ad A", weight: 1, cpm: 10.0 }, surface: :bogus)

    expect(store.surface_snapshot).to eq("a" => { unknown: 1 })
  end

  it "defaults a surface-less record to :unknown and keeps the old snapshot shape", :aggregate_failures do
    store.record(id: "a", text: "Ad A", weight: 1, cpm: 10.0)

    expect(store.snapshot).to eq("a" => { text: "Ad A", impressions: 1, cpm: 10.0 })
    expect(store.surface_snapshot).to eq("a" => { unknown: 1 })
  end

  it "reset clears the snapshot" do
    store.record(id: "a", text: "Ad A", weight: 1, cpm: 10.0)
    store.reset
    expect(store.snapshot).to eq({})
  end

  it "reset clears the surface tally too" do
    store.record({ id: "a", text: "Ad A", weight: 1, cpm: 10.0 }, surface: :log)
    store.reset
    expect(store.surface_snapshot).to eq({})
  end

  it "records concurrently without losing increments" do
    threads = Array.new(10) do
      Thread.new { 100.times { store.record(id: "a", text: "Ad A", weight: 1, cpm: 1.0) } }
    end
    threads.each(&:join)

    expect(store.snapshot["a"][:impressions]).to eq(1000)
  end
end

RSpec.describe SponsoredLogs::Ledger::Store::Redis do
  # Minimal in-memory stand-in for the redis client, exercising the exact
  # commands the adapter uses (hincrby/hset/hgetall/del).
  #
  let(:fake_redis) do
    Class.new do
      def initialize
        @hashes = Hash.new { |h, k| h[k] = {} }
      end

      def hincrby(key, field, by)
        @hashes[key][field] = @hashes[key].fetch(field, 0).to_i + by
      end

      def hset(key, field, value)
        @hashes[key][field] = value.to_s
      end

      def hgetall(key)
        @hashes[key].transform_values(&:to_s)
      end

      def del(*keys)
        keys.each { |k| @hashes.delete(k) }
      end
    end.new
  end

  let(:store) { described_class.new(client: fake_redis) }

  it "records impressions and cpm via the client, keyed by id", :aggregate_failures do
    2.times { store.record(id: "a", text: "Ad A", weight: 1, cpm: 10.0) }
    store.record(id: "b", text: "Ad B", weight: 1, cpm: 5.0)

    expect(store.snapshot).to eq(
      "a" => { text: "Ad A", impressions: 2, cpm: 10.0 },
      "b" => { text: "Ad B", impressions: 1, cpm: 5.0 }
    )
  end

  it "records a per-surface tally via the client alongside the per-ad total", :aggregate_failures do
    store.record({ id: "a", text: "Ad A", weight: 1, cpm: 10.0 }, surface: :log)
    store.record({ id: "a", text: "Ad A", weight: 1, cpm: 10.0 }, surface: :page)
    store.record({ id: "a", text: "Ad A", weight: 1, cpm: 10.0 }, surface: :log)

    expect(store.snapshot["a"][:impressions]).to eq(3)
    expect(store.surface_snapshot).to eq("a" => { log: 2, page: 1 })
  end

  it "defaults a surface-less record to :unknown and keeps the old snapshot shape", :aggregate_failures do
    store.record(id: "a", text: "Ad A", weight: 1, cpm: 10.0)

    expect(store.snapshot).to eq("a" => { text: "Ad A", impressions: 1, cpm: 10.0 })
    expect(store.surface_snapshot).to eq("a" => { unknown: 1 })
  end

  it "reset deletes the keys" do
    store.record(id: "a", text: "Ad A", weight: 1, cpm: 10.0)
    store.reset
    expect(store.snapshot).to eq({})
  end

  it "reset deletes the per-surface keys too" do
    store.record({ id: "a", text: "Ad A", weight: 1, cpm: 10.0 }, surface: :log)
    store.reset
    expect(store.surface_snapshot).to eq({})
  end
end
