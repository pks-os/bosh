require 'db_migrator'
require 'rufus-scheduler'
require 'prometheus/client'

module Bosh
  module Director
    class MetricsCollector
      def initialize(config)
        @config = config

        @registry = Prometheus::Client.registry
        @resurrection_enabled = Prometheus::Client::Gauge.new(
          :resurrection_enabled,
          docstring: 'Is resurrection enabled? 0 for disabled, 1 for enabled',
        )

        @registry.register(@resurrection_enabled)
      end

      def start
        ensure_migrations
        Bosh::Director::App.new(@config)

        populate_metrics

        Rufus::Scheduler::PlainScheduler.new.every '30s' do
          populate_metrics
        end
      end

      private

      def ensure_migrations
        if defined?(Bosh::Director::Models)
          raise 'Bosh::Director::Models were loaded before ensuring migrations are current. Cowardly refusing to start worker.'
        end
        migrator = DBMigrator.new(@config.db, :director)
        unless migrator.finished?
          @config.worker_logger.error(
            "Migrations not current during worker start after #{DBMigrator::MAX_MIGRATION_ATTEMPTS} attempts.",
          )
          raise "Migrations not current after #{DBMigrator::MAX_MIGRATION_ATTEMPTS} retries"
        end
        require 'bosh/director'
      end

      def populate_metrics
        @resurrection_enabled.set(Api::ResurrectorManager.new.pause_for_all? ? 0 : 1)
      end
    end
  end
end
