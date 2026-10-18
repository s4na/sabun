require 'minitest/autorun'
require 'tmpdir'
require 'json'
require_relative '../lib/sabun/cli'

class CLIE2EAggregateTest < Minitest::Test
  IDENTITY = { 'commit' => 'abc123', 'fingerprint' => 'env456' }.freeze

  def setup
    @directory = Dir.mktmpdir('sabun-e2e-aggregate-')
    @output = File.join(@directory, 'record')
    FileUtils.mkdir_p("#{@output}.d")
    File.write("#{@output}.manifest.json", JSON.generate('complete' => true, 'tests' => %w[test-a test-b]))
    write_entry('a.json', 'unit' => 'checkout.spec.js::chromium', 'test_id' => 'test-a',
                          'complete' => true, 'dependencies' => ['app/checkout.rb'],
                          'identity' => IDENTITY, 'worker_id' => 100)
    write_entry('b.json', 'unit' => 'shipping.spec.js::chromium', 'test_id' => 'test-b',
                          'complete' => true, 'dependencies' => ['app/shipping.rb'],
                          'identity' => IDENTITY, 'worker_id' => 200)
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_final_worker_dependencies_are_shared_by_every_e2e_unit
    write_entry('worker-100.json', 'kind' => 'worker_final', 'worker_id' => 100,
                                    'complete' => true, 'dependencies' => ['app/cleanup.rb'], 'identity' => IDENTITY)
    write_entry('worker-200.json', 'kind' => 'worker_final', 'worker_id' => 200,
                                    'complete' => true, 'dependencies' => ['app/after_all.rb'], 'identity' => IDENTITY)

    result = Sabun::CLI.new.send(:aggregate_e2e, @output, identity: IDENTITY)

    assert_equal true, result['complete']
    result.fetch('units').each_value do |unit|
      assert_includes unit.fetch('dependencies'), 'app/cleanup.rb'
      assert_includes unit.fetch('dependencies'), 'app/after_all.rb'
    end
  end

  def test_missing_final_worker_snapshot_cannot_promote_the_record
    write_entry('worker-100.json', 'kind' => 'worker_final', 'worker_id' => 100,
                                    'complete' => true, 'dependencies' => [], 'identity' => IDENTITY)

    error = assert_raises(Sabun::Error) { Sabun::CLI.new.send(:aggregate_e2e, @output, identity: IDENTITY) }

    assert_equal 'missing E2E worker final snapshot', error.message
  end

  private

  def write_entry(name, data)
    File.write(File.join("#{@output}.d", name), JSON.generate(data))
  end
end
