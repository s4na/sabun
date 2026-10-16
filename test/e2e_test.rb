require 'minitest/autorun'
require 'stringio'
require_relative '../lib/sabun/e2e'

class E2ETest < Minitest::Test
  def setup
    @old = %w[SABUN_E2E_TOKEN SABUN_E2E_JOBS_SYNC].to_h { |k| [k, ENV[k]] }
    ENV['SABUN_E2E_TOKEN'] = 'test-secret'
    ENV['SABUN_E2E_JOBS_SYNC'] = '1'
    @middleware = Sabun::E2E::Middleware.new(->(_env) { [200, {}, ['OK']] })
  end

  def teardown
    @old.each { |k, v| ENV[k] = v }
  end

  def control(action, id: 'test-1', token: 'test-secret')
    @middleware.call('PATH_INFO' => '/__sabun__/control', 'REQUEST_METHOD' => 'POST',
      'HTTP_AUTHORIZATION' => "Bearer #{token}", 'rack.input' => StringIO.new(JSON.generate(action: action, id: id)))
  end

  def test_token_required
    assert_equal 403, control('start', token: 'wrong')[0]
  end

  def test_sequential_sessions
    Sabun::Recorder.start!
    assert_equal 200, control('start')[0]
    assert_equal 409, control('start')[0]
    assert_equal 409, control('finish', id: 'wrong')[0]
    status, _, body = control('finish')
    assert_equal 200, status
    assert_kind_of Array, JSON.parse(body.join)['dependencies']
  end

  def test_requests_in_flight_prevent_finishing
    Sabun::Recorder.start!
    control('start')
    status, _, body = @middleware.call('PATH_INFO' => '/health')
    assert_equal 200, status
    assert_equal 409, control('finish')[0]
    body.each { |_| }
    assert_equal 200, control('finish')[0]
  end
end
