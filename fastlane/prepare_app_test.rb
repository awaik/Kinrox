require_relative "lane_test_support"

module Spaceship
  module ConnectAPI
    class << self
      attr_accessor :token
      def login(*) = raise("Unexpected Apple ID login")
    end

    class BundleId
      def self.find(*) = OpenStruct.new(identifier: "app.kinrox.remote", id: "fixture-bundle")
    end

    class App
      def self.find(*) = nil
      def self.create(**) = raise("Unexpected app creation")
    end
  end
end

class PrepareAppLaneTest < Minitest::Test
  def with_creation(login_failure: false, create_failure: false)
    lane = FastfileHarness.new
    lane.define_singleton_method(:kinrox_api_key) do
      events << :api_key
      Spaceship::ConnectAPI.token = :fixture_token
    end
    created = false
    find_app = lambda do |*|
      if created
        assert_equal(:fixture_token, Spaceship::ConnectAPI.token)
        OpenStruct.new(id: "fixture-app")
      end
    end
    login = lambda do |*|
      assert_nil(Spaceship::ConnectAPI.token)
      raise "Login failed" if login_failure
    end
    create = lambda do |**|
      assert_nil(Spaceship::ConnectAPI.token)
      raise "Creation failed" if create_failure
      created = true
    end
    ENV.stub(:fetch, "fixture-user") do
      Spaceship::ConnectAPI.stub(:login, login) do
        Spaceship::ConnectAPI::App.stub(:find, find_app) do
          Spaceship::ConnectAPI::App.stub(:create, create) { yield lane }
        end
      end
    end
  ensure
    Spaceship::ConnectAPI.token = nil
  end

  def test_api_authentication_is_restored_before_reading_the_created_app
    with_creation do |lane|
      lane.run(:prepare_app)
      assert_equal(:fixture_token, Spaceship::ConnectAPI.token)
    end
  end

  def test_api_authentication_is_restored_when_login_fails
    with_creation(login_failure: true) do |lane|
      error = assert_raises(RuntimeError) { lane.run(:prepare_app) }
      assert_equal("Login failed", error.message)
      assert_equal(:fixture_token, Spaceship::ConnectAPI.token)
    end
  end

  def test_api_authentication_is_restored_when_creation_fails
    with_creation(create_failure: true) do |lane|
      error = assert_raises(RuntimeError) { lane.run(:prepare_app) }
      assert_equal("Creation failed", error.message)
      assert_equal(:fixture_token, Spaceship::ConnectAPI.token)
    end
  end
end
