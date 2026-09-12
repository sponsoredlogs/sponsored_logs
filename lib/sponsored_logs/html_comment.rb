# frozen_string_literal: true

module SponsoredLogs
  # Shared, framework-agnostic core for HTML-comment ad placements. Picks an ad
  # (reusing Advertisers.pick), records the impression to the same ledger as the
  # log emitter, and wraps the copy as a hardened HTML comment. The controller
  # render patch (and, in a later PR, a per-partial hook) both route through
  # here, so every surface draws from the same campaigns and one ledger.
  #
  module HtmlComment
    module_function

    # Pick one ad, record the impression, and return it wrapped as an HTML
    # comment: "<!-- [AD] <text> -->". Returns nil when no ad is eligible. No
    # ANSI color: it is meaningless in HTML source, so the copy stays plain.
    #
    def render(config, ledger)
      ad = Advertisers.pick(
        config.ads,
        mode: config.selection,
        counts: ledger.impression_counts
      )
      return if ad.nil?

      ledger.record(ad)

      prefix = config.ad_prefix.to_s.strip
      body = prefix.empty? ? ad[:text] : "#{prefix} #{ad[:text]}"
      "<!-- #{escape(body)} -->"
    end

    # Minimum stripped length a fragment must clear before it is worth (and safe)
    # decorating. Tiny fragments are usually icons, inline glyphs, or partials
    # whose whole job is one attribute or word, where a trailing comment is noise
    # at best and risky at worst.
    #
    MIN_INJECTABLE_LENGTH = 10

    # A closing element tag such as "</div>" or "</my-widget>". Its presence is
    # our proxy for "this rendered string is real HTML element markup" rather
    # than attribute soup, plain text, or a data blob.
    #
    CLOSING_TAG = %r{</[a-zA-Z][\w:-]*>}

    # Conservative gate for the per-partial hook: return true only when a rendered
    # partial string looks like ordinary HTML element markup into which an inert
    # "<!-- [AD] ... -->" comment can be appended harmlessly. We deliberately err
    # toward false: a skipped placement costs nothing, but a comment dropped into
    # a script body, a JSON response, or an SVG document can corrupt the payload.
    # We inspect the OUTPUT string only (never template source), so the check is
    # identical for ERB, HAML, and Slim.
    #
    # A fragment is injectable only when ALL of these hold:
    # - it is non-blank and clears MIN_INJECTABLE_LENGTH (skip trivial fragments),
    # - it contains at least one closing element tag (skip text / void-only soup),
    # - it does not contain "<script" (an HTML comment inside JS is a syntax hazard
    #   and inside a <script> body is not even a comment),
    # - it does not contain "<svg" (SVG/XML documents have their own comment rules
    #   and are not log-style HTML; blanket-skip them rather than reason per-node),
    # - it does not begin with "{" or "[" after stripping (skip JSON-ish blobs;
    #   a partial can render a data structure, and "-->" is not JSON).
    #
    def injectable?(str)
      return false if str.nil?

      stripped = str.to_s.strip
      return false if stripped.length < MIN_INJECTABLE_LENGTH
      return false if stripped.start_with?("{", "[")
      return false if stripped.match?(/<script/i)
      return false if stripped.match?(/<svg/i)

      stripped.match?(CLOSING_TAG)
    end

    # Neutralize the HTML comment delimiter so crafted ad copy cannot close the
    # comment early and break out into live markup (comment-injection). Any "--"
    # run is defused by inserting a zero-width space between the hyphens, which
    # also covers "-->" as a special case. "--" inside a comment is invalid HTML
    # anyway, so this both hardens against injection and yields a well-formed
    # comment. The break is zero-width, so View Source reads normally.
    #
    def escape(text)
      text.to_s.gsub(/-(?=-)/, "-\u200B")
    end
  end
end
