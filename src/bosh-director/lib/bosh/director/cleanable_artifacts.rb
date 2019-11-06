module Bosh::Director
  class CleanableArtifacts
    def initialize(remove_all, logger, release_manager: Api::ReleaseManager.new)
      @logger = logger
      @release_manager = release_manager
      @remove_all = remove_all
    end

    def orphaned_vms
      Models::OrphanedVm.all
    end

    def releases
      releases_to_keep = @remove_all ? 0 : 2

      releases_to_delete_picker = Jobs::Helpers::ReleasesToDeletePicker.new(@release_manager)
      releases_to_delete_picker.pick(releases_to_keep)
    end

    def compiled_packages
      return [] unless @remove_all

      Jobs::Helpers::CompiledPackagesToDeletePicker.pick(stemcells)
    end

    def stemcells
      @stemcells ||= begin
                           stemcells_to_keep = @remove_all ? 0 : 2
                           stemcell_manager = Api::StemcellManager.new
                           stemcells_to_delete_picker = Jobs::Helpers::StemcellsToDeletePicker.new(stemcell_manager)
                           stemcells_to_delete_picker.pick(stemcells_to_keep)
                         end
    end

    def blobs
      dns_blob_age = @remove_all ? 0 : 3600
      dns_blobs_to_keep = if @remove_all && Models::Deployment.count.positive?
                            1
                          elsif @remove_all
                            0
                          else
                            10

                          end

      cleanup_params = { 'max_blob_age' => dns_blob_age, 'num_dns_blobs_to_keep' => dns_blobs_to_keep }
      dns_blob_cleanup = ScheduledDnsBlobsCleanup.new(cleanup_params)
      dns_blob_cleanup.blobs_to_delete
    end

    def orphan_disks
      return [] unless @remove_all

      Models::OrphanDisk.all
    end

    def exported_releases
      Models::Blob.where(type: 'exported-release').all
    end

    def show_all
      {
        releases: releases.map { |r| "#{r['name']}/#{r['versions']}" },
        stemcells: stemcells.map { |r| "#{r['operating_system']}/#{r['version']}" },
        compiled_packages: compiled_packages.map { |r| "#{r.stemcell_os}/#{r.stemcell_version}" },
        orphaned_disks: orphan_disks.map { |r| r.disk_cid },
        orphaned_vms: orphaned_vms.map { |r| r.cid },
        exported_releases: exported_releases.map { |r| r.blobstore_id },
        blobs: blobs.map { |r| r.blob_id },
      }
    end
  end
end


