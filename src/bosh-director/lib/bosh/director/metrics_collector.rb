require 'prometheus/client'
require 'prometheus/client/data_stores/direct_file_store'

module Bosh::Director
  class MetricsCollector
    include Singleton

    def initialize
      @enabled = false
    end

    def enable
      return self if @enabled

      @enabled = true

      Prometheus::Client.config.data_store = Prometheus::Client::DataStores::DirectFileStore.new(dir: '/var/vcap/store/director/prometheus')
      @registry = Prometheus::Client.registry
      @resurrection_enabled = @registry.gauge(
        :resurrection_enabled,
        docstring: 'Is resurrection enabled? 0 for disabled, 1 for enabled',
      )
      populate_metrics

      self
    end

    def get(metric_name)
      return unless @enabled

      instance_variable_get("@#{metric_name}").get
    end

    def set(metric_name, value)
      return unless @enabled

      instance_variable_get("@#{metric_name}").set(value)
    end

    def reset
      return self unless @enabled

      @registry.unregister(:resurrection_enabled)
      @enabled = false

      self
    end

    private

    def populate_metrics
      @resurrection_enabled.set(Api::ResurrectorManager.new.pause_for_all? ? 0 : 1)
    end
  end
end
