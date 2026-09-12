# frozen_string_literal: true

require_relative "html_comment"

module SponsoredLogs
  # Tier 2 of HTML-comment ads: append a host-read [AD] comment after a rendered
  # partial, turning partial-heavy pages into component-level ad inventory. We
  # prepend onto ActionView::Renderer#render, the single entry point whose return
  # value is the final rendered STRING, and act only when options carries
  # :partial so full template renders (the page tier's job) are left alone.
  # Hooking the output string (never the template source) makes this
  # engine-agnostic for free: ERB, HAML, and Slim all compile down to the same
  # rendered string.
  #
  # Higher risk than the page tier, so it is doubly gated at runtime: the
  # partial_ads flag is off by default AND SponsoredLogs must be active AND the
  # html_probability roll must pass (all inside decorate via maybe_html_comment).
  # The prepend itself is therefore inert until explicitly enabled, exactly like
  # the controller patch, so installing it unconditionally is safe.
  #
  module PartialPatch
    module RenderPatch
      def render(context, options)
        rendered = super
        return rendered unless options.is_a?(Hash) && options.key?(:partial)

        SponsoredLogs::PartialPatch.decorate(rendered)
      end
    end

    # Given the rendered string of one partial, optionally append an [AD] comment
    # and return the (possibly augmented) string. Every gate that could suppress
    # a placement lives here so the prepend stays a thin pass-through:
    # - partial_ads must be enabled (opt-in; off by default),
    # - maybe_html_comment enforces active? + the html_probability roll,
    # - injectable? confirms the string is ordinary HTML element markup and not a
    #   script body, JSON blob, SVG document, or trivial fragment.
    # The original string is always returned untouched when any gate fails, and a
    # rescue guarantees an ad failure can never break the host render.
    #
    def self.decorate(rendered)
      return rendered unless SponsoredLogs.configuration.partial_ads
      return rendered unless HtmlComment.injectable?(rendered.to_s)

      comment = SponsoredLogs.maybe_html_comment
      return rendered if comment.nil?

      "#{rendered}#{comment}"
    rescue StandardError
      # Ad delivery must never break the host render; swallow and return as-is.
      #
      rendered
    end

    def self.install!
      return if @installed
      return unless defined?(ActionView::Renderer)

      ActionView::Renderer.prepend(RenderPatch)
      @installed = true
    end

    def self.installed?
      @installed == true
    end
  end
end
