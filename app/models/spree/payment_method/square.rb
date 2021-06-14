# frozen_string_literal: true
require 'active_merchant/billing/response'

module Spree
  class PaymentMethod
    class Square < Spree::PaymentMethod::CreditCard
      SUPPORTED_SQUARE_API_VERSION = '2021-05-13'.freeze

      preference :application_id, :string
      preference :access_token, :string
      preference :location_id, :string

      CARD_TYPE_MAPPING = {
        'AMERICAN_EXPRESS' => 'american_express',
        'DISCOVER_DINERS' => 'diners_club',
        'VISA' => 'visa',
        'MASTERCARD' => 'master',
        'DISCOVER' => 'discover',
        'JCB' => 'jcb'
      }.freeze

      CVV_CODE_MAPPING = {
        'CVV_ACCEPTED' => 'M',
        'CVV_REJECTED' => 'N',
        'CVV_NOT_CHECKED' => 'P'
      }.freeze

      AVS_CODE_MAPPING = {
        # TODO: unsure if Square does street or only postal AVS matches
        'AVS_ACCEPTED' => 'P', # 'P' => 'Postal code matches, but street address not verified.',
        'AVS_REJECTED' => 'N', # 'N' => 'Street address and postal code do not match. For American Express: Card member\'s name, street address and postal code do not match.',
        'AVS_NOT_CHECKED' => 'I' # 'I' => 'Address not verified.',
      }.freeze

      def test?
        !!preferred_test_mode
      end

      def square
        @square ||= Square::Client.new({
          square_version: SUPPORTED_SQUARE_API_VERSION,
          access_token: preferred_access_token,
          environment: test? ? 'sandbox' : 'production',
        })
      end

      def javascript_resource_url
        test? ? "https://sandbox.web.squarecdn.com/v1/square.js" : "https://web.squarecdn.com/v1/square.js"
      end

      def partial_name
        'square'
      end

      def gateway_class
        self.class
      end

      def payment_profiles_supported?
        true
      end

      def reusable_sources_by_order(order)
        source_ids = order.payments.where(payment_method_id: id).pluck(:source_id).uniq
        payment_source_class.where(id: source_ids).select(&:reusable?)
      end

      def reusable_sources(order)
        if order.completed?
          reusable_sources_by_order(order)
        elsif order.user_id
          order.user.wallet.wallet_payment_sources.map(&:payment_source).select(&:reusable?)
        else
          []
        end
      end

      def purchase(money, creditcard, transaction_options)
        with_active_merchant_response do
          square.payments.create_payment(body: body_for_purchase_or_auth(money, creditcard, transaction_options))
        end
      end

      def authorize(money, creditcard, transaction_options)
        with_active_merchant_response do
          square.payments.create_payment(body: body_for_purchase_or_auth(money, creditcard, transaction_options).merge({ autocomplete: false }))
        end
      end

      def capture(money, response_code, transaction_options)
        with_active_merchant_response do
          square.payments.complete_payment(payment_id: response_code)
        end
      end

      def credit(money, _creditcard, response_code, transaction_options)
        refund_body = {
          payment_id: response_code,
          reason: payment_intents_refund_reason
        }
        add_idempotency_key(refund_body)
        add_amount(refund_body, money, transaction_options)
        add_application_fee(refund_body, transaction_options[:application_fee], transaction_options)
        with_active_merchant_response { square.refunds.refund_payment(body: refund_body) }
      end

      def void(response_code, _creditcard, _transaction_options)
        with_active_merchant_response { square.payments.cancel_payment(payment_id: response_code) }
      end

      def payment_intents_refund_reason
        Spree::RefundReason.where(name: Spree::Payment::Cancellation::DEFAULT_REASON).first_or_create
      end

      def try_void(payment)
        void(payment.response_code, nil, nil)
      end

      def cancel(response_code)
        void(response_code, nil, nil)
      end

      def create_profile(payment)
        return unless payment.source.gateway_customer_profile_id.nil?

        options = {
          email: payment.order.email,
          login: preferred_secret_key,
        }.merge! address_for(payment)

        source = update_source!(payment.source)
        if source.number.blank? && source.gateway_payment_profile_id.present?
          if v3_intents?
            creditcard = ActiveMerchant::Billing::StripeGateway::StripePaymentToken.new('id' => source.gateway_payment_profile_id)
          else
            creditcard = source.gateway_payment_profile_id
          end
        else
          creditcard = source
        end

        response = gateway.store(creditcard, options)
        if response.success?
          if v3_intents?
            payment.source.update!(
              cc_type: payment.source.cc_type,
              gateway_customer_profile_id: response.params['customer'],
              gateway_payment_profile_id: response.params['id']
            )
          else
            payment.source.update!(
              cc_type: payment.source.cc_type,
              gateway_customer_profile_id: response.params['id'],
              gateway_payment_profile_id: response.params['default_source'] || response.params['default_card']
            )
          end
        else
          payment.send(:gateway_error, response.message)
        end
      end

    private

      def add_idempotency_key(post, options)
        post[:idempotency_key] = options[:idempotency_key] unless options.nil? || options[:idempotency_key].nil? || options[:idempotency_key].blank?
      end

      def add_amount(body, money, options)
        currency = options[:currency] || currency(money)
        body[:amount_money] = {
          amount: localized_amount(money, currency).to_i,
          currency: currency.upcase
        }
      end

      def add_application_fee(body, money, options)
        currency = options[:currency] || currency(money)
        if options[:application_fee]
          body[:app_fee_money] = {
            amount: localized_amount(money, currency).to_i,
            currency: currency.upcase
          }
        end
      end

      def add_customer(body, options)
        first_name = options[:billing_address][:name].split(' ')[0]
        last_name = options[:billing_address][:name].split(' ')[1] if options[:billing_address][:name].split(' ').length > 1

        body[:email_address] = options[:email] || nil
        body[:phone_number] = options[:billing_address] ? options[:billing_address][:phone] : nil
        body[:given_name] = first_name
        body[:family_name] = last_name

        body[:address] = {}
        body[:address][:address_line_1] = options[:billing_address] ? options[:billing_address][:address1] : nil
        body[:address][:address_line_2] = options[:billing_address] ? options[:billing_address][:address2] : nil
        body[:address][:locality] = options[:billing_address] ? options[:billing_address][:city] : nil
        body[:address][:administrative_district_level_1] = options[:billing_address] ? options[:billing_address][:state] : nil
        body[:address][:administrative_district_level_2] = options[:billing_address] ? options[:billing_address][:country] : nil
        body[:address][:country] = options[:billing_address] ? options[:billing_address][:country] : nil
        body[:address][:postal_code] = options[:billing_address] ? options[:billing_address][:zip] : nil
      end

      def body_for_purchase_or_auth(money, creditcard, transaction_options)
        body = {}
        body[:reference_id] = transaction_options[:order_id]
        body[:statement_description_identifier] = transaction_options[:statement_description_identifier] if transaction_options[:statement_description_identifier]

        if customer = creditcard.gateway_customer_profile_id
          body[:customer_id] = customer
        end
        if token_or_card_id = creditcard.gateway_payment_profile_id
          body[:source_id] = token_or_card_id
        end

        add_idempotency_key(body, transaction_options)
        add_amount(body, money, transaction_options)
        add_application_fee(body, transaction_options[:application_fee], transaction_options)

        body
      end

      def address_for(payment)
        {}.tap do |options|
          if address = payment.order.bill_address
            options[:address] = {
              address1: address.address1,
              address2: address.address2,
              city: address.city,
              zip: address.zipcode
            }

            if country = address.country
              options[:address][:country] = country.name
            end

            if state = address.state
              options[:address].merge!(state: state.name)
            end
          end
        end
      end

      def update_source!(source)
        source.cc_type = CARD_TYPE_MAPPING[source.cc_type] if CARD_TYPE_MAPPING.include?(source.cc_type)
        source
      end

      def card_from_response(response)
        return {} unless response && response['payment']

        response['payment']['card_details'] || {}
      end

      def message_from(success, response)
        success ? 'Transaction approved' : response.errors[0]['detail']
      end

      def error_code_from(errors)
        return nil unless errors

        errors[0]['code']
      end

      def authorization_from(success, response_data)
        return nil unless success

        response.values.first.try(:key, 'id')
      end

      def with_active_merchant_response(&block)
        response = yield
        success = response.success?

        card = card_from_response(response.data)

        avs_result = AVS_CODE_MAPPING[card['avs_status']]
        cvv_result = CVV_CODE_MAPPING[card['cvv_status']]

        ActiveMerchant::Billing::Response.new(
          success,
          message_from(success, response),
          response.data,
          {
            authorization: authorization_from(success, response.data),
            avs_result: success ? avs_result : nil,
            cvv_result: success ? cvv_result : nil,
            error_code: success ? nil : error_code_from(response.errors),
            test: test?,
          }
        )
      end
    end
  end
end
