require "log4r"
require 'json'

require 'vagrant/util/retryable'

require 'vagrant-aws/util/timer'

module VagrantPlugins
  module AWS
    module Action
      # This runs the configured instance.
      class RunInstance
        @@instances = 0
        LIMIT = 10
        
        def self.update_instances
          @@instances = @@instances + 1
        end

        def self.instances
          @@instances
        end

        include Vagrant::Util::Retryable

        def initialize(app, env)
          RunInstance.update_instances
          @app    = app
          @instance_no = RunInstance.instances
          @iteration = 1
          @logger = Log4r::Logger.new("vagrant_aws::action::run_instance")
          @logger.info("---------------------- No of instances - #{RunInstance.instances}---------------")
          control_vm_creation
        end

        def call(env)
          # Initialize metrics if they haven't been
          env[:metrics] ||= {}

          # Get the region we're going to booting up in
          region = env[:machine].provider_config.region

          # Get the configs
          region_config         = env[:machine].provider_config.get_region_config(region)
          ami                   = region_config.ami
          availability_zone     = region_config.availability_zone
          instance_type         = region_config.instance_type
          keypair               = region_config.keypair_name
          private_ip_address    = region_config.private_ip_address
          security_groups       = region_config.security_groups
          subnet_id             = region_config.subnet_id
          tags                  = region_config.tags
          user_data             = region_config.user_data
          block_device_mapping  = region_config.block_device_mapping
          elastic_ip            = region_config.elastic_ip
          allocate_elastic_ip   = region_config.allocate_elastic_ip
          terminate_on_shutdown = region_config.terminate_on_shutdown
          iam_instance_profile_arn  = region_config.iam_instance_profile_arn
          iam_instance_profile_name = region_config.iam_instance_profile_name
          monitoring            = region_config.monitoring
          ebs_optimized         = region_config.ebs_optimized

          # If there is no keypair then warn the user
          if !keypair
            env[:ui].warn(I18n.t("vagrant_aws.launch_no_keypair"))
          end

          # If there is a subnet ID then warn the user
          if subnet_id and not elastic_ip and not allocate_elastic_ip
            env[:ui].warn(I18n.t("vagrant_aws.launch_vpc_warning"))
          end
          # Launch!
          env[:ui].info(I18n.t("vagrant_aws.launching_instance"))
          env[:ui].info(" -- Type: #{instance_type}")
          env[:ui].info(" -- AMI: #{ami}")
          env[:ui].info(" -- Region: #{region}")
          env[:ui].info(" -- Availability Zone: #{availability_zone}") if availability_zone
          env[:ui].info(" -- Keypair: #{keypair}") if keypair
          env[:ui].info(" -- Subnet ID: #{subnet_id}") if subnet_id
          env[:ui].info(" -- IAM Instance Profile ARN: #{iam_instance_profile_arn}") if iam_instance_profile_arn
          env[:ui].info(" -- IAM Instance Profile Name: #{iam_instance_profile_name}") if iam_instance_profile_name
          env[:ui].info(" -- Private IP: #{private_ip_address}") if private_ip_address
          env[:ui].info(" -- Elastic IP: #{elastic_ip.inspect}") if elastic_ip
          env[:ui].info(" -- Allocate Elastic IP: #{allocate_elastic_ip.inspect}") if allocate_elastic_ip 
          env[:ui].info(" -- User Data: yes") if user_data
          env[:ui].info(" -- Security Groups: #{security_groups.inspect}") if !security_groups.empty?
          env[:ui].info(" -- User Data: #{user_data}") if user_data
          env[:ui].info(" -- Block Device Mapping: #{block_device_mapping}") if block_device_mapping
          env[:ui].info(" -- Terminate On Shutdown: #{terminate_on_shutdown}")
          env[:ui].info(" -- Monitoring: #{monitoring}")
          env[:ui].info(" -- EBS optimized: #{ebs_optimized}")

          options = {
            :availability_zone         => availability_zone,
            :flavor_id                 => instance_type,
            :image_id                  => ami,
            :key_name                  => keypair,
            :private_ip_address        => private_ip_address,
            :subnet_id                 => subnet_id,
            :iam_instance_profile_arn  => iam_instance_profile_arn,
            :iam_instance_profile_name => iam_instance_profile_name,
            :tags                      => tags,
            :user_data                 => user_data,
            :elastic_ip                => elastic_ip,
            :allocate_elastic_ip       => allocate_elastic_ip,
            :instance_initiated_shutdown_behavior => terminate_on_shutdown == true ? "terminate" : nil,
            :monitoring                => monitoring,
            :ebs_optimized             => ebs_optimized
          }
          options = process_block_device_options(options, block_device_mapping)
          if !security_groups.empty?
            security_group_key = options[:subnet_id].nil? ? :groups : :security_group_ids
            options[security_group_key] = security_groups
          end

          begin
            env[:ui].warn(I18n.t("vagrant_aws.warn_ssh_access")) unless allows_ssh_port?(env, security_groups, subnet_id)

            @logger.info("---------------------- All Options - #{options}---------------")
            server = env[:aws_compute].servers.create(options)
          rescue Fog::Compute::AWS::NotFound => e
            # Invalid subnet doesn't have its own error so we catch and
            # check the error message here.
            if e.message =~ /subnet ID/
              raise Errors::FogError,
                :message => "Subnet ID not found: #{subnet_id}"
            end

            raise
          rescue Fog::Compute::AWS::Error => e
            raise Errors::FogError, :message => e.message
          rescue Excon::Errors::HTTPStatusError => e
            raise Errors::InternalFogError,
              :error => e.message,
              :response => e.response.body
          end

          # Immediately save the ID since it is created at this point.
          env[:machine].id = server.id

                   
          # Wait for the instance to be ready first
          env[:metrics]["instance_ready_time"] = Util::Timer.time do
            tries = region_config.instance_ready_timeout / 2

            env[:ui].info(I18n.t("vagrant_aws.waiting_for_ready"))
            begin
              retryable(:on => Fog::Errors::TimeoutError, :tries => tries) do
                # If we're interrupted don't worry about waiting
                next if env[:interrupted]

                # Wait for the server to be ready
                server.wait_for(3) { ready? }
              end
            rescue Fog::Errors::TimeoutError
              # Delete the instance
              terminate(env)

              # Notify the user
              raise Errors::InstanceReadyTimeout,
                timeout: region_config.instance_ready_timeout
            end
          end

          @logger.info("Time to instance ready: #{env[:metrics]["instance_ready_time"]}")

          # Create and attach ebs volume if present
          if not ebs_volumes(block_device_mapping).empty?
            @logger.info("creating and attaching ebs volume")
            ebs_volumes(block_device_mapping).each do |ebs_vol|
              vol_options = build_volume_options(ebs_vol,server.availability_zone)
              begin
                @logger.info("VOL OPTIONS - #{vol_options}")
                volume = env[:aws_compute].volumes.create(vol_options)
                @logger.info("------------------- v - #{volume.inspect} ----------------")
                tries = region_config.instance_ready_timeout / 2
                attach_volume_to_server(env[:aws_compute],volume.id,server.id,ebs_vol['DeviceName'],tries)
              rescue Fog::Compute::AWS::Error => e
                raise Errors::FogError, :message => e.message
              end
            end
          end

          # Allocate and associate an elastic IP if requested
          #if elastic_ip
          #  domain = subnet_id ? 'vpc' : 'standard'
          #  do_elastic_ip(env, domain, server)
          #end
          if elastic_ip
            associate_elastic_ip(env,elastic_ip)
          elsif allocate_elastic_ip
            allocate_and_associate_elastic_ip(env,allocate_elastic_ip)
          end

          if !env[:interrupted]
            env[:metrics]["instance_ssh_time"] = Util::Timer.time do
              # Wait for SSH to be ready.
              env[:ui].info(I18n.t("vagrant_aws.waiting_for_ssh"))
              while true
                # If we're interrupted then just back out
                break if env[:interrupted]
                break if env[:machine].communicate.ready?
                sleep 2
              end
            end

            @logger.info("Time for SSH ready: #{env[:metrics]["instance_ssh_time"]}")

            # Ready and booted!
            env[:ui].info(I18n.t("vagrant_aws.ready"))
          end

          # Terminate the instance if we were interrupted
          terminate(env) if env[:interrupted]

          @app.call(env)
        end

        def recover(env)
          return if env["vagrant.error"].is_a?(Vagrant::Errors::VagrantError)

          if env[:machine].provider.state.id != :not_created
            # Undo the import
            terminate(env)
          end
        end

        def allows_ssh_port?(env, test_sec_groups, is_vpc)
          port = 22 # TODO get ssh_info port
          test_sec_groups = [ "default" ] if test_sec_groups.empty? # AWS default security group
          # filter groups by name or group_id (vpc)
          groups = test_sec_groups.map do |tsg|
            env[:aws_compute].security_groups.all.select { |sg| tsg == (is_vpc ? sg.group_id : sg.name) }
          end.flatten
          # filter TCP rules
          rules = groups.map { |sg| sg.ip_permissions.select { |r| r["ipProtocol"] == "tcp" } }.flatten
          # test if any range includes port
          !rules.select { |r| (r["fromPort"]..r["toPort"]).include?(port) }.empty?
        end

        def do_elastic_ip(env, domain, server)
          begin
            allocation = env[:aws_compute].allocate_address(domain)
          rescue
            @logger.debug("Could not allocate Elastic IP.")
            terminate(env)
            raise Errors::FogError,
                            :message => "Could not allocate Elastic IP."
          end
          @logger.debug("Public IP #{allocation.body['publicIp']}")

          # Associate the address and save the metadata to a hash
          if domain == 'vpc'
            # VPC requires an allocation ID to assign an IP
            association = env[:aws_compute].associate_address(server.id, nil, nil, allocation.body['allocationId'])
            h = { :allocation_id => allocation.body['allocationId'], :association_id => association.body['associationId'], :public_ip => allocation.body['publicIp'] }
          else
            # Standard EC2 instances only need the allocated IP address
            association = env[:aws_compute].associate_address(server.id, allocation.body['publicIp'])
            h = { :public_ip => allocation.body['publicIp'] }
          end

          unless association.body['return']
            @logger.debug("Could not associate Elastic IP.")
            terminate(env)
            raise Errors::FogError,
                            :message => "Could not allocate Elastic IP."
          end

          # Save this IP to the data dir so it can be released when the instance is destroyed
          ip_file = env[:machine].data_dir.join('elastic_ip')
          ip_file.open('w+') do |f|
            f.write(h.to_json)
          end
        end

        def terminate(env)
          destroy_env = env.dup
          destroy_env.delete(:interrupted)
          destroy_env[:config_validate] = false
          destroy_env[:force_confirm_destroy] = true
          env[:action_runner].run(Action.action_destroy, destroy_env)
        end

        def associate_elastic_ip(env,elastic_ip)
          begin
            eip = env[:aws_compute].addresses.get(elastic_ip)
            if eip.nil?
              terminate(env)
              raise Errors::FogError,
                :message => "Elastic IP specified not found: #{elastic_ip}"
            end
            @logger.info("eip - #{eip}")
            env[:aws_compute].associate_address(env[:machine].id,nil,nil,eip.allocation_id)
            env[:ui].info(I18n.t("vagrant_aws.elastic_ip_allocated"))
          rescue Fog::Compute::AWS::NotFound => e
          # Invalid elasticip doesn't have its own error so we catch and
          # check the error message here.
            if e.message =~ /Elastic IP/
              terminate(env)
              raise Errors::FogError,
                :message => "Elastic IP not found: #{elastic_ip}"
            end
            raise
          end
        end

        def allocate_and_associate_elastic_ip(env,allocate_elastic_ip)
          begin
            allocated_eip = env[:aws_compute].allocate_address(allocate_elastic_ip)
            associate_elastic_ip(env,allocated_eip[:body]["publicIp"])
          rescue Fog::Compute::AWS::NotFound => e
            # Invalid computation of elasticip doesn't have its own error so we catch and
            # check the error message here.
            if e.message =~ /Elastic IP/
              terminate(env)
              raise Errors::FogError,
                :message => "Elastic IP not allocated with allocate_elastic_ip option: #{allocate_elastic_ip}"
            end
            raise
          end
        end
        
        def process_block_device_options(options,block_devices)
          ephemeral_devices = block_devices - ebs_volumes(block_devices)
          if not ephemeral_devices.empty?
            options[:block_device_mapping] = block_devices
          end
          options
        end

        def build_volume_options(ebs_vol,availability_zone)
          volume_options = {}
          volume_options[:device] = ebs_vol['DeviceName'] || '/dev/sdf'
          volume_options[:tags] = {'Name' => ebs_vol['VirtualName']} if ebs_vol.has_key?('VirtualName')
          volume_options[:size] = ebs_vol['Ebs.VolumeSize'] || raise("EBS Volume size not specified")
          volume_options[:availability_zone] = availability_zone
          volume_options[:delete_on_termination] = ebs_vol['Ebs.DeleteOnTermination'] || true
          volume_options[:type] = ebs_vol['Ebs.VolumeType'] if ebs_vol.has_key?('Ebs.VolumeType')
          volume_options[:iops] = ebs_vol['Ebs.Iops'] if ebs_vol.has_key?('Ebs.Iops')
          volume_options
        end
              
        def ebs_volumes(block_devices) 
          block_devices.select { |block_device| block_device.has_key?('Ebs.VolumeSize') or block_device.has_key?('Ebs.VolumeType') }
        end

        def attach_volume_to_server(connection,volume_id,server_id,device,tries)
          try = 0
          while try < tries do
            sleep(5)
            break if connection.volumes.find{ |vol| vol.id == volume_id}.state == 'available'
            try = try + 1
          end
          raise_error("Taking too long to create volume with id #{volume_id}") if try == tries
          output = connection.attach_volume(server_id,volume_id,device)
          try = 0
          while try < tries do 
            break if connection.volumes.find{ |vol| vol.id == volume_id}.state == 'in-use'
            try = try + 1
          end          
          raise_error("Unable to attach volume #{volume_id} as device #{device} to server #{server_id}") if try == tries
        end

        def raise_error(error_message)
          raise Errors::FogError,
                  :message => error_message
        end

        def control_vm_creation
          while @instance_no > (LIMIT * @iteration) do
            @iteration = @iteration + 1
            @logger.info("----------------instance_no - #{@instance_no} will wait-----------------")
            sleep 30
          end
        end
      end
    end
  end
end
