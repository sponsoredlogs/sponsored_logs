# frozen_string_literal: true

RSpec.describe SponsoredLogs::Surfaces do
  describe ".coerce" do
    it "passes known surfaces through unchanged", :aggregate_failures do
      expect(described_class.coerce(:log)).to eq(:log)
      expect(described_class.coerce(:page)).to eq(:page)
      expect(described_class.coerce(:partial)).to eq(:partial)
      expect(described_class.coerce(:unknown)).to eq(:unknown)
    end

    it "accepts string forms and normalizes case/whitespace", :aggregate_failures do
      expect(described_class.coerce("log")).to eq(:log)
      expect(described_class.coerce(" PAGE ")).to eq(:page)
    end

    it "coerces anything unrecognized to :unknown", :aggregate_failures do
      expect(described_class.coerce(nil)).to eq(:unknown)
      expect(described_class.coerce(:bogus)).to eq(:unknown)
      expect(described_class.coerce("email")).to eq(:unknown)
    end
  end

  it "lists every surface in ALL with :unknown last", :aggregate_failures do
    expect(described_class::ALL).to eq(%i[log page partial unknown])
    expect(described_class::ALL.last).to eq(:unknown)
  end
end
