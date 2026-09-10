require "test_helper"

class Portfolio::ContractCoverageTest < ActiveSupport::TestCase
  setup do
    @dir = Dir.mktmpdir
    @test_file = "test/models/portfolio/flow_classifier_test.rb"
    write_contract(<<~MD)
      | ID | Decision | Demonstrating test | Resolves |
      | --- | --- | --- | --- |
      | P1 | first | `Portfolio::FlowClassifierTest` "a Dividend income trade is income" | - |
      | P2 | second | `Portfolio::FlowClassifierTest` "every activity label has a rule" | - |
    MD
    write_manifest(
      "P1" => [ entry("a Dividend income trade is income") ],
      "P2" => [ entry("every activity label has a rule") ]
    )
  end

  teardown do
    FileUtils.remove_entry(@dir)
  end

  test "the committed contract and manifest verify" do
    count = Portfolio::ContractCoverage.new(
      contract_path: Rails.root.join("docs/portfolio/methodology.md"),
      manifest_path: Rails.root.join("config/portfolio_contract_tests.yml")
    ).verify!

    assert_operator count, :>=, 20
  end

  test "verifies a contract whose rows all name existing tests" do
    assert_equal 2, coverage.verify!
  end

  test "fails when a row names a test that does not exist" do
    # Document and manifest agree, so the earlier cross-check passes and the
    # failure is the one this test is about: the named test is in neither.
    write_contract(<<~MD)
      | P1 | first | `Portfolio::FlowClassifierTest` "a Dividend income trade is income" | - |
      | P2 | second | `Portfolio::FlowClassifierTest` "a test that was renamed" | - |
    MD
    write_manifest("P1" => [ entry("a Dividend income trade is income") ], "P2" => [ entry("a test that was renamed") ])

    error = assert_raises(Portfolio::ContractCoverage::Error) { coverage.verify! }
    assert_match(/P2: missing test "a test that was renamed"/, error.message)
  end

  test "fails when the document and the manifest disagree on the test class" do
    write_manifest(
      "P1" => [ entry("a Dividend income trade is income") ],
      "P2" => [ entry("every activity label has a rule", class_name: "Portfolio::OtherTest") ]
    )

    error = assert_raises(Portfolio::ContractCoverage::Error) { coverage.verify! }
    assert_match(/P2: contract names Portfolio::FlowClassifierTest, manifest names Portfolio::OtherTest/, error.message)
  end

  test "fails when the rows do not run P1..Pn without gaps" do
    write_contract(<<~MD)
      | P1 | first | `Portfolio::FlowClassifierTest` "a Dividend income trade is income" | - |
      | P3 | third | `Portfolio::FlowClassifierTest` "every activity label has a rule" | - |
    MD
    write_manifest("P1" => [ entry("a Dividend income trade is income") ], "P3" => [ entry("every activity label has a rule") ])

    error = assert_raises(Portfolio::ContractCoverage::Error) { coverage.verify! }
    assert_match(/contract rows must run P1-P3 without gaps/, error.message)
  end

  test "fails when the document cites a test the manifest does not name" do
    write_contract(<<~MD)
      | P1 | first | `Portfolio::FlowClassifierTest` "a test nobody wrote" | - |
    MD
    write_manifest("P1" => [ entry("a Dividend income trade is income") ])

    error = assert_raises(Portfolio::ContractCoverage::Error) { coverage.verify! }
    assert_match(/P1: Portfolio::FlowClassifierTest/, error.message)
    assert_match(/document cites "a test nobody wrote"/, error.message)
  end

  test "fails when the document omits a test the manifest names" do
    write_contract(<<~MD)
      | P1 | first | `Portfolio::FlowClassifierTest` "a Dividend income trade is income" | - |
    MD
    write_manifest("P1" => [ entry("a Dividend income trade is income", "every activity label has a rule") ])

    error = assert_raises(Portfolio::ContractCoverage::Error) { coverage.verify! }
    assert_match(/document does not cite "every activity label has a rule"/, error.message)
  end

  test "fails when the named test lives in a different class in the same file" do
    File.write(File.join(@dir, "two_classes_test.rb"), <<~RUBY)
      class AlphaTest < ActiveSupport::TestCase
        test "belongs to alpha" do
        end
      end

      class BetaTest < ActiveSupport::TestCase
        test "belongs to beta" do
        end
      end
    RUBY
    write_contract(<<~MD)
      | P1 | first | `AlphaTest` "belongs to beta" | - |
    MD
    write_manifest("P1" => [ { "file" => "two_classes_test.rb", "class" => "AlphaTest", "tests" => [ "belongs to beta" ] } ])

    error = assert_raises(Portfolio::ContractCoverage::Error) do
      Portfolio::ContractCoverage.new(
        contract_path: File.join(@dir, "methodology.md"),
        manifest_path: File.join(@dir, "manifest.yml"),
        root: @dir
      ).verify!
    end
    assert_match(/missing test "belongs to beta" in AlphaTest/, error.message)
  end

  test "a manifest entry missing a required key is a contract error, not a KeyError" do
    write_contract(<<~MD)
      | P1 | first | `Portfolio::FlowClassifierTest` "a Dividend income trade is income" | - |
    MD
    write_manifest("P1" => [ { "class" => "Portfolio::FlowClassifierTest" } ])

    error = assert_raises(Portfolio::ContractCoverage::Error) { coverage.verify! }
    assert_match(/manifest entry has no "tests"/, error.message)
  end

  test "fails when a row is duplicated in the document" do
    write_contract(<<~MD)
      | P1 | first | `Portfolio::FlowClassifierTest` "a Dividend income trade is income" | - |
      | P1 | again | `Portfolio::FlowClassifierTest` "every activity label has a rule" | - |
    MD

    error = assert_raises(Portfolio::ContractCoverage::Error) { coverage.verify! }
    assert_match(/duplicate contract rows: P1/, error.message)
  end

  test "fails when a row names a test class that is not declared in the file" do
    write_contract(<<~MD)
      | P1 | first | `Portfolio::MissingTest` "a Dividend income trade is income" | - |
    MD
    write_manifest("P1" => [ entry("a Dividend income trade is income", class_name: "Portfolio::MissingTest") ])

    error = assert_raises(Portfolio::ContractCoverage::Error) { coverage.verify! }
    assert_match(/P1: Portfolio::MissingTest is not declared/, error.message)
  end

  private
    def coverage
      Portfolio::ContractCoverage.new(
        contract_path: File.join(@dir, "methodology.md"),
        manifest_path: File.join(@dir, "manifest.yml")
      )
    end

    def entry(*tests, class_name: "Portfolio::FlowClassifierTest")
      { "file" => @test_file, "class" => class_name, "tests" => tests }
    end

    def write_contract(body)
      File.write(File.join(@dir, "methodology.md"), body)
    end

    def write_manifest(rows)
      File.write(File.join(@dir, "manifest.yml"), rows.to_yaml)
    end
end
