# frozen_string_literal: true

require "tmpdir"

require "action_view"

require "sponsored_logs/partial_patch"

# Like controller_patch_spec, we avoid booting a Rails::Application (engine_spec
# owns the single permitted initialize!). Two layers are exercised here:
#
# - decorate: the pure seam the prepend calls, driven with plain strings so the
#   gating (partial_ads + active? + probability + injectable?) is unit-testable.
# - the real prepend: a genuine ActionView::Base rendering a real ERB partial
#   from a temp dir, so we prove Renderer#render_partial actually routes through
#   our patch and returns the augmented string, engine boot not required.
#
RSpec.describe SponsoredLogs::PartialPatch do
  before(:all) do
    SponsoredLogs::PartialPatch.install!
  end

  describe ".decorate" do
    it "appends a comment to HTML markup when enabled, active, and rolled in", :aggregate_failures do
      SponsoredLogs.sponsor!(partial_ads: true, html_probability: 1.0, ads: [{ text: "Partial ad", weight: 1 }])

      result = described_class.decorate("<div>Component body content</div>")

      expect(result).to include("<div>Component body content</div>")
      expect(result).to include("<!-- [AD] Partial ad -->")
      # The comment trails the rendered markup.
      #
      expect(result).to match(%r{</div>.*<!-- \[AD\] Partial ad -->}m)
    end

    it "returns the string untouched when partial_ads is off" do
      SponsoredLogs.sponsor!(partial_ads: false, html_probability: 1.0, ads: [{ text: "Partial ad", weight: 1 }])

      result = described_class.decorate("<div>Component body content</div>")

      expect(result).to eq("<div>Component body content</div>")
    end

    it "returns the string untouched when sponsoring is inactive" do
      SponsoredLogs.unsponsor!
      SponsoredLogs.configuration.partial_ads = true
      SponsoredLogs.configuration.html_probability = 1.0

      result = described_class.decorate("<div>Component body content</div>")

      expect(result).to eq("<div>Component body content</div>")
    end

    it "respects an html_probability of zero" do
      SponsoredLogs.sponsor!(partial_ads: true, html_probability: 0.0, ads: [{ text: "Partial ad", weight: 1 }])

      result = described_class.decorate("<div>Component body content</div>")

      expect(result).not_to include("[AD]")
    end

    it "skips fragments the injectable guard rejects", :aggregate_failures do
      SponsoredLogs.sponsor!(partial_ads: true, html_probability: 1.0, ads: [{ text: "Partial ad", weight: 1 }])

      expect(described_class.decorate("<script>var x = 1;</script>")).to eq("<script>var x = 1;</script>")
      expect(described_class.decorate('{ "a": 1, "b": 2 }')).to eq('{ "a": 1, "b": 2 }')
      expect(described_class.decorate("plain text, no markup at all")).to eq("plain text, no markup at all")
      expect(described_class.decorate("<svg><circle r='5'></circle></svg>")).to eq("<svg><circle r='5'></circle></svg>")
    end

    it "records the impression to the shared ledger", :aggregate_failures do
      SponsoredLogs.sponsor!(partial_ads: true, html_probability: 1.0, ads: [{ text: "Shared", weight: 1, cpm: 10.0 }])

      expect { described_class.decorate("<div>Component body content</div>") }
        .to change { SponsoredLogs.ledger.total_impressions }.by(1)
    end

    it "draws from the same campaigns as logs and pages" do
      SponsoredLogs.sponsor!(partial_ads: true, html_probability: 1.0, ads: [{ text: "OnlyCampaign", weight: 1 }])

      result = described_class.decorate("<div>Component body content</div>")

      expect(result).to include("OnlyCampaign")
    end

    it "never lets an ad failure break the host string" do
      SponsoredLogs.sponsor!(partial_ads: true, html_probability: 1.0, ads: [{ text: "Boom", weight: 1 }])
      allow(SponsoredLogs).to receive(:maybe_html_comment).and_raise("kaboom")

      result = described_class.decorate("<div>Component body content</div>")

      expect(result).to eq("<div>Component body content</div>")
    end
  end

  describe "install!/installed?" do
    it "is idempotent and reports installed", :aggregate_failures do
      described_class.install!
      described_class.install!

      expect(described_class.installed?).to be(true)
    end
  end

  describe "the real prepended render_partial path" do
    around do |example|
      Dir.mktmpdir do |dir|
        @template_dir = dir
        example.run
      end
    end

    def render_partial(name)
      lookup = ActionView::LookupContext.new([@template_dir])
      view = ActionView::Base.with_empty_template_cache.new(lookup, {}, nil)
      view.render(partial: name)
    end

    it "augments a real rendered HTML partial when enabled", :aggregate_failures do
      File.write(File.join(@template_dir, "_widget.html.erb"), "<div>hello from the widget partial</div>")
      SponsoredLogs.sponsor!(partial_ads: true, html_probability: 1.0, ads: [{ text: "Real partial ad", weight: 1 }])

      out = render_partial("widget")

      expect(out).to include("<div>hello from the widget partial</div>")
      expect(out).to include("<!-- [AD] Real partial ad -->")
    end

    it "leaves a real rendered partial untouched when partial_ads is off" do
      File.write(File.join(@template_dir, "_widget.html.erb"), "<div>hello from the widget partial</div>")
      SponsoredLogs.sponsor!(partial_ads: false, html_probability: 1.0, ads: [{ text: "Real partial ad", weight: 1 }])

      out = render_partial("widget")

      expect(out).not_to include("[AD]")
    end

    it "leaves a real rendered non-HTML partial untouched" do
      File.write(File.join(@template_dir, "_data.html.erb"), '{ "count": 42, "ok": true }')
      SponsoredLogs.sponsor!(partial_ads: true, html_probability: 1.0, ads: [{ text: "Real partial ad", weight: 1 }])

      out = render_partial("data")

      expect(out).not_to include("[AD]")
    end
  end
end
