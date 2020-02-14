require 'bosh/director/api/controllers/base_controller'

module Bosh::Director
  module Api::Controllers
    class ReleasesController < BaseController
      post '/', scope: :upload_releases, consumes: :json do
        payload = json_decode(request.body.read)
        if payload['sha1'] && params['sha1']
          message = 'Sha1 provided in multiple places'
          throw(:halt, [400, message])
        end

        sha1 = payload['sha1'] || params['sha1']

        options = {
          rebase: params['rebase'] == 'true',
          fix: params['fix'] == 'true',
          sha1: sha1,
        }

        task = @release_manager.create_release_from_url(current_user, payload['location'], options)
        redirect "/tasks/#{task.id}"
      end

      post '/', scope: :upload_releases, consumes: :multipart do
        options = {
          rebase: params['rebase'] == 'true',
          fix: params['fix'] == 'true',
        }

        task = @release_manager.create_release_from_file_path(current_user, params[:nginx_upload_path], options)
        redirect "/tasks/#{task.id}"
      end

      get '/', scope: :read_releases do
        releases = @release_manager.all_releases

        json_encode(releases)
      end

      post '/export', consumes: :json do
        body_params = JSON.parse(request.body.read)

        deployment_name = body_params['deployment_name']
        release_name = body_params['release_name']
        release_version = body_params['release_version']
        stemcell_os = body_params['stemcell_os']
        stemcell_version = body_params['stemcell_version']
        sha2 = body_params['sha2']
        jobs = body_params['jobs']

        task = @release_manager.export_release(
          current_user, deployment_name, release_name, release_version, stemcell_os, stemcell_version, sha2, jobs
        )

        redirect "/tasks/#{task.id}"
      end

      get '/:name', scope: :read_releases do
        name = params[:name].to_s.strip

        return inspect_release(name, params['version']) if params['version']

        release = @release_manager.find_by_name(name)

        result = {}

        result['packages'] = release.packages.map do |package|
          {
            'name' => package.name,
            'sha1' => package.sha1,
            'version' => package.version.to_s,
            'dependencies' => package.dependency_set.to_a,
          }
        end

        result['jobs'] = release.templates.map do |template|
          {
            'name' => template.name,
            'sha1' => template.sha1,
            'version' => template.version.to_s,
            'packages' => template.package_names,
          }
        end

        result['versions'] = release.versions.map do |rv|
          rv.version.to_s
        end

        content_type(:json)
        json_encode(result)
      end

      delete '/:name' do
        release = @release_manager.find_by_name(params[:name])

        options = {}
        options['force'] = true if params['force'] == 'true'
        options['version'] = params['version']

        task = @release_manager.delete_release(current_user, release, options)
        redirect "/tasks/#{task.id}"
      end

      private

      def inspect_release(name, version)
        release = @release_manager.find_by_name(name)
        release_version = @release_manager.find_version(release, version)

        result = {}

        result['jobs'] = release_version.templates.sort_by(&:name).map do |template|
          {
            'name' => template.name,
            'blobstore_id' => template.blobstore_id,
            'sha1' => template.sha1,
            'fingerprint' => template.fingerprint.to_s,
            'consumes' => template.consumes,
            'provides' => template.provides,
          }
        end

        result['packages'] = release_version.packages.sort_by(&:name).map do |package|
          {
            'name' => package.name,
            'blobstore_id' => package.blobstore_id,
            'sha1' => package.sha1,
            'fingerprint' => package.fingerprint.to_s,
            'compiled_packages' => package.compiled_packages.sort_by { |cp| [cp.stemcell_os, cp.stemcell_version] }.map do |compiled|
                                     {
                                       'stemcell' => "#{compiled.stemcell_os}/#{compiled.stemcell_version}",
                                       'sha1' => compiled.sha1,
                                       'blobstore_id' => compiled.blobstore_id,
                                     }
                                   end,
          }
        end

        content_type(:json)
        json_encode(result)
      end
    end
  end
end
