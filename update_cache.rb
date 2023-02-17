#! /usr/bin/env ruby
require 'fileutils'
require 'pathname'
require 'json'
require 'nokogiri'
require 'open-uri'

class Catalog
  attr_accessor :content

  def load
    self.content = if File.exist?(file_path)
      JSON.load file_path
    else
      FileUtils.mkdir_p File.dirname(file_path)
      {}
    end
    self
  end

  def save
    File.write(file_path, JSON.pretty_generate(content))
  end

  def export_product_table
    File.write(product_table_path, JSON.pretty_generate(products.values))
  end

  def base_folder
    @base_folder ||= Pathname.new(File.dirname(__FILE__)).join('cache')
  end

  def product_table_path
    @product_table_path ||= base_folder.join('product_table.json')
  end

  def file_path
    @file_path ||= base_folder.join('catalog.json')
  end

  def image_folder
    @image_folder ||= begin
      path = base_folder.join('images')
      FileUtils.mkdir_p(path) unless File.exist?(path)
      path
    end
  end

  def image_path(filename, original_path)
    extension = original_path.split('.').last
    image_folder.join([filename, extension].join('.'))
  end

  def product_metadata
    content['product_metadata'] ||= {}
  end

  def product_metadata=(value)
    content['product_metadata'] = value
  end

  def products
    content['products'] ||= {}
  end
end

class Scraper
  BACKOFF_SECONDS = ENV.fetch('BACKOFF_SECONDS', 0.3).to_f
  BASE_URL = 'http://www.trumpeter-china.com'.freeze
  INDEX_URL = '/index.php?l=en'.freeze
  CATEGORY_NAMES = %w[Armor Buildings Car Plane Ship Other Tools].freeze
  PRODUCT_TWEAKS = {
    '02063' => { 'scale' => '1:35'},
    '06240' => { 'scale' => '1:350'},
    '06647' => { 'scale' => '1:350'},
    '06729' => { 'scale' => '1:700'}
  }.freeze

  def show_scales
    scales = catalog.products.values.each_with_object({}) do |product, memo|
      scale = product['scale'] || ''
      memo[scale] ||= 0
      memo[scale] += 1
    end
    scales.keys.sort.each do |scale|
      puts "#{scale}: #{scales[scale]} products"
    end
  end

  def ensure_cache_complete
    load_product_metadata
    load_products
    save
    cache_product_images
  end

  def catalog
    @catalog ||= Catalog.new.load
  end

  def save
    catalog.save
    catalog.export_product_table
  end

  def load_product_metadata(refresh: false)
    product_metadata(refresh: refresh)
    log 'Load Product Pages', 'loaded'
  end

  def product_metadata(refresh: false)
    return unless refresh || catalog.product_metadata.empty?

    result = {}
    result['products_url'] = index_doc.css('.solidblockmenu').css('a').detect { |a| a.text == 'Product' }.attr('href')
    product_doc = get_page(result['products_url'], message: 'GET main product page')

    CATEGORY_NAMES.each do |category_name|
      url = product_doc.css('ul.menu h4').css('a').detect { |a| a.text == category_name }.attr('href')
      category_doc = get_page(url, message: "GET #{category_name} product page")
      last_page_url = category_doc.css('.pages a').last.attr('href') rescue nil
      pages = last_page_url ? last_page_url.split('p=').last.to_i : 1
      result[category_name] = {
        'url' => url,
        'last_page_url' => last_page_url,
        'pages' => pages
      }
      log "Product #{category_name} metadata", result[category_name].to_s
      if refresh
        log "Refreshing/replacing Product #{category_name} curent metadata", catalog.product_metadata[category_name].to_s
        catalog.product_metadata[category_name] = result[category_name]
      end
    end
    result
  end

  def product_category(category_name)
    category_metadata = catalog.product_metadata[category_name]
    category_url = category_metadata['url']
    category_metadata['pages'].times.each do |i|
      page = i + 1
      page_url = page == 1 ? category_url : "#{category_url}&p=#{page}"
      page_doc = get_page(page_url, message: "#{category_name} Page #{page}")

      page_doc.css('ul#products dl').each do |product|
        product_data = {}
        product_data['category'] = category_name
        product_data['url'] = product.css('a').first.attr('href')
        product_data['image_url'] = product.css('img').first.attr('src')
        product_data['code'] = product.css('dd')[0].css('a').first.text
        product_data['name'] = product.css('dd')[1].css('a').first.text
        product_data['code'] = product_data['name'].split(' ').last if product_data['code'].empty?
        product_data['name'] = product_data['name'].gsub(" #{product_data['code']}", '').strip
        product_data['scale'] = PRODUCT_TWEAKS.fetch(product_data['code'], {})['scale']
        product_data['scale'] ||= product.css('dd')[2].css('a').first.text.gsub('/', ':').gsub('：', ':')
        log "Load #{category_name} Products", "#{product_data['code']} #{product_data['scale']} #{product_data['name']}"
        catalog.products[product_data['code']] = product_data
      end
    end
    log "Load #{category_name} Products", 'loaded'
  end

  def load_products(refresh: false)
    if refresh || catalog.products.empty?
      CATEGORY_NAMES.each do |category_name|
        product_category(category_name)
      end
    end
    log 'Load Products', 'loaded'
  end

  def cache_product_images
    catalog.products.keys.each do |code|
      product_data = catalog.products[code]
      image_url = product_data['image_url']
      filename = catalog.image_path(code, image_url)
      log 'Load Product Image', "loading #{filename} with a #{BACKOFF_SECONDS} second grace period delay"

      unless File.exist?(filename)
        open(filename, 'wb') do |file|
          file << URI.open(URI.parse(BASE_URL + image_url)).read
        end
        sleep BACKOFF_SECONDS
      end
    end
  end

  def index_doc
    @index_doc ||= get_page(INDEX_URL, message: 'GET main page (en)')
  end

  def get_page(relative_url, message: nil)
    url = BASE_URL + relative_url
    log message, "loading #{url} with a #{BACKOFF_SECONDS} second grace period delay"
    html = URI.open(URI.parse(url))
    result = Nokogiri::HTML(html)
    sleep BACKOFF_SECONDS
    result
  end

  def log(category, message)
    warn "[#{category}][#{Time.now}] #{message}"
  end
end

if __FILE__ == $PROGRAM_NAME
  operation = ARGV.shift
  scraper = Scraper.new
  case operation
  when 'show_scales'
    scraper.show_scales
  when 'refresh_metadata'
    scraper.load_product_metadata refresh: true
    scraper.save
  when 'refresh_products'
    scraper.load_products refresh: true
    scraper.save
  when 'refresh_category'
    scraper.product_category ARGV.shift
    scraper.save
  when nil
    scraper.ensure_cache_complete
  else
    warn <<-HELP
      Usage:
        ruby #{$PROGRAM_NAME} show_scales                      # list all the scales referenced in the catalog
        ruby #{$PROGRAM_NAME} refresh_metadata                 # update the product metadata
        ruby #{$PROGRAM_NAME} refresh_products                 # update all the product
        ruby #{$PROGRAM_NAME} refresh_category <category_name> # update products for specific category (#{Scraper::CATEGORY_NAMES.join(', ')})
        ruby #{$PROGRAM_NAME} help                             # this help
        ruby #{$PROGRAM_NAME}                                  # checks/updates cache

      Environment settings:
        BACKOFF_SECONDS # override the default backoff delay 0.3 seconds
    HELP
  end
end
