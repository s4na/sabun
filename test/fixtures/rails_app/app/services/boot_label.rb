class BootLabel
  def self.text
    ENV.fetch('SABUN_FIXTURE_FLAG', 'ready')
  end
end
