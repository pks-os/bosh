module Bosh::Director
  module Jobs
    class CleanupArtifacts < BaseJob
      include Bosh::Director::LockHelper

      @queue = :normal

      def self.job_type
        :delete_artifacts
      end

      def self.enqueue(username, config, job_queue)
        description = config['remove_all'] ? 'clean up all' : 'clean up'
        job_queue.enqueue(username, Jobs::CleanupArtifacts, description, [config])
      end

      def initialize(config)
        @config = config
      end

      def perform
        blobstore = App.instance.blobstores.blobstore
        compiled_package_deleter = Jobs::Helpers::CompiledPackageDeleter.new(blobstore, logger)
        stemcell_deleter = Jobs::Helpers::StemcellDeleter.new(logger)
        package_deleter = Helpers::PackageDeleter.new(compiled_package_deleter, blobstore, logger)
        template_deleter = Helpers::TemplateDeleter.new(blobstore, logger)
        release_deleter = Helpers::ReleaseDeleter.new(package_deleter, template_deleter, Config.event_log, logger)
        release_version_deleter =
          Helpers::ReleaseVersionDeleter.new(release_deleter, package_deleter, template_deleter, logger, Config.event_log)
        release_manager = Api::ReleaseManager.new
        name_version_release_deleter =
          Helpers::NameVersionReleaseDeleter.new(release_deleter, release_manager, release_version_deleter, logger)

        orphaned_vm_deleter = OrphanedVMDeleter.new(logger)
        orphan_disk_manager = OrphanDiskManager.new(Config.logger)

        cleanable_artifacts = CleanableArtifacts.new(@config['remove_all'], logger, release_manager: release_manager)

        num_orphaned_vms_deleted = delete_orphaned_vms(orphaned_vm_deleter, cleanable_artifacts.orphaned_vms)

        num_releases_deleted = delete_releases(
          name_version_release_deleter,
          cleanable_artifacts.releases,
        )

        num_stemcells_deleted = delete_stemcells(
          stemcell_manager,
          stemcell_deleter,
          cleanable_artifacts.stemcells,
        )

        num_compiled_packages_deleted = delete_compiled_packages(compiled_package_deleter, cleanable_artifacts.compiled_packages)
        num_orphaned_disks_deleted = delete_orphaned_disks(orphan_disk_manager, cleanable_artifacts.orphan_disks)
        num_exported_releases_deleted = delete_exported_releases(blobstore, cleanable_artifacts.exported_releases)
        dns_blob_message = delete_expired_dns_blobs(dns_blob_cleanup, cleanable_artifacts.expired_blobs)

        "Deleted #{num_releases_deleted} release(s), " \
          "#{num_stemcells_deleted} stemcell(s), " \
          "#{num_compiled_packages_deleted} extra compiled package(s), " \
          "#{num_orphaned_disks_deleted} orphaned disk(s), " \
          "#{num_orphaned_vms_deleted} orphaned vm(s), " \
          "#{num_exported_releases_deleted} exported release(s), " \
          "#{dns_blob_message}"
      end

      private

      def delete_orphaned_vms(orphaned_vm_deleter, orphaned_vms)
        orphaned_vm_stage = Config.event_log.begin_stage('Deleting orphaned vms', orphaned_vms.count)
        ThreadPool.new(max_threads: Config.max_threads).wrap do |pool|
          orphaned_vms.each do |orphaned_vm|
            pool.process do
              orphaned_vm_stage.advance_and_track(orphaned_vm.cid) do
                orphaned_vm_deleter.delete_vm(orphaned_vm, 10)
              end
            end
          end
        end
        orphaned_vms.count
      end

      def delete_releases(name_version_release_deleter, unused_release_name_and_versions)
        release_count = unused_release_name_and_versions.map { |r| r['versions'] }.flatten.count
        release_stage = Config.event_log.begin_stage('Deleting releases', release_count)
        ThreadPool.new(max_threads: Config.max_threads).wrap do |pool|
          unused_release_name_and_versions.each do |release|
            pool.process do
              name = release['name']
              with_release_lock(name, timeout: 10) do
                release['versions'].each do |version|
                  release_stage.advance_and_track("#{name}/#{version}") do
                    name_version_release_deleter.find_and_delete_release(name, version, false)
                  end
                end
              end
            end
          end
        end

        release_count
      end

      def delete_stemcells(stemcell_manager, stemcell_deleter, stemcells_to_delete)
        stemcell_stage = Config.event_log.begin_stage('Deleting stemcells', stemcells_to_delete.count)
        ThreadPool.new(max_threads: Config.max_threads).wrap do |pool|
          stemcells_to_delete.each do |stemcell|
            pool.process do
              stemcell_stage.advance_and_track("#{stemcell['name']}/#{stemcell['version']}") do
                Models::StemcellUpload.where(name: stemcell['name'], version: stemcell['version']).delete
                stemcells = stemcell_manager.all_by_name_and_version(stemcell['name'], stemcell['version'])
                stemcells.each { |s| stemcell_deleter.delete(s) }
              end
            end
          end
        end

        stemcells_to_delete.count
      end

      def delete_compiled_packages(compiled_package_deleter, compiled_packages_to_delete)
        remaining_compiled_packages_to_delete = compiled_packages_to_delete.reject do |cp|
          cp.package.nil? # deleting release version may have already deleted package by cascade
        end
        compiled_package_stage = Config.event_log.begin_stage('Deleting compiled packages',
          remaining_compiled_packages_to_delete.count)
        ThreadPool.new(max_threads: Config.max_threads).wrap do |pool|
          remaining_compiled_packages_to_delete.each do |compiled_package|
            pool.process do
              cp_desc = "#{compiled_package.name} for #{compiled_package.stemcell_os}/#{compiled_package.stemcell_version}"
              compiled_package_stage.advance_and_track(cp_desc) do
                compiled_package_deleter.delete(compiled_package)
              end
            end
          end
        end

        remaining_compiled_packages_to_delete.count
      end

      def delete_orphaned_disks(orphan_disk_manager, orphan_disks)
        orphan_disk_stage = Config.event_log.begin_stage('Deleting orphaned disks', orphan_disks.count)
        ThreadPool.new(max_threads: Config.max_threads).wrap do |pool|
          orphan_disks.each do |orphan_disk|
            pool.process do
              orphan_disk_stage.advance_and_track(orphan_disk.disk_cid.to_s) do
                orphan_disk_manager.delete_orphan_disk(orphan_disk)
              end
            end
          end
        end

        orphan_disks.count
      end

      def delete_exported_releases(blobstore, exported_releases)
        exported_release_count = exported_releases.count
        exported_release_stage = Config.event_log.begin_stage('Deleting exported releases', exported_releases.count)
        exported_releases.each do |exported_release|
          exported_release_stage.advance_and_track(exported_release.blobstore_id) do
            blobstore.delete(exported_release.blobstore_id)
            exported_release.destroy
          end
        end

        exported_release_count
      end

      def delete_expired_dns_blobs(dns_blob_cleanup, expired_blobs)
        dns_blob_message = ''

        dns_blobs_stage = Config.event_log.begin_stage('Deleting dns blobs', 1)
        dns_blobs_stage.advance_and_track('DNS blobs') do
          dns_blob_message = dns_blob_cleanup.perform(expired_blobs)
        end

        dns_blob_message
      end
    end
  end
end
