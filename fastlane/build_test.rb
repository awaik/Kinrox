require_relative "lane_test_support"

class BuildLaneTest < Minitest::Test
  def setup
    @original_path = ENV.fetch("PATH")
    @lane = FastfileHarness.new
  end

  def teardown
    ENV["PATH"] = @original_path
  end

  def test_build_generates_projects_before_provisioning_and_archiving
    @lane.run
    assert_equal([[:generate, File.expand_path("../Scripts/generate.sh", __dir__)],
                  :api_key, :bundle_ids, :profile, :profile, [:archive, "RemoteiOS"]], @lane.events)
    profiles = @lane.build_options.fetch(:export_options).fetch(:provisioningProfiles)
    assert_equal(%w[app.kinrox.remote app.kinrox.remote.lockscreen], profiles.keys)
  end

  def test_generation_failure_stops_before_provisioning_and_archiving
    @lane.generation_failure = true
    error = assert_raises(RuntimeError) { @lane.run }
    assert_equal("Generation failed", error.message)
    assert_equal([[:generate, File.expand_path("../Scripts/generate.sh", __dir__)]], @lane.events)
  end

  def test_export_generates_projects_before_inspecting_the_workspace
    @lane.run(:export)
    assert_equal([[:generate, File.expand_path("../Scripts/generate.sh", __dir__)],
                  [:archive, "RemoteiOS"]], @lane.events)
    assert_equal(true, @lane.build_options.fetch(:skip_build_archive))
    assert_equal("app-store", @lane.build_options.fetch(:export_method))
    options = @lane.build_options.fetch(:export_options)
    assert_equal(@lane.build_options[:export_method], options.fetch(:method, @lane.build_options[:export_method]))
    assert_equal(false, options.fetch(:manageAppVersionAndBuildNumber))
  end

  def test_export_stops_when_project_generation_fails
    @lane.generation_failure = true
    assert_raises(RuntimeError) { @lane.run(:export) }
    assert_nil(@lane.build_options)
  end
end
