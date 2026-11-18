# frozen_string_literal: true

require "test_helper"
require "rubocop"

# .rubocop-codacy.yml is a hand-flattened copy of what .rubocop.yml resolves to,
# because Codacy's RuboCop image cannot load the rubocop-rails-omakase gem. A
# gem bump or a new local override changes one and not the other; this fails
# when they stop agreeing, instead of Codacy quietly linting to other rules.
class CodacyRubocopConfigTest < ActiveSupport::TestCase
  test "the Codacy RuboCop config resolves to the same rules as the repository's" do
    repository = effective_config(".rubocop.yml")
    codacy = effective_config(".rubocop-codacy.yml")

    # The repository's own Sure/ cops load through .rubocop.yml's `require:`, which
    # Codacy's image cannot run, so the flattened copy leaves them out.
    drifted = (repository.keys | codacy.keys).reject { |name| name.start_with?("Sure/") || repository[name] == codacy[name] }

    assert_empty drifted, "regenerate .rubocop-codacy.yml from the gem's config plus .rubocop.yml; differs on #{drifted.join(', ')}"
  end

  private
    # Per cop: whether it runs, and every other option. Whether it runs is asked
    # of RuboCop rather than read from "Enabled", because a cop enabled inside a
    # disabled department resolves to "override_department" through
    # inherit_gem but to true when written out flat, and both mean it runs.
    def effective_config(path)
      config = RuboCop::ConfigLoader.load_file(Rails.root.join(path).to_s)
      names = RuboCop::Cop::Registry.global.map(&:cop_name) | config.to_h.keys

      names.sort.to_h do |name|
        if name.include?("/")
          [ name, [ config.cop_enabled?(name), config.for_cop(name).except("Enabled") ] ]
        else
          [ name, config.to_h[name] ]
        end
      end
    end
end
