# frozen_string_literal: true

require "rails"
require "action_controller"
require "action_controller/metal"

require "sponsored_logs/controller_patch"

# Rails permits only one Rails::Application#initialize! per process (engine_spec
# owns that boot), so we deliberately avoid booting an app here. Instead we
# exercise the patched dispatch path directly: ActionController::Metal.action
# returns a Rack endpoint we can call with a minimal env, giving us a genuine
# ActionController response (real media_type, real body) without a host app.
#
RSpec.describe SponsoredLogs::ControllerPatch do
  before(:all) do
    SponsoredLogs::ControllerPatch.install!
  end

  # Minimal controllers built on Metal so .action works without routing/app.
  #
  html_controller = Class.new(ActionController::Metal) do
    include AbstractController::Rendering
    include ActionController::Rendering

    def show
      self.content_type = "text/html; charset=utf-8"
      self.response_body = "<html><body>Hello</body></html>"
    end
  end

  json_controller = Class.new(ActionController::Metal) do
    def data
      self.content_type = "application/json"
      self.response_body = '{"ok":true}'
    end
  end

  def call(controller, action)
    env = Rack::MockRequest.env_for("/")
    status, headers, body = controller.action(action).call(env)
    joined = +""
    body.each { |chunk| joined << chunk }
    [status, headers, joined]
  end

  it "appends an ad comment to an HTML response when active", :aggregate_failures do
    SponsoredLogs.sponsor!(html_probability: 1.0, ads: [{ text: "Trailing ad", weight: 1 }])

    _status, _headers, body = call(html_controller, :show)

    expect(body).to include("<!-- [AD] Trailing ad -->")
    # Comment lands after the closing html tag (trailing append, this PR).
    #
    expect(body).to match(%r{</html>.*<!-- \[AD\] Trailing ad -->}m)
  end

  it "records the impression to the :page surface", :aggregate_failures do
    SponsoredLogs.reset_ledger!
    SponsoredLogs.sponsor!(html_probability: 1.0, ads: [{ text: "Trailing ad", weight: 1, cpm: 10.0 }])

    call(html_controller, :show)

    expect(SponsoredLogs.report[:impressions_by_surface]).to eq(log: 0, page: 1, partial: 0, unknown: 0)
  end

  it "does not touch a non-HTML response", :aggregate_failures do
    SponsoredLogs.sponsor!(html_probability: 1.0, ads: [{ text: "Trailing ad", weight: 1 }])

    _status, _headers, body = call(json_controller, :data)

    expect(body).to eq('{"ok":true}')
    expect(body).not_to include("[AD]")
  end

  it "stays silent when sponsoring is inactive" do
    SponsoredLogs.unsponsor!

    _status, _headers, body = call(html_controller, :show)

    expect(body).not_to include("[AD]")
  end

  it "respects html_probability of zero" do
    SponsoredLogs.sponsor!(html_probability: 0.0, ads: [{ text: "Trailing ad", weight: 1 }])

    _status, _headers, body = call(html_controller, :show)

    expect(body).not_to include("[AD]")
  end

  it "leaves the original HTML intact ahead of the comment" do
    SponsoredLogs.sponsor!(html_probability: 1.0, ads: [{ text: "Trailing ad", weight: 1 }])

    _status, _headers, body = call(html_controller, :show)

    expect(body).to include("<html><body>Hello</body></html>")
  end
end
