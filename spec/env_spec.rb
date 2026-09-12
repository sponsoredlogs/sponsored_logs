# frozen_string_literal: true

RSpec.describe SponsoredLogs::Env do
  describe ".activate?" do
    it "is true for recognized truthy values", :aggregate_failures do
      %w[1 true TRUE yes On].each do |val|
        expect(described_class.activate?("SPONSORED_LOGS" => val)).to be(true)
      end
    end

    it "is false when unset or non-truthy", :aggregate_failures do
      expect(described_class.activate?({})).to be(false)
      expect(described_class.activate?("SPONSORED_LOGS" => "0")).to be(false)
      expect(described_class.activate?("SPONSORED_LOGS" => "nope")).to be(false)
    end
  end

  describe ".options" do
    it "returns an empty hash when nothing is configured" do
      expect(described_class.options({})).to eq({})
    end

    it "parses each supported override", :aggregate_failures do
      env = {
        "SPONSORED_LOGS_PROBABILITY" => "0.25",
        "SPONSORED_LOGS_HTML_PROBABILITY" => "0.75",
        "SPONSORED_LOGS_INTERVAL" => "15",
        "SPONSORED_LOGS_PERIODIC" => "true",
        "SPONSORED_LOGS_PREFIX" => "SPONSORED:",
        "SPONSORED_LOGS_ADS_FILE" => "/tmp/ads.json",
        "SPONSORED_LOGS_PARTIAL_ADS" => "true"
      }

      expect(described_class.options(env)).to eq(
        probability: 0.25,
        html_probability: 0.75,
        interval: 15.0,
        periodic: true,
        ad_prefix: "SPONSORED:",
        ads_file: "/tmp/ads.json",
        partial_ads: true
      )
    end

    it "coerces SPONSORED_LOGS_PARTIAL_ADS truthily", :aggregate_failures do
      expect(described_class.options("SPONSORED_LOGS_PARTIAL_ADS" => "1")).to eq(partial_ads: true)
      expect(described_class.options("SPONSORED_LOGS_PARTIAL_ADS" => "on")).to eq(partial_ads: true)
      expect(described_class.options("SPONSORED_LOGS_PARTIAL_ADS" => "0")).to eq(partial_ads: false)
      expect(described_class.options("SPONSORED_LOGS_PARTIAL_ADS" => "nope")).to eq(partial_ads: false)
    end
  end
end

RSpec.describe SponsoredLogs do
  describe ".sponsor_from_env!" do
    it "does nothing when the flag is absent", :aggregate_failures do
      described_class.sponsor_from_env!({})

      expect(described_class.active?).to be(false)
    end

    it "activates and applies overrides when the flag is set", :aggregate_failures do
      env = {
        "SPONSORED_LOGS" => "1",
        "SPONSORED_LOGS_PROBABILITY" => "0.5",
        "SPONSORED_LOGS_PREFIX" => "AD!"
      }

      described_class.sponsor_from_env!(env)

      expect(described_class.active?).to be(true)
      expect(described_class.configuration.probability).to eq(0.5)
      expect(described_class.configuration.ad_prefix).to eq("AD!")
    end

    it "leaves manual activation untouched" do
      described_class.sponsor_from_env!({})
      described_class.sponsor!(probability: 0.3)

      expect(described_class.active?).to be(true)
    end
  end
end
