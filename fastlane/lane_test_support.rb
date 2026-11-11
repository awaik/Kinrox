require "minitest/autorun"
require "minitest/mock"
require "tmpdir"
require "ostruct"

# Execute lanes with offline action doubles; never load fastlane or credentials.
module SharedValues
  SIGH_NAME = :profile_name
end

module UI
  def self.user_error!(message) = raise(RuntimeError, message)
  def self.message(*) = nil
  def self.success(*) = nil
end

class FastfileHarness
  attr_reader :events, :build_options, :upload_options
  attr_accessor :generation_failure

  def initialize(root = nil)
    @events = []
    path = File.join(__dir__, "Fastfile")
    instance_eval(File.read(path), path)
    define_singleton_method(:kinrox_root) { root } if root
    define_singleton_method(:ensure_bundle_ids!) { @events << :bundle_ids }
    define_singleton_method(:kinrox_api_key) do
      @events << :api_key
      :fixture_key
    end
  end

  def default_platform(*) = nil
  def desc(*) = nil
  def platform(*) = yield
  def lane(name, &block) = define_singleton_method(name, &block)
  def run(name = :build) = public_send(name)

  def sh(command)
    @events << [:generate, command]
    raise "Generation failed" if generation_failure
  end

  def get_provisioning_profile(**)
    @events << :profile
    "fixture.mobileprovision"
  end

  def lane_context = { SharedValues::SIGH_NAME => "Fixture Profile" }

  def build_app(**options)
    @build_options = options
    @events << [:archive, options.fetch(:scheme)]
  end

  def upload_to_app_store(**options)
    @upload_options = options
    @events << :upload
  end
end
