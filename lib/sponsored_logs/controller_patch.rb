# frozen_string_literal: true

module SponsoredLogs
  # Tier 1 of HTML-comment ads: append a host-read [AD] comment to the tail of
  # an HTML controller response. Prepended onto the controller dispatch path so
  # it runs after the action has built its response. Like the log Injector, a
  # prepend can't be undone, so SponsoredLogs.active? (via maybe_html_comment)
  # is what actually gates emission; install! just wires the prepend once.
  #
  module ControllerPatch
    module RenderPatch
      def dispatch(*, **)
        result = super
        SponsoredLogs::ControllerPatch.decorate(response)
        result
      end
    end

    # Append a comment to the response body when the response is HTML. Gating
    # (active? + html_probability roll) lives in maybe_html_comment, so a nil
    # return there means "no placement" and we leave the body untouched. The
    # comment is appended after the existing body (after </html>): the
    # deliberate low-risk trailing-append placement for this PR.
    #
    def self.decorate(response)
      return unless response
      return unless html_response?(response)

      comment = SponsoredLogs.maybe_html_comment(surface: SponsoredLogs::Surfaces::PAGE)
      return if comment.nil?

      response.body = "#{response.body}#{comment}"
    rescue StandardError
      # Ad delivery must never break the host response; swallow and move on.
      #
      nil
    end

    # True when the response advertises an HTML media type. Guarded because not
    # every response object exposes media_type/content_type cleanly.
    #
    def self.html_response?(response)
      media = response.media_type if response.respond_to?(:media_type)
      media ||= response.content_type if response.respond_to?(:content_type)
      media.to_s.include?("text/html")
    end

    def self.install!
      return if @installed
      return unless defined?(ActionController::Metal)

      ActionController::Metal.prepend(RenderPatch)
      @installed = true
    end

    def self.installed?
      @installed == true
    end
  end
end
