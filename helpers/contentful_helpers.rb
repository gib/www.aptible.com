require 'contentful'

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

module ContentfulHelpers
  MARKDOWN_PROCESSORS = {
    'customer' => lambda do |yml|
      quotes = []
      case_study = {}

      if yml.key? :quotes
        yml[:quotes].each do |quote|
          q = {
            'quote' => quote[:quote],
            'type' => 'quote',
            'approved' => quote[:approved],
            'author' => quote[:author],
            'position' => quote[:position]
          }
          q['card_image'] = yml[:logo][:url] if yml.key? :logo
          q['author_image'] = quote[:image][:url] if quote.key? :image

          quotes << q
        end
      end

      if yml.key? :case_study
        case_study = {
          'title' => yml[:case_study][:title],
          'summary' => yml[:case_study][:summary],
          'type' => 'case_study',
          'approved' => yml[:case_study][:approved],
          'path' => yml[:case_study][:path]
        }
        if yml[:case_study].key? :card_image
          case_study['card_image'] = yml[:case_study][:card_image][:url]
        end
      end

      customer = {
        'name' => yml[:name],
        'slug' => yml[:slug],
        'include_in_logo_bar' => yml[:include_in_logo_bar],
        'quotes' => quotes,
        'case_study' => case_study
      }
      customer['logo'] = yml[:logo][:url] if yml.key? :logo

      [customer]
    end,
    'blogPost' => lambda do |yml|
      [{
        markdown_path: "source/#{blog_post_dir(yml)}/#{yml[:slug]}.md",
        markdown: yml[:body],
        frontmatter: {
          'title' => yml[:title],
          'excerpt' => yml[:excerpt],
          'author_name' => yml[:author][:name],
          'author_email' => yml[:author][:email],
          'author_id' => yml[:author][:slug],
          'posted' => Time.parse(yml[:posted]).to_date,
          'product' => yml[:product],
          'section' => 'Blog',
          'type' => yml[:type],
          'hackernews_link' => yml[:hackernews_link],
          'show_body_in_index' => yml[:show_body_in_index]
        }
      }]
    end,
    'resourcePage' => lambda do |yml|
      main = {
        markdown_path: "source/#{yml[:subfolder]}/#{yml[:slug]}.md",
        markdown: yml[:content],
        frontmatter: {
          'category' => yml[:category],
          'cover_image' => yml[:cover_image],
          'created_at' => Time.parse(yml[:date]).to_datetime,
          'description' => yml[:meta_description] || yml[:snippet],
          'documents' => yml[:documents],
          'excerpt' => yml[:snippet],
          'featured' => yml[:featured],
          'hackernews_link' => yml[:hackernews_link],
          'included_on_index' => yml[:included_on_index],
          'included_in_footer' => yml[:included_in_footer],
          'footer_position' => yml[:footer_position],
          'layout' => 'resource',
          'section' => 'Resources',
          'slug' => yml[:slug],
          'subfolder' => yml[:subfolder],
          'title' => yml[:title],
          'type' => yml[:type],
          'webinar_slides_link' => yml[:webinar_slides_link],
          'webinar_video_link' => yml[:webinar_video_link],
          'webinar_transcript_partial' => nil
        }
      }

      return [main] unless yml[:webinar_transcript]

      main[:frontmatter]['webinar_transcript_partial'] =
        "#{yml[:subfolder]}/#{yml[:slug]}-transcript"

      transcript = {
        markdown_path: "source/#{yml[:subfolder]}/_#{yml[:slug]}-transcript.md",
        markdown: "#{yml[:webinar_transcript]}\n#{yml[:webinar_transcript2]}"
      }
      [main, transcript]
    end
  }.freeze

  def self.populate!
    filelist = []
    Dir.mktmpdir do |dir|
      fetch_yaml_files!(dir)
      failures = 0
      MARKDOWN_PROCESSORS.keys.each do |type|
        if type == 'customer'
          failures += generate_customer_data_file(dir)
        else
          Dir.glob(File.join(dir, "#{type}/*.yml")).each do |yaml_file|
            yaml = File.read(yaml_file)

            begin
              map = markdown_map(type, yaml)
            rescue => e
              puts "WARN: Failed to parse #{File.basename(yaml_file)}"
              ([e.message] + e.backtrace).each { |l| puts "WARN:   #{l}" }
              failures += 1
              next
            end

            map.each do |path, markdown|
              dest = File.expand_path("../#{path}", File.dirname(__FILE__))
              filelist << dest
              next if File.exist?(dest) && markdown == File.read(dest)
              puts "INFO: Updating #{dest}"
              File.open(dest, 'w') { |file| file << markdown }
            end
          end
        end
      end
      raise "Failed on #{failures} files" if failures > 0
    end

    # If ENV['CONTENTFUL_PRUNE_ON_POPULATE'] is set, prune local Markdown
    # files previously pulled from Contentful with no matching resource
    return unless prune_on_populate?
    (local_contentful_filenames - filelist).each do |dest|
      puts "INFO: Pruning #{dest}"
      FileUtils.rm(dest)
    end
  end

  def self.local_contentful_filenames
    pattern = '../source/**/*.md'
    all = Dir.glob(File.expand_path(pattern, File.dirname(__FILE__)))
    all.select { |f| File.read(f).lines.grep(/^contentful: true$/).any? }
  end

  def self.fetch_yaml_files!(tempdir)
    client.sync(initial: true).each_page do |page|
      page.items.each do |item|
        next unless item.respond_to?(:content_type) && item.content_type
        next unless MARKDOWN_PROCESSORS.keys.include?(item.content_type.id)

        hash = hashify_contentful_entry(item)
        yaml_file = File.join(tempdir, item.content_type.id, "#{item.id}.yml")
        FileUtils.mkdir_p(File.dirname(yaml_file))
        File.open(yaml_file, 'w') do |file|
          file << hash.to_yaml
        end
      end
    end
  end

  def self.hashify_contentful_entry(item)
    if item.is_a?(Contentful::Asset)
      { title: item.title, description: item.description, url: item.url }
    elsif item.is_a?(Contentful::Link)
      hashify_contentful_entry(item.resolve(client))
    elsif item.respond_to?(:fields)
      hashify_contentful_entry(item.fields.dup)
    elsif item.is_a?(Array)
      item.map { |i| hashify_contentful_entry(i) }
    elsif item.is_a?(Hash)
      item.each { |k, v| item[k] = hashify_contentful_entry(v) }
    else
      item
    end
  end

  # Returns a hash of Markdown filenames to Markdown strings
  def self.markdown_map(type, yaml_string)
    Hash[MARKDOWN_PROCESSORS[type].call(YAML.load(yaml_string)).map do |hash|
      markdown = ''
      frontmatter = { 'contentful' => true }
      frontmatter.merge!(hash[:frontmatter] || {})
      markdown << frontmatter.to_yaml.gsub(/ *$/, '')
      markdown << "---\n\n"
      markdown << hash[:markdown]

      [hash[:markdown_path], markdown]
    end]
  end

  def self.generate_customer_data_file(dir)
    failures = 0
    customers_data = {
      'contentful' => true,
      'customers' => []
    }
    # Each contentful customer
    Dir.glob(File.join(dir, 'customer/*.yml')).each do |yaml_file|
      yaml = File.read(yaml_file)
      begin
        MARKDOWN_PROCESSORS['customer'].call(YAML.load(yaml)).map do |hash|
          customers_data['customers'] << hash
        end
      rescue => e
        puts "WARN: Failed to parse #{File.basename(yaml_file)}"
        ([e.message] + e.backtrace).each { |l| puts "WARN:   #{l}" }
        failures += 1
        next
      end
    end
    File.open('data/customers.yml', 'w') do |file|
      puts 'INFO: Updating data/customers.yml'
      file << customers_data.to_yaml.gsub(/ *$/, '')
    end
    failures
  end

  def self.access_token
    ENV['CONTENTFUL_TOKEN'] ||
      '9f900421de36456577e619e3fbf7f0870954b64ad8f0ead9f3d80f55ceaf4bee'
  end

  def self.api_host
    preview_mode? ? 'preview.contentful.com' : 'cdn.contentful.com'
  end

  def self.preview_mode?
    !!ENV['CONTENTFUL_PREVIEW_MODE']
  end

  def self.space_id
    ENV['CONTENTFUL_SPACE_ID'] || '8djp5jlzqrnc'
  end

  def self.prune_on_populate?
    !!ENV['CONTENTFUL_PRUNE_ON_POPULATE']
  end

  def self.client
    Contentful::Client.new(access_token: access_token,
                           space: space_id,
                           api_url: api_host,
                           default_locale: 'en-US')
  end

  def self.blog_post_dir(yml)
    changelog_types = ['changelog post', 'upcoming feature']
    return 'changelog' if changelog_types.include?(yml[:type])
    'blog'
  end
end
