require "minitest/autorun"
require "minitest/mock"
require "tmpdir"
require "fileutils"
require "ostruct"
require_relative "verify_store"

# Offline doubles: this test never loads fastlane or contacts App Store Connect.
module Spaceship
  module ConnectAPI
    class Build
      def self.all(**)
        [OpenStruct.new(app_version: "0.1.0", processing_state: "VALID", uses_non_exempt_encryption: false)]
      end
    end
  end
end

class KinroxStoreVerificationTest < Minitest::Test
  def verify_contact(contact, create_delivery: true, configure: nil, expect_success: false)
    Dir.mktmpdir("kinrox-store-verification-") do |root|
      paths = %w[AppStore/review fastlane]
      paths << "DerivedData/AppStoreDelivery" if create_delivery
      paths.each do |path|
        FileUtils.mkdir_p(File.join(root, path))
      end
      File.write(File.join(root, "AppStore/manifest.json"), JSON.generate(locales: {}))
      File.write(File.join(root, "AppStore/review/notes.txt"), "Review notes")
      if contact
        File.write(File.join(root, "fastlane/.env.review.json"), JSON.generate(contact))
      end
      review = OpenStruct.new(
        contact_first_name: "Test", contact_last_name: "Reviewer", contact_email: "test@example.invalid",
        contact_phone: "+10000000000", demo_account_required: false, notes: "Review notes")
      version = OpenStruct.new(
        release_type: "MANUAL", get_app_store_version_localizations: [],
        fetch_app_store_review_detail: review, version_string: "0.1.0", app_store_state: "TEST")
      app = OpenStruct.new(id: "test", fetch_edit_app_info: OpenStruct.new(get_app_info_localizations: []))
      configure.call(root, app, version) if configure
      # The small fixture also reports missing screenshots; all errors must be aggregated.
      if expect_success
        result = KinroxStoreVerification.run(root, app, version)
        assert_empty(result.fetch(:errors))
        assert_equal(350, result.fetch(:screenshot_count))
      else
        error = assert_raises(RuntimeError) { KinroxStoreVerification.run(root, app, version) }
      end
      report = JSON.parse(File.read(File.join(root, "DerivedData/AppStoreDelivery/store-verification.json")))
      assert_includes(report.fetch("errors"), "Expected 350 screenshots, found 0") unless expect_success
      yield error, report.fetch("errors")
    end
  end

  def valid_contact
    { first_name: "Test", last_name: "Reviewer", email_address: "test@example.invalid", phone_number: "+10000000000" }
  end

  def test_report_directory_is_created_on_a_clean_checkout
    verify_contact(valid_contact, create_delivery: false) { |_, errors| assert_equal(1, errors.size) }
  end

  def test_missing_review_details_are_reported_without_aborting
    configure = ->(_, _, version) { version.fetch_app_store_review_detail = nil }
    verify_contact(valid_contact, configure: configure) do |_, errors|
      assert_includes(errors, "App Review details are missing")
    end
  end

  def test_contact_whitespace_matches_deliver_normalization
    contact = valid_contact.transform_values { |value| " \t#{value}\n" }
    verify_contact(contact) do |_, errors|
      refute(errors.any? { |message| message.include?("contact") })
    end
  end

  def test_unexpected_remote_locales_do_not_abort_the_report
    configure = lambda do |_, app, version|
      extra = OpenStruct.new(locale: "fr-FR", get_app_screenshot_sets: [])
      version.get_app_store_version_localizations = [extra]
      app.fetch_edit_app_info.get_app_info_localizations = [extra]
    end
    verify_contact(valid_contact, configure: configure) do |_, errors|
      assert_includes(errors, "Version locale list differs")
      assert_includes(errors, "App info locale list differs")
    end
  end

  def test_unexpected_screenshot_slot_does_not_abort_the_report
    configure = lambda do |root, _, version|
      File.write(File.join(root, "AppStore/manifest.json"), JSON.generate(locales: { "en-US" => "en" }))
      directory = File.join(root, "AppStore/metadata/en-US")
      FileUtils.mkdir_p(directory)
      %w[description keywords marketing_url promotional_text support_url].each do |field|
        File.write(File.join(directory, "#{field}.txt"), "")
      end
      set = OpenStruct.new(screenshot_display_type: "APP_IPHONE_65", app_screenshots: [])
      version.get_app_store_version_localizations = [OpenStruct.new(locale: "en-US", get_app_screenshot_sets: [set])]
    end
    verify_contact(valid_contact, configure: configure) do |_, errors|
      assert_includes(errors, "en-US: screenshot display types differ")
    end
  end

  def test_complete_kit_passes_before_the_candidate_build_is_attached
    configure = lambda do |root, app, version|
      locales = JSON.parse(File.read(File.join(__dir__, "../AppStore/manifest.json"))).fetch("locales")
      File.write(File.join(root, "AppStore/manifest.json"), JSON.generate(locales: locales))
      copies = locales.keys.map do |locale|
        metadata = File.join(root, "AppStore/metadata", locale)
        staged = File.join(root, "DerivedData/AppStoreDelivery/screenshots", locale)
        FileUtils.mkdir_p([metadata, staged])
        fields = %w[description keywords marketing_url promotional_text support_url name subtitle privacy_policy_url]
        fields.each do |field|
          filename = field == "privacy_policy_url" ? "privacy_url" : field
          File.write(File.join(metadata, "#{filename}.txt"), "Fixture text")
        end
        sets = { "APP_IPHONE_61" => "1206x2622", "APP_IPHONE_67" => "1320x2868" }.map do |type, size|
          shots = 5.times.map do |index|
            name = "#{size}-#{index}.png"
            path = File.join(staged, name)
            File.write(path, "fixture #{locale}/#{name}")
            OpenStruct.new(file_name: name, complete?: true, source_file_checksum: Digest::MD5.file(path).hexdigest,
                           asset_delivery_state: { "state" => "COMPLETE" })
          end
          OpenStruct.new(screenshot_display_type: type, app_screenshots: shots)
        end
        OpenStruct.new(fields.to_h { |field| [field, "Fixture text"] }.merge(locale: locale, get_app_screenshot_sets: sets))
      end
      version.get_app_store_version_localizations = copies
      app.fetch_edit_app_info.get_app_info_localizations = copies
    end
    verify_contact(valid_contact, configure: configure, expect_success: true) do |_, errors|
      assert_empty(errors)
    end
  end

  def test_missing_expected_metadata_file_is_reported
    configure = lambda do |root, _, version|
      File.write(File.join(root, "AppStore/manifest.json"), JSON.generate(locales: { "en-US" => "en" }))
      version.get_app_store_version_localizations = [OpenStruct.new(locale: "en-US", get_app_screenshot_sets: [])]
    end
    verify_contact(valid_contact, configure: configure) do |_, errors|
      assert_includes(errors, "en-US: local description.txt is missing")
    end
  end

  def test_build_lookup_uses_the_verified_version_before_submission_selects_a_build
    configure = ->(_, _, version) { version.version_string = "0.2.0" }
    build = OpenStruct.new(app_version: "0.2.0", processing_state: "VALID", uses_non_exempt_encryption: false)
    lookup = lambda do |**options|
      assert_equal("0.2.0", options.fetch(:version))
      [build]
    end
    Spaceship::ConnectAPI::Build.stub(:all, lookup) do
      verify_contact(valid_contact, configure: configure) do |_, errors|
        refute(errors.any? { |message| message.include?("Build") })
      end
    end
  end

  def test_missing_private_contact_is_reported_without_aborting_verification
    verify_contact(nil) do |error, errors|
      assert_includes(error.message, "fastlane/.env.review.json")
      assert(errors.any? { |message| message.include?("contact") && message.include?("missing") })
    end
  end

  def test_existing_contact_is_still_compared
    contact = { first_name: "Test", last_name: "Reviewer", email_address: "wrong@example.invalid", phone_number: "+10000000000" }
    verify_contact(contact) do |_, errors|
      assert_includes(errors, "App Review contact differs: email_address")
      refute(errors.any? { |message| message.include?("missing") })
    end
  end

  def test_incomplete_contact_reports_every_missing_field_and_writes_report
    verify_contact({ first_name: "Test" }) do |error, errors|
      %w[last_name email_address phone_number].each do |key|
        assert_includes(errors, "App Review contact differs: #{key}")
        assert_includes(error.message, "App Review contact differs: #{key}")
      end
      refute_includes(errors, "App Review contact differs: first_name")
    end
  end

  def test_blank_contact_fields_are_reported
    verify_contact({ first_name: "", last_name: nil, email_address: " ", phone_number: "" }) do |_, errors|
      %w[first_name last_name email_address phone_number].each do |key|
        assert_includes(errors, "App Review contact differs: #{key}")
      end
    end
  end
end
