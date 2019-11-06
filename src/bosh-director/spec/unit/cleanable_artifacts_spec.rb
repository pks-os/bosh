require 'spec_helper'

module Bosh::Director
  describe CleanableArtifacts do
    context 'when dryrun is configured' do
      before do
        Bosh::Director::Models::Blob.new(blobstore_id: 'exported_release_id_1', sha1: 'smurf1', type: 'exported-release').save
        Bosh::Director::Models::Blob.new(blobstore_id: 'exported_release_id_2', sha1: 'smurf2', type: 'exported-release').save
      end
      let(:remove_all) { true }
      subject { CleanableArtifacts.new(remove_all, logger) }

      it 'reports the releases and stemcells it would delete' do
        result = subject.show_all
        expect(result).to eq(
          {:releases=>["release-1/[\"1\"]", "release-2/[\"2\"]"],
           :stemcells=>["gentoo_linux/1", "/2"],
           :compiled_packages=>["gentoo_linux/1"],
           :orphaned_disks=>[],
           :orphaned_vms=>[],
           :exported_releases=>["exported_release_id_1", "exported_release_id_2"],
           blobs: []
        }
        )
      end
    end
  end
end
