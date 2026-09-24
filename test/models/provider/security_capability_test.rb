require "test_helper"

# The declarations in #212 gate whether a provider is asked at all, so a
# provider that CAN answer and forgets to say so is silently never asked --
# look-through simply never populates, and classification silently stops, and
# both read as missing data rather than as a missing line of code.
#
# That is not hypothetical: it happened in the first cut of #212. Alpha Vantage
# and Yahoo Finance both return `sector` and `industry`, both were left on the
# `false` default, and cubic caught it in review rather than a user catching it
# in production.
#
# So the declarations are checked against what the providers actually build. The
# source is read rather than the provider called, because calling means API keys
# and network, and the thing worth pinning is the pairing itself.
class Provider::SecurityCapabilityTest < ActiveSupport::TestCase
  PROVIDER_FILES = Dir[Rails.root.join("app/models/provider/*.rb")].freeze

  test "every provider that returns a classification declares it" do
    mismatched = capability_mismatches(builds: /^\s*sector:/, declares: :supplies_classification?)

    assert_empty mismatched,
                 "these providers return sector/industry but answer false to supplies_classification?, " \
                 "so #212's gate will never ask them: #{mismatched.join(", ")}"
  end

  test "every provider that returns constituents declares it" do
    mismatched = capability_mismatches(builds: /^\s*constituents:/, declares: :supplies_constituents?)

    assert_empty mismatched,
                 "these providers return constituents but answer false to supplies_constituents?, " \
                 "so #212's gate will never ask them: #{mismatched.join(", ")}"
  end

  # The other direction, so the tests above cannot be satisfied by declaring
  # everything true: a provider that builds neither must not claim either.
  test "a provider that returns neither claims neither" do
    overclaiming = security_providers.reject do |klass, source|
      next true if source.match?(/^\s*sector:/) || source.match?(/^\s*constituents:/)

      instance = klass.allocate
      !instance.supplies_classification? && !instance.supplies_constituents?
    end.map { |klass, _| klass.name }

    assert_empty overclaiming,
                 "these providers declare a capability they never build a value for: #{overclaiming.join(", ")}"
  end

  private
    def security_providers
      PROVIDER_FILES.filter_map do |path|
        klass = "Provider::#{File.basename(path, ".rb").camelize}".safe_constantize
        next unless klass.is_a?(Class) && klass.include?(Provider::SecurityConcept)

        [ klass, File.read(path) ]
      end
    end

    def capability_mismatches(builds:, declares:)
      security_providers.filter_map do |klass, source|
        next unless source.match?(builds)

        klass.name unless klass.allocate.public_send(declares)
      end
    end
end
