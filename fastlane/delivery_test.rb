require_relative "lane_test_support"

class DeliveryLaneTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("kinrox-delivery-test-")
    @lane = FastfileHarness.new(@root)
    FileUtils.mkdir_p(File.join(@root, "fastlane"))
    FileUtils.mkdir_p(File.join(@root, "AppStore/review"))
    File.write(File.join(@root, "AppStore/review/notes.txt"), "Review notes")
    FileUtils.mkdir_p(File.join(@root, "Config"))
    File.write(File.join(@root, "Config/RemoteiOS.xcconfig"), "MARKETING_VERSION = 0.1.0\nCURRENT_PROJECT_VERSION = 1\n")
    File.write(File.join(@root, "AppStore/manifest.json"), JSON.generate(locales: { "en-US" => "en" }))
    @target = File.join(@root, "DerivedData/AppStoreDelivery/screenshots/en-US")
    %w[1206x2622 1320x2868].each do |size|
      source = File.join(@root, "AppStore/screenshots/export-20261111-v2/en-US", size)
      FileUtils.mkdir_p(source)
      8.times { |index| File.write(File.join(source, "#{index}.png"), "fixture #{size}/#{index}") }
    end
  end

  def teardown
    FileUtils.remove_entry(@root) # Only the fixture directory created by this test.
  end

  def write_contact(**overrides)
    contact = { first_name: "Test", last_name: "Reviewer", email_address: "test@example.invalid", phone_number: "+10000000000" }
    File.write(File.join(@root, "fastlane/.env.review.json"), JSON.generate(contact.merge(overrides)))
  end

  def assert_contact_rejected(lane)
    error = assert_raises(RuntimeError) { @lane.run(lane) }
    assert_includes(error.message, "App Review contact is incomplete")
    assert_empty(@lane.events)
    refute(File.exist?(@target))
  end

  def test_metadata_rejects_missing_contact_before_staging_or_upload
    assert_contact_rejected(:metadata)
  end

  def test_metadata_rejects_incomplete_contact_before_upload
    write_contact(phone_number: nil)
    assert_contact_rejected(:metadata)
  end

  def test_metadata_rejects_whitespace_contact_before_upload
    write_contact(first_name: " \t\n")
    assert_contact_rejected(:metadata)
  end

  def test_submit_rejects_whitespace_contact_before_upload
    write_contact(first_name: " \t\n")
    assert_contact_rejected(:submit)
  end

  def test_metadata_sends_valid_contact_and_complete_screenshots
    write_contact
    @lane.run(:metadata)
    assert_equal("Test", @lane.upload_options.fetch(:app_review_information).fetch(:first_name))
    refute(@lane.upload_options[:skip_metadata])
    assert_equal(true, @lane.upload_options.fetch(:overwrite_screenshots))
    assert_equal(16, Dir.children(@target).size)
    assert(Dir.children(@target).all? { |name| File.symlink?(File.join(@target, name)) })
    @lane.run(:stage_screenshots) # Repeated staging must preserve the same links.
    assert_equal(16, Dir.children(@target).size)
  end

  def test_broken_staging_link_stops_upload_with_a_diagnostic_and_is_preserved
    FileUtils.mkdir_p(@target)
    destination = File.join(@target, "1206x2622-0.png")
    File.symlink("missing.png", destination)
    error = assert_raises(RuntimeError) { @lane.run(:screenshots) }
    assert_includes(error.message, "staged screenshot")
    assert_equal("missing.png", File.readlink(destination))
    assert_nil(@lane.upload_options)
  end

  def test_extra_staged_image_stops_upload_and_is_preserved
    @lane.run(:stage_screenshots)
    extra = File.join(@target, "old.png")
    File.write(extra, "preserved")
    error = assert_raises(RuntimeError) { @lane.run(:screenshots) }
    assert_includes(error.message, "Unexpected staged")
    assert_equal("preserved", File.read(extra))
    assert_nil(@lane.upload_options)
  end

  def test_extra_staged_locale_stops_upload_and_is_preserved
    extra = File.join(File.dirname(@target), "fr-FR")
    FileUtils.mkdir_p(extra)
    error = assert_raises(RuntimeError) { @lane.run(:screenshots) }
    assert_includes(error.message, "Unexpected staged")
    assert(File.directory?(extra))
    assert_nil(@lane.upload_options)
  end

  def test_verify_stages_screenshots_before_reading_store_state
    app = OpenStruct.new(get_app_store_versions: [OpenStruct.new(version_string: "0.1.0")])
    @lane.define_singleton_method(:kinrox_app) { app }
    read_back = lambda do |root, *|
      assert_equal(16, Dir.glob(File.join(root, "DerivedData/AppStoreDelivery/screenshots/en-US/*.png")).size)
      {}
    end
    KinroxStoreVerification.stub(:run, read_back) { @lane.run(:verify) }
  end
end
