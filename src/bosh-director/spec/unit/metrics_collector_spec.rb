require 'spec_helper'

module Bosh
  module Director
    describe MetricsCollector do
      before do
        MetricsCollector.instance.reset
      end

      context 'when metrics are not enabled' do
        let(:metrics) { MetricsCollector.instance }
        it 'treats metrics setting as a no-op' do
          metrics.set(:resurrection_enabled, 123)
          expect(metrics.get(:resurrection_enabled)).to be_nil
        end
      end

      context 'when metrics are enabled' do
        let(:metrics) { MetricsCollector.instance.enable }
        it 'allows getting and setting of metrics' do
          metrics.set(:resurrection_enabled, 123)
          expect(metrics.get(:resurrection_enabled)).to eq(123)
        end

        context 'resurrection_enabled' do
          it 'initializes to 1 if resurrection is enabled' do
            expect(metrics.get(:resurrection_enabled)).to eq(1)
          end

          it 'initializes to 0 if resurrection is disabled' do
            Models::DirectorAttribute.create(name: 'resurrection_paused', value: 'true')
            expect(metrics.get(:resurrection_enabled)).to eq(0)
          end
        end
      end
    end
  end
end
