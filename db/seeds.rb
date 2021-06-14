# frozen_string_literal: true

application_id = ENV['SQUARE_SEEDS_APPLICATION_ID']
access_token = ENV['SQUARE_SEEDS_ACCESS_TOKEN']
location_id = ENV['SQUARE_SEEDS_LOCATION_ID']

puts "Loading seed: solidus_square/square_payment_method"

if application_id.blank? || access_token.blank? || location_id.blank?
  puts "Failure: You have to set SQUARE_SEEDS_APPLICATION_ID, SQUARE_SEEDS_ACCESS_TOKEN, and SQUARE_SEEDS_LOCATION_ID environment variables."
else
  square_payment_method = Spree::PaymentMethod::Square.new do |payment_method|
    payment_method.name = 'Square'
    payment_method.preferred_test_mode = true
    payment_method.preferred_application_id = application_id
    payment_method.preferred_access_token = access_token
    payment_method.preferred_location_id = location_id
  end

  if square_payment_method.save
    puts "Square Payment Method correctly created."
  else
    puts "There was some problems with creating Square Payment Method:"
    square_payment_method.errors.full_messages.each do |error|
      puts error
    end
  end
end
