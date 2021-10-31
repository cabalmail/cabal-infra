property :name,                        String, required: true, name_property: true
property :value,                       [String, Array]
property :type,                        String, required: true
property :ttl,                         Integer, default: 3600
property :zone_id,                     String
property :aws_region,                  String

action :create do
  require 'aws-sdk'

  upsert_record
  Chef::Log.info "Record created: #{new_resource.name}[#{new_resource.type}]"
end

action_class do
  def route53
    @route53 ||= begin
      @route53 = Aws::Route53::Client.new(region: new_resource.aws_region)
    end
  end

  def resource_record_set
    rr_set = {
      name: new_resource.name,
      type: new_resource.type,
    }
    rr_set[:ttl] = new_resource.ttl
    rr_set[:resource_records] = new_resource.value.sort.map { |v| { value: v } }
    rr_set
  end

  def upsert_record(action)
    request = {
      hosted_zone_id: "/hostedzone/#{new_resource.zone_id}",
      change_batch: {
        comment: "Chef Route53 Resource: #{new_resource.name}",
        changes: [
          {
            action: action,
            resource_record_set: resource_record_set,
          },
        ],
      },
    }
    converge_by("#{action} record #{new_resource.name} ") do
      response = route53.change_resource_record_sets(request)
    end
  end
end
