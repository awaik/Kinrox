require "digest"
require "fileutils"
require "json"

# Read back Apple's stored metadata and compare it with the reviewed local kit.
module KinroxStoreVerification
  def self.run(root, app, version, build_number = "1")
    manifest = JSON.parse(File.read(File.join(root, "AppStore/manifest.json")))
    expected_locales = manifest.fetch("locales").keys.sort
    localizations = version.get_app_store_version_localizations
    info_localizations = app.fetch_edit_app_info.get_app_info_localizations
    errors = []
    errors << "Release type must remain MANUAL" unless version.release_type == "MANUAL"
    errors << "Version locale list differs" unless localizations.map(&:locale).sort == expected_locales
    errors << "App info locale list differs" unless info_localizations.map(&:locale).sort == expected_locales

    localizations.each do |locale|
      next unless expected_locales.include?(locale.locale)
      %w[description keywords marketing_url promotional_text support_url].each do |field|
        path = File.join(root, "AppStore/metadata", locale.locale, "#{field}.txt")
        unless File.file?(path)
          errors << "#{locale.locale}: local #{field}.txt is missing"
          next
        end
        expected = File.read(path).strip
        errors << "#{locale.locale}: #{field} differs" unless locale.public_send(field).to_s.strip == expected
      end
    end
    info_localizations.each do |locale|
      next unless expected_locales.include?(locale.locale)
      %w[name subtitle privacy_policy_url].each do |field|
        filename = field == "privacy_policy_url" ? "privacy_url" : field
        path = File.join(root, "AppStore/metadata", locale.locale, "#{filename}.txt")
        unless File.file?(path)
          errors << "#{locale.locale}: local #{filename}.txt is missing"
          next
        end
        expected = File.read(path).strip
        errors << "#{locale.locale}: #{field} differs" unless locale.public_send(field).to_s.strip == expected
      end
    end

    screenshot_count = 0
    screenshot_report = {}
    localizations.each do |locale|
      sets = locale.get_app_screenshot_sets
      types = { "APP_IPHONE_61" => "1206x2622", "APP_IPHONE_67" => "1320x2868" }
      errors << "#{locale.locale}: screenshot display types differ" unless sets.map(&:screenshot_display_type).sort == types.keys.sort
      screenshot_report[locale.locale] = sets.to_h do |set|
        shots = set.app_screenshots || []
        screenshot_count += shots.count
        report = shots.map { |s| { name: s.file_name, state: s.asset_delivery_state["state"] } }
        size = types[set.screenshot_display_type]
        next [set.screenshot_display_type, report] unless size
        expected_paths = Dir.glob(File.join(root, "DerivedData/AppStoreDelivery/screenshots", locale.locale, "#{size}-*.png")).sort
        errors << "#{locale.locale}/#{size}: screenshot count/order differs" unless shots.map(&:file_name) == expected_paths.map { |p| File.basename(p) }
        shots.each do |shot|
          path = File.join(root, "DerivedData/AppStoreDelivery/screenshots", locale.locale, shot.file_name)
          errors << "#{locale.locale}/#{shot.file_name}: incomplete" unless shot.complete?
          errors << "#{locale.locale}/#{shot.file_name}: checksum differs" unless File.exist?(path) && Digest::MD5.file(path).hexdigest == shot.source_file_checksum
        end
        [set.screenshot_display_type, report]
      end
    end
    # Every one of Apple's 35 store localizations carries the manifest's per-locale set.
    expected_shots = manifest.fetch("screenshots_per_locale", 10) * 35
    errors << "Expected #{expected_shots} screenshots, found #{screenshot_count}" unless screenshot_count == expected_shots
    review = version.fetch_app_store_review_detail
    errors << "App Review details are missing" unless review
    contact_path = File.join(root, "fastlane/.env.review.json")
    if File.exist?(contact_path)
      contact = JSON.parse(File.read(contact_path))
      { "first_name" => :contact_first_name, "last_name" => :contact_last_name,
        "email_address" => :contact_email, "phone_number" => :contact_phone }.each do |key, attr|
        expected = contact[key].to_s.strip
        errors << "App Review contact differs: #{key}" unless !expected.empty? && review&.public_send(attr).to_s.strip == expected
      end
    else
      errors << "App Review contact file is missing: fastlane/.env.review.json"
    end
    errors << "Unexpected required demo account" if review&.demo_account_required
    errors << "Review notes differ" unless review&.notes.to_s.strip == File.read(File.join(root, "AppStore/review/notes.txt")).strip
    # The submit lane selects this candidate build; it need not be attached yet.
    builds = Spaceship::ConnectAPI::Build.all(app_id: app.id, version: version.version_string, build_number: build_number, platform: "IOS")
    build = builds.find { |b| b.app_version == version.version_string }
    errors << "Build #{version.version_string} (#{build_number}) is not VALID" unless build&.processing_state == "VALID"
    errors << "Build export-compliance declaration differs" unless build&.uses_non_exempt_encryption == false
    result = { app_id: app.id, version: version.version_string, state: version.app_store_state,
               locales: expected_locales.count, screenshot_count: screenshot_count,
               screenshots: screenshot_report, build_state: build&.processing_state, errors: errors }
    path = File.join(root, "DerivedData/AppStoreDelivery/store-verification.json")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.pretty_generate(result))
    raise errors.join("\n") unless errors.empty?
    result.reject { |key, _| key == :screenshots }
  end
end
