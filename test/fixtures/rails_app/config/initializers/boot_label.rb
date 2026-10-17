# frozen_string_literal: true
require Rails.root.join('app/services/boot_label')
Rails.configuration.x.boot_label = BootLabel.text
