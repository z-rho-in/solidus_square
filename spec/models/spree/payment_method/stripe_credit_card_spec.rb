# frozen_string_literal: true

require 'spec_helper'

describe Spree::PaymentMethod::StripeCreditCard do
  let(:secret_key) { 'key' }
  let(:email) { 'customer@example.com' }
  let(:source) { Spree::CreditCard.new }

  let(:bill_address) { nil }

  let(:order) {
    double('Spree::Order',
      email: email,
      bill_address: bill_address,
      currency: 'USD',
      number: 'NUMBER',
      total: 10.99
    )
  }

  let(:payment) {
    double('Spree::Payment',
      source: source,
      order: order,
      amount: order.total
    )
  }

  let(:gateway) do
    double('gateway').tap do |p|
      allow(p).to receive(:purchase)
      allow(p).to receive(:authorize)
      allow(p).to receive(:capture)
    end
  end

  before do
    subject.preferences = { secret_key: secret_key }
    allow(subject).to receive(:options_for_purchase_or_auth).and_return(['money', 'cc', 'opts'])
    allow(subject).to receive(:gateway).and_return gateway
  end

  it 'can enable Stripe.js V3 Elements via preference setting' do
    expect do
      subject.preferred_v3_elements = true
    end.to change { subject.v3_elements? }.from(false).to true
  end

  describe '#stripe_config' do
    context 'when payment request feature is disabled' do
      before { subject.preferences = { publishable_key: 'stripe_key' } }

      it 'includes the basic configuration' do
        config = subject.stripe_config(order)
        expect(config.keys).to eq %i[id publishable_key]
        expect(config[:publishable_key]).to include('stripe_key')
      end
    end

    context 'when the payment request feature is enabled' do
      before do
        subject.preferences = {
          publishable_key: 'stripe_key',
          stripe_country: 'US',
          v3_intents: true
        }
      end

      it 'includes the payment request configuration as well' do
        config = subject.stripe_config(order)
        expect(config.keys).to eq %i[id publishable_key payment_request]
        expect(config[:payment_request][:currency]).to eq 'usd'
        expect(config[:payment_request][:amount]).to be 1099
        expect(config[:payment_request][:label]).to include 'NUMBER'
      end
    end
  end

  describe '#create_profile' do
    before do
      allow(payment.source).to receive(:update_attributes!)
    end

    context 'with an order that has a bill address' do
      let(:bill_address) {
        double('Spree::Address',
          address1: '123 Happy Road',
          address2: 'Apt 303',
          city: 'Suzarac',
          zipcode: '95671',
          state: double('Spree::State', name: 'Oregon'),
          country: double('Spree::Country', name: 'United States'))
      }

      it 'stores the bill address with the gateway' do
        expect(subject.gateway).to receive(:store).with(payment.source, {
          email: email,
          login: secret_key,

          address: {
            address1: '123 Happy Road',
            address2: 'Apt 303',
            city: 'Suzarac',
            zip: '95671',
            state: 'Oregon',
            country: 'United States'
          }
        }).and_return double.as_null_object

        subject.create_profile payment
      end
    end

    context 'with an order that does not have a bill address' do
      it 'does not store a bill address with the gateway' do
        expect(subject.gateway).to receive(:store).with(payment.source, {
          email: email,
          login: secret_key,
        }).and_return double.as_null_object

        subject.create_profile payment
      end

      # Regression test for #141
      context "correcting the card type" do
        before do
          # We don't care about this method for these tests
          allow(subject.gateway).to receive(:store).and_return(double.as_null_object)
        end

        it "converts 'American Express' to 'american_express'" do
          payment.source.cc_type = 'American Express'
          subject.create_profile(payment)
          expect(payment.source.cc_type).to eq('american_express')
        end

        it "converts 'Diners Club' to 'diners_club'" do
          payment.source.cc_type = 'Diners Club'
          subject.create_profile(payment)
          expect(payment.source.cc_type).to eq('diners_club')
        end

        it "converts 'Visa' to 'visa'" do
          payment.source.cc_type = 'Visa'
          subject.create_profile(payment)
          expect(payment.source.cc_type).to eq('visa')
        end
      end
    end

    context 'with a card represents payment_profile' do
      let(:source) { Spree::CreditCard.new(gateway_payment_profile_id: 'tok_profileid') }
      let(:bill_address) { nil }

      it 'stores the profile_id as a card' do
        expect(subject.gateway).to receive(:store).with(source.gateway_payment_profile_id, anything).and_return double.as_null_object

        subject.create_profile payment
      end
    end
  end

  context 'purchasing' do
    after do
      subject.purchase(19.99, 'credit card', {})
    end

    it 'send the payment to the gateway' do
      expect(gateway).to receive(:purchase).with('money', 'cc', 'opts')
    end
  end

  context 'authorizing' do
    after do
      subject.authorize(19.99, 'credit card', {})
    end

    it 'send the authorization to the gateway' do
      expect(gateway).to receive(:authorize).with('money', 'cc', 'opts')
    end
  end

  context 'capturing' do
    after do
      subject.capture(1234, 'response_code', {})
    end

    it 'convert the amount to cents' do
      expect(gateway).to receive(:capture).with(1234, anything, anything)
    end

    it 'use the response code as the authorization' do
      expect(gateway).to receive(:capture).with(anything, 'response_code', anything)
    end
  end

  context 'capture with payment class' do
    let(:payment_method) do
      payment_method = described_class.new(active: true)
      payment_method.set_preference :secret_key, secret_key
      allow(payment_method).to receive(:options_for_purchase_or_auth).and_return(['money', 'cc', 'opts'])
      allow(payment_method).to receive(:gateway).and_return gateway
      allow(payment_method).to receive_messages source_required: true
      payment_method
    end

    let!(:store) { FactoryBot.create(:store) }
    let(:order) { Spree::Order.create! }

    let(:card) do
      FactoryBot.create(
        :credit_card,
        gateway_customer_profile_id: 'cus_abcde',
        imported: false
      )
    end

    let(:payment) do
      payment = Spree::Payment.new
      payment.source = card
      payment.order = order
      payment.payment_method = payment_method
      payment.amount = 98.55
      payment.state = 'pending'
      payment.response_code = '12345'
      payment
    end

    let!(:success_response) do
      double('success_response', success?: true,
                               authorization: '123',
                               avs_result: { 'code' => 'avs-code' },
                               cvv_result: { 'code' => 'cvv-code', 'message' => "CVV Result" })
    end

    after do
      payment.capture!
    end

    it 'gets correct amount' do
      expect(gateway).to receive(:capture).with(9855, '12345', anything).and_return(success_response)
    end
  end

  describe '#try_void' do
    let(:payment) { create :payment, amount: order.total }

    shared_examples 'voids the payment transaction' do
      it 'voids the payment transaction' do
        expect(gateway).to receive(:void)

        subject.try_void(payment)
      end
    end

    context 'when using Payment Intents' do
      before { subject.preferred_v3_intents = true }

      context 'when the payment is completed' do
        before do
          allow(payment).to receive(:completed?) { true }
        end

        it 'creates a refund' do
          expect { subject.try_void(payment) }.to change { Spree::Refund.count }.by(1)
        end
      end

      context 'when the payment is not completed' do
        it_behaves_like 'voids the payment transaction'
      end
    end

    context 'when not using Payment Intents' do
      before { subject.preferred_v3_intents = false }

      context 'when the payment is completed' do
        it_behaves_like 'voids the payment transaction'
      end

      context 'when the payment is not completed' do
        it_behaves_like 'voids the payment transaction'
      end
    end
  end

  describe '#options_for_purchase_or_auth' do
    let(:card) do
      FactoryBot.create(
        :credit_card,
        gateway_customer_profile_id: 'cus_abcde',
        imported: false
      )
    end

    before do
      allow(subject).to receive(:options_for_purchase_or_auth).and_call_original
    end

    context 'transaction_options' do
      it 'includes basic values and keys' do
        options = subject.send(:options_for_purchase_or_auth, 19.99, card, {})
        expect(options[0]).to eq(19.99)
        expect(options[1]).to eq(card)
        expect(options[2].keys).to eq([:description, :currency, :customer])
      end

      it 'includes statement_descriptor_suffix within options' do
        transaction_options = { statement_descriptor_suffix: 'FFFFFFF' }
        options = subject.send(:options_for_purchase_or_auth, 19.99, card, transaction_options)
        expect(options.last[:statement_descriptor_suffix]).to eq('FFFFFFF')
      end
    end
  end
end
