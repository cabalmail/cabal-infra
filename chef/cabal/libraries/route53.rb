class Route53Record
  def self.create(name, value, type, ttl, zone_id, options)
    require 'aws-sdk-route53'
    region = options[:region]
    route53 = Aws::Route53::Client.new(region: region)
    resp = route53.change_resource_record_sets({
      change_batch: {
        changes: [
          {
            action: "UPSERT",
            resource_record_set: {
              name: name,
              resource_records: [
                {
                  value: value,
                },
              ],
              ttl: ttl,
              type: type,
            },
          },
        ],
      },
      hosted_zone_id: zone_id,   
    })
  end
end
