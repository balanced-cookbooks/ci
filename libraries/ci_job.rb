#
# Author:: Noah Kantrowitz <noah@coderanger.net>
#
# Copyright 2013, Balanced, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require File.expand_path('../ci_deploy_key', __FILE__)

class Chef
  class Resource::CiJob < Resource
    include Poise(parent: CiServer, parent_optional: true)
    include Ci::SshHelper::Resource
    actions(:enable, :disable)

    attribute(:job_name, kind_of: String, default: lazy { name.split('::').last })
    attribute(:path, kind_of: String, default: lazy { node['ci']['path'] })
    attribute(:source, kind_of: String)
    attribute(:cookbook, kind_of: [String, Symbol])
    attribute(:content, kind_of: String)

    attribute(:repository, kind_of: String, default: lazy { node['ci']['repository'] })
    attribute(:builder_label, kind_of: [String, FalseClass], default: lazy { job_name })
    attribute(:command, kind_of: String, required: true)

    attribute(:server_url, kind_of: String, default: lazy { node['ci']['server_url'] || search_for_server })
    attribute(:server_username, kind_of: String, default: lazy { node['ci']['server_username'] })
    attribute(:server_api_key, kind_of: String, default: lazy { node['ci']['server_api_key'] })
    attribute(:is_builder, equal_to: [true, false], default: lazy { node['ci']['is_builder'] })
    def builder_recipe(arg=nil, &block)
      set_or_return(:builder_recipe, arg || block, kind_of: [String, Proc], default: node['ci']['builder_recipe'])
    end

    def after_created
      super
      raise "#{self}: Only one of source or content can be specified" if source && content
      raise Exceptions::ValidationFailed, 'Required argument repository is missing!' unless repository

      # If source is given, the default cookbook should be the current one
      cookbook(source ? cookbook_name : 'ci')
      # If neither source nor content are given, fill in a default
      source('job-config.xml.erb') if !source && !content

      # Interpolate the job name into a few attributes to make life easier
      %w{repository builder_recipe}.each do |key|
        val = send(key)
        send(key, val % {name: job_name}) if val && val.is_a?(String)
      end
    end

    def search_for_server
      raise "Please specify a server URL via node['ci']['server_url']" if Chef::Config[:solo]
      server = partial_search(:node, 'ci_is_server:true', rows: 1, keys: {ip: ['ipaddress'], local_ipv4: ['cloud', 'local_ipv4'], is_ssl: ['ci', 'is_server_ssl'], port: ['ci', 'server_port']}).first.first
      raise "Unable to find Jenkins server via search" unless server
      "#{server['is_ssl'] ? 'https' : 'http'}://#{server['local_ipv4'] || server['ip']}:#{server['port']}/"
    end

  end

  class Provider::CiJob < Provider
    include Poise
    include Ci::SshHelper::Provider

    def action_enable
      if new_resource.parent
        converge_by("create jenkins job #{new_resource.job_name}") do
          notifying_block do
            create_job
          end
        end
      end
      if new_resource.is_builder
        converge_by("install builder for #{new_resource.job_name}") do
          install_builder_recipe
          create_node
          create_ssh_dir
          manage_ssh
        end
      end
    end

    def action_disable
      if new_resource.parent
        converge_by("disable jenkins job #{new_resource.job_name}") do
          notifying_block do
            disable_job
          end
        end
      end
      if new_resource.is_builder
        converge_by("remove builder for #{new_resource.job_name}") do
          delete_node
        end
      end
    end

    def ssh_user
      node['jenkins']['node']['user']
    end

    def ssh_group
      node['jenkins']['node']['group']
    end

    private

    def create_job
      jenkins_job new_resource.job_name do
        source new_resource.source
        cookbook new_resource.cookbook
        content new_resource.content
        parent new_resource.parent
        options do
          repository new_resource.repository
          command new_resource.command
          builder_label new_resource.builder_label if new_resource.builder_label
        end
      end
    end

    def disable_job
      r = enable_job
      r.action(:disable)
      r
    end

    def install_builder_recipe
      include_recipe(new_resource.builder_recipe)
    end

    def create_node
      jenkins_node node.name do
        parent new_resource.parent
        path new_resource.path
        labels [new_resource.builder_label] if new_resource.builder_label
        server_url new_resource.server_url
        server_username new_resource.server_username
        server_password new_resource.server_api_key
      end
    end

    def create_ssh_dir
      directory ::File.join(new_resource.path, '.ssh') do
        owner node['jenkins']['node']['user']
        group node['jenkins']['node']['group']
        mode '700'
      end
    end

    def delete_node
      r = create_node
      r.action(:delete)
      r
    end

  end
end
