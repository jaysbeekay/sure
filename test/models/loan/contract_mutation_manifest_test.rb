require "test_helper"

# The mutation gate (`loans:verify_contract_mutations`) is only as good as its
# anchors: a `find` string that no longer matches the production file mutates
# nothing, and the row's tests then "survive" for a reason that has nothing to
# do with the contract. The gate aborts when that happens, but it takes minutes
# to run and nothing forces it. This runs in the normal suite instead, so a
# refactor that moves an anchor fails immediately and next to the change.
#
# A row is either one mutation or a list of them, one per test entry the row
# names in config/loan_contract_tests.yml (#406). Every check below runs over
# each mutation of each row.
class Loan::ContractMutationManifestTest < ActiveSupport::TestCase
  MUTATIONS = YAML.load_file(Rails.root.join("config/loan_contract_mutations.yml")).freeze
  TEST_ENTRIES = YAML.load_file(Rails.root.join("config/loan_contract_tests.yml")).freeze
  CONTRACT_ROWS = (1..16).map { |number| "C#{number}" }.freeze

  test "every contract row has a mutation" do
    assert_equal CONTRACT_ROWS, MUTATIONS.keys.sort_by { |id| id.delete_prefix("C").to_i }
  end

  test "every row carries one mutation per test entry" do
    CONTRACT_ROWS.each do |id|
      mutations = Array.wrap(MUTATIONS.fetch(id))
      entries = Array.wrap(TEST_ENTRIES.fetch(id))

      assert mutations.any?, "#{id}: a row with an empty mutation list proves nothing"
      assert_equal entries.length, mutations.length,
        "#{id}: #{entries.length} test entries but #{mutations.length} mutations; each entry's tests must be proven by a mutation of their own"
    end
  end

  test "every mutation anchor matches its production file exactly once" do
    each_mutation do |label, mutation|
      path = Rails.root.join(mutation.fetch("file"))
      assert path.file?, "#{label}: #{mutation.fetch('file')} does not exist"

      occurrences = path.read.scan(mutation.fetch("find")).length
      assert_equal 1, occurrences,
        "#{label}: anchor matches #{occurrences} times in #{mutation.fetch('file')}; a mutation that matches nothing proves nothing"
    end
  end

  test "every mutation changes the source it targets" do
    each_mutation do |label, mutation|
      assert_not_equal mutation.fetch("find"), mutation.fetch("replace"),
        "#{label}: replacement is identical to the anchor, so the mutation is a no-op"
      assert mutation.fetch("defect").present?, "#{label}: mutation must describe the defect it injects"
    end
  end

  test "mutations target production code, not tests" do
    each_mutation do |label, mutation|
      assert_match %r{\Aapp/}, mutation.fetch("file"),
        "#{label}: mutating a test would prove the test can be broken, not that it pins behaviour"
    end
  end

  private
    def each_mutation
      MUTATIONS.each do |id, value|
        mutations = Array.wrap(value)
        mutations.each.with_index(1) do |mutation, position|
          yield(mutations.one? ? id : "#{id}##{position}", mutation)
        end
      end
    end
end
