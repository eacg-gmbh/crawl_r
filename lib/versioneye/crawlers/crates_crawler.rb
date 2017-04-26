class CratesCrawler < Versioneye::Crawl

  API_HOST  = "https://crates.io"
  API_URL   = "https://crates.io/api/v1"

  def self.logger
    if !defined?(@@log) || @@log.nil?
      @@log = Versioneye::DynLog.new("log/crates.log", 10).log
    end
    @@log
  end

  def self.crawl(api_key)
    api_key = api_key.to_s.strip

    if api_key.empty?
      logger.error "crates api_key is not set - will stop crawler"
      return
    end

    logger.info "Going to crawl rust packages on the crates.io"
    crawl_product_list(api_key)
    logger.info "Done!"
  end


  def self.crawl_product_list(api_key, page_nr = 1, per_page = 100)
    logger.info "going to crawl product list from #{page_nr}, per_page: #{per_page}"

    n = 0
    loop do
      products = fetch_product_list(api_key, page_nr, per_page)
      if products.to_a.empty?
        logger.info "Stopping crawl_product_list after #{page_nr} due empty response"
        break
      end

      products.to_a.each do |product|
        crawl_product_details api_key, product[:id], product[:max_version]
        n += 1
      end

      page_nr += 1
    end

    logger.info "crawl_product_list: crawled #{page_nr} pages and #{n} products"
    n
  end

  def self.crawl_product_details(api_key, product_id, latest_version, ignore_existing = true)
    product_exists = Product.where(
      language: Product::A_LANGUAGE_RUST,
      prod_type: Project::A_TYPE_CRATES,
      prod_key: product_id,
      version: latest_version
    ).first

    if product_exists and ignore_existing
      logger.info "crawl_product_details: #{product_exists} has no new releases"
      return
    end

    logger.info "crawl_product_details: fetching #{product_id} - #{latest_version}"
    product_doc = fetch_product_details api_key, product_id
    if product_doc.nil?
      logger.error "crawl_product_details: Failed to fetch product details for #{product_id}"
      return
    end

    product_db = upsert_product(product_doc[:crate])
    unless product_db
      logger.error "crawl_product_details: failed to save product #{product_doc[:crate]}"
      return
    end

    product_license = product_doc[:crate][:license].to_s
    product_doc[:versions].each do |version_doc|
      version_db = upsert_version(product_db, version_doc)
      unless version_db
        logger.error "crawl_product_details: failed to save version data #{product_db} #{version_doc}"
        next
      end

      upsert_version_licenses(product_db, version_db[:version], product_license)
      upsert_product_links(product_db, version_db[:version], product_doc[:crate])
      upsert_version_archive(product_db, version_db[:version], version_doc[:dl_path])

      #create download and version_links
      crawl_version_details(api_key, product_db, version_db)
    end

    #crawl owners details
    owners = fetch_product_owners(api_key, product_db[:prod_key])
    owners.to_a.each do |owner_doc|
      upsert_product_owner(product_db, owner_doc)
    end

    logger.info "crawl_product_details: add #{product_db}"

    ProductService.update_version_data product_db
    product_db
  end

  def self.crawl_version_details(api_key, product_db, version_db)
    version = version_db[:version]
    unless version
      logger.error "crawl_version_details: product version has no version label #{product_db} #{version_db}"
      return
    end

    logger.info "crawl_version_details: fetching version details for #{product_db[:prod_key]} - #{version}"
    #crawl dependencies
    dep_docs = fetch_version_dependencies(api_key, product_db[:prod_key], version)
    dep_docs.to_a.each do |dep_doc|
      upsert_product_dependency(product_db, version_db, dep_doc)
      CrawlerUtils.create_newest(product_db, version, logger)
      CrawlerUtils.create_notifications(product_db, version, logger)
    end
  end

  #-- persistance helpers

  def self.upsert_product(product_doc)
    prod_key = product_doc[:id].to_s.strip.downcase
    product_db = Product.where(
      language: Product::A_LANGUAGE_RUST,
      prod_type: Project::A_TYPE_CRATES,
      prod_key: prod_key
    ).first_or_initialize

    product_db.update(
      name: product_doc[:id],
      name_downcase: prod_key,
      prod_key_dc: prod_key,
      version: product_doc[:max_version],
      tags: product_doc[:categories].to_a + product_doc[:keywords].to_a,
      downloads: product_doc[:downloads].to_i
    );

    product_db.save
    product_db
  end

  def self.upsert_version(product_db, version_doc)
    version_label = version_doc[:num].to_s.strip
    version_db = product_db.versions.where(version: version_label).first_or_initialize

    dt = DateTime.parse version_doc[:created_at]
    status = version_doc[:yanked] ? 'yanked' : ''
    version_db.update(
      status: status,
      released_string: version_doc[:created_at],
      released_at: dt
    )
    version_db.save
    version_db
  end

  def self.upsert_product_owner(product_db, owner_doc)
    owner_name = if owner_doc[:name].nil?
                   owner_doc[:login]
                 else
                   owner_doc[:name]
                 end
    if owner_name.nil?
      logger.warn "upsert_product_owner: no owner for #{product_db}"
      return
    end

    owner_id = Author.encode_name(owner_name)
    owner = Author.where(name_id: owner_id).first_or_initialize
    owner.update(
      name: owner_name,
      email: owner_doc[:email].to_s,
      homepage: owner_doc[:url],
      role: 'owner'
    )

    owner.save
    owner.add_product(
      product_db.id, product_db[:language], product_db[:prod_key]
    )

    owner
  end

  def self.upsert_version_licenses(product_db, version_label, license_label)
    licenses = license_label.to_s.strip.split('/')
    licenses.to_a.each do |license|
      self.upsert_version_license(product_db, version_label, license)
    end

    licenses
  end

  def self.upsert_version_license(product_db, version_label, license_name)
    license_name = license_name.to_s.strip

    lic_db = License.where(
      language: product_db[:language],
      prod_key: product_db[:prod_key],
      version: version_label,
      name: license_name
    ).first_or_create

    lic_db.update(source: 'crates')
    lic_db.save

    lic_db
  end

  def self.upsert_product_dependency(product_db, version_id, dep_doc)
    dep_db = Dependency.where(
      language: product_db[:language],
      prod_key: product_db[:prod_key],
      prod_version: version_id,
      dep_prod_key: dep_doc[:crate_id],
    ).first_or_create

    scope = if dep_doc[:optional]
              Dependency::A_SCOPE_OPTIONAL
            elsif dep_doc[:target] == 'test'
              Dependency::A_SCOPE_TEST
            else
              Dependency::A_SCOPE_COMPILE
            end

    dep_db.update(
      prod_type: product_db[:prod_type],
      version: dep_doc[:req],
      name: dep_doc[:crate_id],
      scope: scope
    )

    dep_db
  end

  def self.upsert_product_links(product_db, version_id, product_doc)
    links = []
    links << upsert_version_link(product_db, version_id, "homepage", product_doc[:homepage])
    links << upsert_version_link(product_db, version_id, "documentation", product_doc[:documentation])
    links << upsert_version_link(product_db, version_id, "repo", product_doc[:repository])

    #link to Crates page
    crates_url = "#{API_HOST}/#{product_db[:prod_key]}/#{version_id}"
    links << upsert_version_link(product_db, version_id, "Crates", crates_url)

    links
  end

  def self.upsert_version_link(product_db, version_id, name, url)
    url_db = Versionlink.where(
      language: product_db[:language],
      prod_key: product_db[:prod_key],
      version_id: version_id,
      name: name
    ).first_or_create

    url_db.update(link: url)
    url_db.save
    url_db
  end

  def self.upsert_version_archive(product_db, version_id, dl_path)
    pkg_name = "#{product_db[:prod_key]}-#{version_id}.crate"
    url = "#{API_HOST}/#{dl_path}"

    url_db = Versionarchive.where(
      language: product_db[:language],
      prod_key: product_db[:prod_key],
      version_id: version_id,
      name: pkg_name
    ).first_or_create

    url_db.update(link: url)
    url_db.save
    url_db
  end

  #-- functions that fetch data over internet
  #origins of the urls
  #https://github.com/rust-lang/crates.io/blob/master/src/lib.rs
  def self.fetch_product_list(api_key, page_nr, per_page = 100)
    resource_url = "#{API_URL}/crates?page=#{page_nr.to_i}&per_page=#{per_page}&api_key=#{api_key}"
    res = fetch_json resource_url
    res[:crates].to_a if res
  end

  def self.fetch_product_details(api_key, product_id)
    resource_url = "#{API_URL}/crates/#{product_id}?api_key=#{api_key}"
    fetch_json resource_url
  end

  def self.fetch_product_owners(api_key, product_id)
    resource_url = "#{API_URL}/crates/#{product_id}/owners?api_key=#{api_key}"
    res = fetch_json resource_url
    res[:users] if res
  end

  def self.fetch_version_dependencies(api_key, product_id, version)
    resource_url = "#{API_URL}/crates/#{product_id}/#{version}/dependencies"
    res = fetch_json resource_url
    res[:dependencies].to_a if res
  end

end