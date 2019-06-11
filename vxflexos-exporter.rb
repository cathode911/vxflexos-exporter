require 'json'
require 'net/http'
require 'openssl'
require 'socket'

def gem_available?(name)
  Gem::Specification.find_by_name(name)
rescue Gem::LoadError
  false
end

require 'pry' if gem_available?('pry')

class VxFlexOSExporter
  def initialize
    file = open("config.json") rescue raise('config file config.json is missing in the root folder of VxFlexOSExporter')
    json = file.read
    @config = JSON.parse(json) rescue raise('config file config.json has some syntax errors inside, please validate it')

    file = open("metric_query_selection.json") rescue raise('config file metric_query_selection.json is missing in the root folder of VxFlexOSExporter')
    json = file.read
    @query = JSON.parse(json) rescue raise('config file metric_query_selection.json has some syntax errors inside, please validate it')

    file = open("metric_definition.json") rescue raise('config file metric_definition.json is missing in the root folder of VxFlexOSExporter')
    json = file.read
    @defs = JSON.parse(json) rescue raise('config file metric_definition.json has some syntax errors inside, please validate it')

    #file = open("properties_selected.json") rescue raise('config file properties_selected.json is missing in the root folder of VxFlexOSExporter')
    #json = file.read
    #@props = JSON.parse(json) rescue raise('config file properties_selected.json has some syntax errors inside, please validate it')

    server = TCPServer.new @config['prom']['listen_port']

    while session = server.accept
      @stats_processed = []
      get_auth_token
      get_tree
      process_tree
      get_stats
      process_stats
      convert_kb_iops

      request = session.gets
      puts request

      session.print "HTTP/1.1 200\r\n" # 1
      session.print "Content-Type: text/plaintext\r\n" # 2
      session.print "\r\n" # 3
      output_stats(session)

      session.close
    end
  end

  def get_auth_token
    uri = URI("https://#{@config['vxf']['host']}:#{@config['vxf']['port'] || 443}/api/login")

    Net::HTTP.start(@config['vxf']['host'], @config['vxf']['port'] || 443,
      :use_ssl => uri.scheme == 'https', 
      :verify_mode => OpenSSL::SSL::VERIFY_NONE) do |http|

      request = Net::HTTP::Get.new(uri.request_uri)
      request.basic_auth(@config['vxf']['user'], @config['vxf']['pass'])

      response = http.request(request)

      if response.body.include?('Unauthorized')
        raise 'Auth at VXFlexOS failed: please check login and password in @config.json'
      else
        @auth_token = response.body.gsub('"','')
      end
      puts 'Got auth token: ' + @auth_token
    end
  end

  def get_tree
    uri = URI("https://#{@config['vxf']['host']}:#{@config['vxf']['port'] || 443}/api/instances/")
    Net::HTTP.start(@config['vxf']['host'], @config['vxf']['port'] || 443,
      :use_ssl => uri.scheme == 'https', 
      :verify_mode => OpenSSL::SSL::VERIFY_NONE) do |http|

      request = Net::HTTP::Get.new(uri.request_uri)
      request.basic_auth('', @auth_token)

      response = http.request(request)

      if response.body.include?('Unauthorized')
        raise 'Tree request failed: maybe the token expired?'
      else
        @tree = JSON.parse(response.body)
        File.open('examples/tree.json', 'w') { |file| file.write(JSON.pretty_generate(@tree)) } if File.exists? 'examples'
      end
    end
  end

  def process_tree
    #binding.pry
  end

  def get_stats
    uri = URI("https://#{@config['vxf']['host']}:#{@config['vxf']['port'] || 443}/api/instances/querySelectedStatistics")
    header = {'Content-Type': 'application/json'}
    
    Net::HTTP.start(@config['vxf']['host'], @config['vxf']['port'] || 443,
      :use_ssl => uri.scheme == 'https', 
      :verify_mode => OpenSSL::SSL::VERIFY_NONE) do |http|

        request = Net::HTTP::Post.new(uri.request_uri, header)
        request.basic_auth('', @auth_token)
        request.body = @query.to_json

        response = http.request(request)
        if response.body.include?('Unauthorized')
          puts 'Stats request failed: maybe the token expired?'
        else
          @stats = JSON.parse(response.body)
          File.open('examples/stats.json', 'w') { |file| file.write(JSON.pretty_generate(@stats)) } if File.exists? 'examples'
        end
    end
  end

  def process_stats
    @stats.each do |type, level1|
      tags = {clu_id: @tree['System']['id'], clu_name: @tree['System']['name']}
      if type != 'System'
        level1.each do |device_id, device_stats|
          tags = {clu_id: @tree['System']['id'], clu_name: @tree['System']['name']}
          if type == 'Sdc'
            sdc = @tree['sdcList'].select{|sdc| sdc['id'] == device_id}.first
            tags.merge!({sdc_id: device_id, sdc_name: sdc['name']})
          elsif type == 'ProtectionDomain'
            protection_domain = @tree['protectionDomainList'].select{|pdo| pdo['id'] == device_id}.first
            tags.merge!({pdo_id: device_id, pdo_name: protection_domain['name']})
          elsif type == 'Sds'
            protection_domain_id = @tree['sdsList'].first{|sds| sds.id == device_id}['protectionDomainId']
            protection_domain = @tree['protectionDomainList'].select{|pdo| pdo['id'] == protection_domain_id}.first
            sds = @tree['sdsList'].select{|sds| sds['id'] == device_id}.first
            tags.merge!({pdo_id: protection_domain_id, pdo_name: protection_domain['name'], sds_id: device_id, sds_name: sds['name']})
          elsif type == 'StoragePool'
            protection_domain_id = @tree['storagePoolList'].first{|sto| sto.id == device_id}['protectionDomainId']
            protection_domain = @tree['protectionDomainList'].select{|pdo| pdo['id'] == protection_domain_id}.first
            storage_pool = @tree['storagePoolList'].select{|sto| sto['id'] == device_id}.first
            tags.merge!({pdo_id: protection_domain_id, pdo_name: protection_domain['name'], sto_id: device_id, sto_name: storage_pool['name']})
          elsif type == 'Volume'
            storage_pool_id = @tree['volumeList'].first{|vol| vol.id == device_id}['storagePoolId']
            storage_pool = @tree['storagePoolList'].select{|sto| sto['id'] == storage_pool_id}.first
            protection_domain_id = storage_pool['protectionDomainId']
            protection_domain = @tree['protectionDomainList'].select{|pdo| pdo['id'] == protection_domain_id}.first
            volume = @tree['volumeList'].select{|vol| vol['id'] == device_id}.first
            tags.merge!({pdo_id: protection_domain_id, pdo_name: protection_domain['name'], sto_id: storage_pool_id, sto_name: storage_pool['name'], vol_id: device_id, vol_name: volume['name']})
          elsif type == 'Device'
            device = @tree['deviceList'].select{|dev| dev['id'] == device_id}.first
            storage_pool_id = device['storagePoolId']
            storage_pool = @tree['storagePoolList'].select{|sto| sto['id'] == storage_pool_id}.first
            sds_id = device['sdsId']
            sds = @tree['sdsList'].select{|sds| sds['id'] == sds_id}.first
            protection_domain_id = storage_pool['protectionDomainId']
            protection_domain = @tree['protectionDomainList'].select{|pdo| pdo['id'] == protection_domain_id}.first
            tags.merge!({pdo_id: protection_domain_id, pdo_name: protection_domain['name'], sto_id: storage_pool_id, sto_name: storage_pool['name'], sds_id: sds_id, sds_name: sds['name'], dev_id: device_id, dev_name: device['name'], dev_path: device['deviceCurrentPathName']})
          elsif type == 'RfcacheDevice'
            rfdevice = @tree['rfcacheDeviceList'].select{|dev| dev['id'] == device_id}.first
            sds_id = rfdevice['sdsId']
            sds = @tree['sdsList'].select{|sds| sds['id'] == sds_id}.first
            protection_domain_id = sds['protectionDomainId']
            protection_domain = @tree['protectionDomainList'].select{|pdo| pdo['id'] == protection_domain_id}.first
            tags.merge!({pdo_id: protection_domain_id, pdo_name: protection_domain['name'], sds_id: sds_id, sds_name: sds['name'], rfdev_id: device_id, rfdev_name: rfdevice['name'], rfdev_path: rfdevice['deviceCurrentPathname']})
          end
          
          device_stats.each do |param, value|
            @stats_processed << {type: type, param: param, value: value, tags: tags}
          end
        end
      else
        level1.each do |param, value|
          @stats_processed << {type: type, param: param, value: value, tags: tags}
        end
      end
    end
  end

  def convert_kb_iops
    conv = []
    @stats_processed.each do |row|
      if row[:value].is_a?(Hash)
        conv << {type: row[:type], param: row[:param], postfix: 'iops', value: (row[:value]['numSeconds'] > 0 ? row[:value]['numOccured']/row[:value]['numSeconds'] : 0), tags: row[:tags]}
        conv << {type: row[:type], param: row[:param], postfix: 'kb', value: (row[:value]['numSeconds'] > 0 ? row[:value]['totalWeightInKb']/row[:value]['numSeconds'] : 0), tags: row[:tags]}
      else
        conv << row
      end
    end
    @stats_processed = conv
  end

  def output_stats(target)
    @stats_processed.group_by{|s| s[:type]+s[:param]+(s[:postfix] || '')}.each do |group, rows|
      param_prom_name = rows[0][:param].gsub(/(.)([A-Z])/,'\1_\2').downcase+
      path_str = ''
      if @defs[rows[0][:param]]
        param_prom_name = @defs[rows[0][:param]]['name'] if @defs[rows[0][:param]]['name']
        path_str = (@config['prom']['prefix'] || '') + rows[0][:type].downcase + '_' + param_prom_name + (rows[0][:postfix] ? '_'+rows[0][:postfix] : '')
        target.print "# HELP #{path_str} #{@defs[rows[0][:param]]['help']}" + "\r\n" if @defs[rows[0][:param]]['help']
        target.print "# TYPE #{path_str} #{@defs[rows[0][:param]]['type']}" + "\r\n" if @defs[rows[0][:param]]['type']
        @defs[rows[0][:param]]['used'] = true
      end

      rows.each do |row|
        tags_str = '{' + row[:tags].map{|t,v| t.to_s + '="' + v + '"'}.join(',') + '}'
        target.print path_str + tags_str + ' ' + row[:value].to_s + "\r\n"
      end
    end
  end
end

app = VxFlexOSExporter.new
