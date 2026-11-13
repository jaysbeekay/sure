require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"

load File.expand_path("../../bin/preflight_conventions", __dir__)

# Each test builds a two-commit repository: BASE holds the files as they were,
# HEAD the change under review. Only what HEAD adds may be reported.
class PreflightConventionsTest < Minitest::Test
  SCHEMA = "ActiveRecord::Schema[8.1].define(version: 2026_11_01_000000) do\nend\n".freeze

  def setup
    @dir = Dir.mktmpdir("preflight")
    git("init", "-q", "-b", "main")
    git("config", "user.email", "test@example.com")
    git("config", "user.name", "Test")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  # --- rule 1: fork history in comments ---

  def test_flags_each_fork_history_pattern_in_a_comment
    hits = check({}, "app/models/foo.rb" => <<~RUBY)
      class Foo
        # see jaysbeekay/sure#123
        # slice 4.1b of the income work
        # addresses the CodeRabbit review
        # opened as a fork PR first
      end
    RUBY

    assert_equal [ 2, 3, 4, 5 ], lines_for(hits, "fork-history")
  end

  def test_flags_erb_and_js_comments_and_a_trailing_ruby_comment
    hits = check({},
      "app/views/foo/show.html.erb" => "<%# drop IP4 layout %>\n",
      "app/javascript/foo.js" => "// per the cubic review\n",
      "app/models/bar.rb" => "x = 1 # from jaysbeekay/sure#9\n")

    assert_equal [ "app/javascript/foo.js", "app/models/bar.rb", "app/views/foo/show.html.erb" ], hits.map(&:path).sort
  end

  def test_leaves_the_same_text_outside_a_comment_and_upstream_references
    hits = check({},
      "test/models/foo_test.rb" => %(test "slice 4.1b totals" do\n  assert true\nend\n),
      "config/foo.yml" => "label: addresses the review\n",
      "app/models/foo.rb" => "# Mirrors the rule in we-promise/sure#4383.\nputs \"x # from jaysbeekay/sure#1\"\n")

    assert_empty hits
  end

  # --- rule 2: Rails.logger instead of DebugLogEntry ---

  def test_flags_a_logger_in_an_importer_and_in_import_namespace
    hits = check({},
      "app/models/mint_import.rb" => method_with("Rails.logger.warn(\"bad row\")"),
      "app/models/import/row_parser.rb" => method_with("Rails.logger.error(\"bad\")"))

    assert_equal [ "app/models/import/row_parser.rb", "app/models/mint_import.rb" ], paths_for(hits, "debug-log")
  end

  # A capture elsewhere in the file does not excuse the logger: it has to be
  # in the same method.
  def test_flags_a_logger_whose_capture_is_in_another_method
    source = <<~RUBY
      class PlaidAccount::Processor
        def import
          Rails.logger.warn("partial response")
        end

        def report
          DebugLogEntry.capture(category: "sync", message: "x")
        end
      end
    RUBY

    hits = check({}, "app/models/plaid_account/processor.rb" => source)

    assert_equal [ 3 ], lines_for(hits, "debug-log")
  end

  def test_leaves_a_logger_with_a_capture_in_its_method_and_one_outside_provider_paths
    with_capture = <<~RUBY
      class PlaidAccount::Processor
        def import
          Rails.logger.warn("partial response")
          DebugLogEntry.capture(category: "sync", message: "partial")
        end
      end
    RUBY

    hits = check({},
      "app/models/plaid_account/processor.rb" => with_capture,
      "app/models/budget.rb" => method_with("Rails.logger.warn(\"x\")"))

    assert_empty hits
  end

  # --- rule 3: design-system tokens ---

  def test_flags_raw_palette_classes_and_hex_in_views
    hits = check({}, "app/views/foo/show.html.erb" => <<~ERB)
      <div class="bg-gray-100 p-2">a</div>
      <span style="color: #fff">b</span>
      <p class="text-white">c</p>
    ERB

    assert_equal [ 1, 2, 3 ], lines_for(hits, "design-tokens")
  end

  def test_leaves_tokens_interpolation_and_comments_in_components
    hits = check({},
      "app/views/foo/show.html.erb" => %(<div class="bg-container text-primary" id="<%= "row-\#{1}" %>">a</div>\n),
      "app/components/foo_component.rb" => "# was #fff before tokens\nclass FooComponent; end\n")

    assert_empty hits
  end

  # --- rule 4: migration version ---

  def test_flags_a_new_migration_on_an_old_version
    hits = check({ "db/schema.rb" => SCHEMA },
      "db/migrate/20261113000000_add_foo.rb" => "class AddFoo < ActiveRecord::Migration[7.2]\nend\n")

    assert_equal [ "db/migrate/20261113000000_add_foo.rb" ], paths_for(hits, "migration-version")
  end

  def test_leaves_a_current_migration_and_an_old_one_left_unchanged
    base = { "db/schema.rb" => SCHEMA, "db/migrate/20200101000000_old.rb" => "class Old < ActiveRecord::Migration[6.0]\nend\n" }
    hits = check(base,
      "db/migrate/20261113000000_add_foo.rb" => "class AddFoo < ActiveRecord::Migration[8.1]\nend\n",
      "app/models/foo.rb" => "class Foo; end\n")

    assert_empty hits
  end

  # --- comment forms ---

  def test_flags_block_html_erb_tag_and_trailing_comments
    hits = check({},
      "app/javascript/a.js" => "/* per the cubic review */\nconst x = 1 // slice 2.1 tweak\n",
      "app/javascript/b.js" => "/**\n * drop IP4 helper\n */\n",
      "app/views/a/show.html.erb" => "<!-- jaysbeekay/sure#12 -->\n<% x = 1 # addresses the review %>\n",
      "app/models/a.rb" => "foo(\"x\") # per the review\n")

    assert_equal [
      [ "app/javascript/a.js", 1 ], [ "app/javascript/a.js", 2 ], [ "app/javascript/b.js", 2 ],
      [ "app/models/a.rb", 1 ], [ "app/views/a/show.html.erb", 1 ], [ "app/views/a/show.html.erb", 2 ]
    ], hits.select { |h| h.rule == "fork-history" }.map { |h| [ h.path, h.line ] }.sort
  end

  def test_leaves_comment_markers_inside_strings
    hits = check({},
      "app/models/a.rb" => %(url = "https://x.test/#slice 2.1"\nlabel = "per the review"\n),
      "app/javascript/a.js" => %(const u = "https://jaysbeekay/sure"\n))

    assert_empty hits
  end

  # A line whose own text starts with "++" appears as "+++ ..." inside a hunk
  # and must not be read as a new file header.
  def test_an_added_line_starting_with_plus_plus_stays_in_its_file
    hits = check({}, "app/models/a.rb" => "x = 1\n++ y\n# drop IP2 note\n")

    assert_equal [ [ "app/models/a.rb", 3 ] ], hits.map { |h| [ h.path, h.line ] }
  end

  # --- rule 2: paths and method boundaries ---

  def test_flags_provider_adapters_items_and_the_import_model
    hits = check({},
      "app/models/provider/plaid.rb" => method_with("Rails.logger.error(\"x\")"),
      "app/models/plaid_item.rb" => method_with("Rails.logger.warn(\"x\")"),
      "app/models/import.rb" => method_with("Rails.logger.warn(\"x\")"))

    assert_equal [ "app/models/import.rb", "app/models/plaid_item.rb", "app/models/provider/plaid.rb" ], paths_for(hits, "debug-log")
  end

  # Outside any method, a capture in an earlier method does not excuse the
  # logger, and an endless method above it is not mistaken for its method.
  def test_flags_a_logger_outside_any_method
    source = <<~RUBY
      class PlaidItem
        def report
          DebugLogEntry.capture(category: "sync", message: "x")
        end

        def label = "plaid"

        rescue_from(StandardError) { |e| Rails.logger.error(e.message) }
      end
    RUBY

    hits = check({}, "app/models/plaid_item.rb" => source)

    assert_equal [ 8 ], lines_for(hits, "debug-log")
  end

  def test_leaves_a_logger_named_only_in_a_comment
    hits = check({}, "app/models/plaid_item.rb" => method_with("x = 1 # Rails.logger.warn was here"))

    assert_empty hits
  end

  # --- rule 3: what is and is not a colour ---

  def test_flags_hex_only_where_a_colour_is_set
    hits = check({}, "app/views/a/show.html.erb" => <<~ERB)
      <div class="bg-[#1a2b3c]">a</div>
      <svg><path fill="#abc"></path></svg>
      <a href="#bed" data-action="click->form#add">b</a>
      <span>&#160;&#039;</span>
    ERB

    assert_equal [ 1, 2 ], lines_for(hits, "design-tokens")
  end

  def test_leaves_a_hex_in_a_trailing_component_comment
    hits = check({}, "app/components/a_component.rb" => "COLOR = :primary # replaces #fff\n")

    assert_empty hits
  end

  # --- added lines only ---

  def test_reports_only_lines_the_change_adds
    base = { "app/models/foo.rb" => "class Foo\n  # slice 1.2 legacy note\nend\n" }
    hits = check(base, "app/models/foo.rb" => "class Foo\n  # slice 1.2 legacy note\n  # drop IP3 new note\nend\n")

    assert_equal [ 3 ], lines_for(hits, "fork-history")
  end

  def test_command_line_exits_nonzero_with_hits_and_zero_without
    base = commit({ "README.md" => "x\n" }, "base")
    head = commit({ "app/models/foo.rb" => "# jaysbeekay/sure#1\n" }, "head")
    script = File.expand_path("../../bin/preflight_conventions", __dir__)

    out, status = Open3.capture2("ruby", script, base, head, chdir: @dir)
    assert_equal 1, status.exitstatus
    assert_includes out, "app/models/foo.rb:1: [fork-history]"

    _, clean = Open3.capture2("ruby", script, base, base, chdir: @dir)
    assert_equal 0, clean.exitstatus
  end

  # A check that cannot run must not read as convention hits.
  def test_command_line_exits_two_when_it_cannot_run
    base = commit({ "README.md" => "x\n" }, "base")
    script = File.expand_path("../../bin/preflight_conventions", __dir__)

    _, _, broken = Open3.capture3("ruby", script, base, "0" * 40, chdir: @dir)
    assert_equal 2, broken.exitstatus

    _, _, usage = Open3.capture3("ruby", script, base, chdir: @dir)
    assert_equal 2, usage.exitstatus
  end

  private

    def check(base_files, head_files)
      base = commit({ "README.md" => "x\n" }.merge(base_files), "base")
      head = commit(head_files, "head")
      PreflightConventions.check(base, head, dir: @dir)
    end

    def commit(files, message)
      files.each do |path, content|
        full = File.join(@dir, path)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, content)
      end
      git("add", "-A")
      git("commit", "-q", "--allow-empty", "-m", message)
      git("rev-parse", "HEAD").strip
    end

    def git(*args)
      out, err, status = Open3.capture3("git", "-C", @dir, *args)
      raise "git #{args.join(' ')}: #{err}" unless status.success?

      out
    end

    def method_with(line)
      "class Foo\n  def run\n    #{line}\n  end\nend\n"
    end

    def lines_for(hits, rule)
      hits.select { |hit| hit.rule == rule }.map(&:line).sort
    end

    def paths_for(hits, rule)
      hits.select { |hit| hit.rule == rule }.map(&:path).sort
    end
end
