# frozen_string_literal: true

require 'solidus_core'
require 'solidus_support'

module SolidusSquare
  class Engine < Rails::Engine
    include SolidusSupport::EngineExtensions

    isolate_namespace ::Spree

    engine_name 'solidus_square'

    # use rspec for tests
    config.generators do |g|
      g.test_framework :rspec
    end

    initializer "spree.payment_method.add_square", after: "spree.register.payment_methods" do |app|
      app.config.spree.payment_methods << "Spree::PaymentMethod::Square"
    end
  end
end
