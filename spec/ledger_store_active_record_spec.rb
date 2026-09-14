# frozen_string_literal: true

require "active_record"
require "digest"
require "tmpdir"

RSpec.describe SponsoredLogs::Ledger::Store::ActiveRecord do
  before(:all) do
    # A file-backed SQLite db (not :memory:) so every connection in the pool --
    # including ones opened by other threads -- sees the same table.
    #
    @db_path = File.join(Dir.mktmpdir, "sponsored_logs_test.sqlite3")
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: @db_path)
    ActiveRecord::Schema.verbose = false
    ActiveRecord::Schema.define do
      create_table :sponsored_logs_impressions, force: true do |t|
        t.string  :ad_id,       null: false
        t.text    :text,        null: false
        t.integer :impressions, null: false, default: 0
        t.float   :cpm,         null: false, default: 0.0
        t.integer :impressions_log,     null: false, default: 0
        t.integer :impressions_page,    null: false, default: 0
        t.integer :impressions_partial, null: false, default: 0
        t.integer :impressions_unknown, null: false, default: 0
        t.timestamps
      end
      add_index :sponsored_logs_impressions, :ad_id, unique: true
    end
  end

  after(:all) do
    ActiveRecord::Base.remove_connection
    FileUtils.rm_f(@db_path)
  end

  let(:store) { described_class.new }

  after { store.reset }

  it "records impressions and cpm, keyed by id with text as a value", :aggregate_failures do
    2.times { store.record(id: "a", text: "Ad A", weight: 1, cpm: 10.0) }
    store.record(id: "b", text: "Ad B", weight: 1, cpm: 5.0)

    expect(store.snapshot).to eq(
      "a" => { text: "Ad A", impressions: 2, cpm: 10.0 },
      "b" => { text: "Ad B", impressions: 1, cpm: 5.0 }
    )
  end

  it "defaults a no-id ad's ad_id to SHA256(text), matching the old digest key", :aggregate_failures do
    store.record(text: "legacy copy", weight: 1, cpm: 4.0)

    digest = Digest::SHA256.hexdigest("legacy copy")
    expect(store.snapshot.keys).to eq([digest])
    expect(store.snapshot[digest]).to eq(text: "legacy copy", impressions: 1, cpm: 4.0)
  end

  it "keeps one tally for a stable id across a copy edit", :aggregate_failures do
    store.record(id: "promo", text: "v1", weight: 1, cpm: 6.0)
    store.record(id: "promo", text: "v2 edited", weight: 1, cpm: 6.0)

    expect(store.snapshot.keys).to eq(["promo"])
    expect(store.snapshot["promo"]).to eq(text: "v2 edited", impressions: 2, cpm: 6.0)
  end

  it "persists across store instances (same table)", :aggregate_failures do
    described_class.new.record(id: "persisted", text: "Persisted", weight: 1, cpm: 7.0)

    fresh = described_class.new
    expect(fresh.snapshot["persisted"]).to eq(text: "Persisted", impressions: 1, cpm: 7.0)
  end

  it "increments atomically under concurrency" do
    threads = Array.new(5) do
      Thread.new { 20.times { described_class.new.record(id: "hot", text: "Hot", weight: 1, cpm: 1.0) } }
    end
    threads.each(&:join)

    expect(store.snapshot["hot"][:impressions]).to eq(100)
  end

  it "records a per-surface tally on the same row as the per-ad total", :aggregate_failures do
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

  it "reset clears the rows" do
    store.record(id: "a", text: "Ad A", weight: 1, cpm: 10.0)
    store.reset
    expect(store.snapshot).to eq({})
  end

  it "handles long ad text via the id key" do
    long = "Sponsored by #{"x" * 5000}"
    store.record(id: "long", text: long, weight: 1, cpm: 3.0)

    expect(store.snapshot["long"]).to eq(text: long, impressions: 1, cpm: 3.0)
  end
end
