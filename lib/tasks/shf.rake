require 'active_support/logger'


namespace :shf do

  ACCEPTED_STATUS = 'Godkänd'

  desc 'recreate db (current env): drop, setup, migrate, seed the db.'
  task :db_recreate => [:environment] do
    tasks = ['db:drop', 'db:setup', 'db:migrate', 'db:seed']
    tasks.each { |t| Rake::Task["#{t}"].invoke }
  end


  # This will associate ALL membership_applications
  #   where status == '#{ACCEPTED_STATUS}' in the DB with their companies.
  # It will set the membership_application.company_id
  # It will OVERWRITE the existing membership_application.company_id
  # Use this in case you don't want to import again and you need to
  # fix the imported data.
  desc 'connect membership to company'
  task :connect_membership_to_company => [:environment] do

    logfile = 'log/import.log'
    start_time = Time.now
    log = start_logging(start_time, logfile)

    num_connected = 0

    MembershipApplication.where(status:ACCEPTED_STATUS).find_each do |mem_app|
      if (connected_co = Company.find_by_company_number(mem_app.company_number))
        mem_app.company = connected_co
        mem_app.save
        log_and_show log, Logger::INFO, "membership_app.id #{mem_app.id} now connected to company_id #{mem_app.company_id} (company number: #{connected_co.company_number})"
        num_connected += 1
      end
    end

    log_and_show log, Logger::INFO, "\nFinished connecting #{num_connected} membership applications to companies, where membership_application.status == #{ACCEPTED_STATUS}."
    log_and_show log, Logger::INFO, "Information was logged to: #{logfile}"
    finish_and_close_log(log, start_time, Time.now)
  end


  desc "import membership apps from csv file. Provide the full filename (with path)"
  task :import_membership_apps, [:csv_filename] => [:environment] do |t, args|

    require 'csv'
    require 'smarter_csv'

    usage = 'rake shf:import_membership_apps["./spec/fixtures/test-import-files/member-companies-sanitized-small.csv"]'

    DEFAULT_PASSWORD = 'whatever'

    headers_to_columns_mapping = {
        membership_number: :membership_number,
        email: :email,
        company_number: :company_number,
        first_name: :first_name,
        last_name: :last_name,
        company_name: :company_name,
        street: :street,
        post_code: :post_code,
        stad: :city,
        region: :region,
        phone_number: :phone_number,
        website: :website,
        category1: :category1,
        category2: :category2
    }

    csv_options = {
        col_sep: ';',
        headers_in_file: true,
        remove_empty_values: false,
        remove_zero_values: false,
        file_encoding: 'UTF-8',
        key_mapping: headers_to_columns_mapping
    }

    logfile = 'log/import.log'
    start_time = Time.now
    log = start_logging(start_time, logfile)

    if args.has_key? :csv_filename

      if File.exist? args[:csv_filename]

        csv = SmarterCSV.process(args[:csv_filename], csv_options)
        #csv = CSV.parse(csv_text, :headers => true, :encoding => 'ISO-8859-1')

        num_read = 0
        error_rows = 0
        csv.each do |row|
          begin
            import_a_member_app_csv(row, log)
            num_read += 1
          rescue ActiveRecord::RecordInvalid => invalid_info
            error_rows += 1
            log_and_show(log, Logger::ERROR, "#{invalid_info.record.errors.full_messages.join(", ")}")
          end
        end

        log_and_show log, Logger::INFO, "\nFinished.  Read #{num_read + error_rows} rows.\n  #{num_read} were valid and their information was imported.\n  #{error_rows} had errors."

      else
        log_file_doesnt_exist_and_close(log, args[:csv_filename], start_time)
        finish_and_close_log(log, start_time, Time.now)
        raise LoadError
      end

    else
      log_must_provide_filename_and_close(log, usage, start_time)
      raise "ERROR: You must specify a .csv filename to import. Ex: #{usage}"
    end

    log_and_show log, Logger::INFO, "Information was logged to: #{logfile}"
    finish_and_close_log(log, start_time, Time.now)
  end

  desc "load regions data (counties plus 'Sweden' and 'Online')"
  task :load_regions => [:environment] do

    logfile = 'log/shf-rake.log'
    start_time = Time.now
    log = start_logging(start_time, logfile, "Regions create")

    # Populate the 'regions' table for Swedish regions (aka counties),
    # as well as 'Sweden' and 'Online'.  This is used to specify the primary
    # region in which a company operates.
    #
    # This uses the 'city-state' gem for a list of regions (name and ISO code).

    if Region.exists?
      log_and_show log, Logger::WARN, "Regions table not empty"
    else
      CS.states(:se).each_pair { |k,v| Region.create(name: v, code: k.to_s) }
      Region.create(name: 'Sweden', code: nil)
      Region.create(name: 'Online', code: nil)

      log_and_show log, Logger::INFO, "Regions created"
    end

    # Create company reference to region using 'old_region'
    num_companies = 0
    Company.all.each do |cmpy|
      next if cmpy.region
      region = Region.where(name: cmpy.old_region)[0]
      if region
        cmpy.region = region
        cmpy.save
        num_companies += 1
      else
        log_and_show log, Logger::INFO, "No region match for company : #{cmpy.name}"
      end
    end
    log_and_show log, Logger::INFO, "#{num_companies} companies " \
                                    "converted to region reference"

    log_and_show log, Logger::INFO, "Information was logged to: #{logfile}"
    finish_and_close_log(log, start_time, Time.now, "Regions create")
  end

  def import_a_member_app_csv(row, log)

    log_and_show log, Logger::INFO, "Importing row: #{row.inspect}"

    if (user = User.find_by(email: row[:email]))
      puts_already_exists 'User', row[:email]
    else
      user = User.create!(email: row[:email], password: DEFAULT_PASSWORD)
      puts_created 'User', row[:email]
    end

    company = find_or_create_company(row[:company_number], user.email,
                                     name: row[:company_name],
                                     street: row[:street],
                                     post_code: row[:post_code],
                                     city: row[:city],
                                     region: row[:region],
                                     phone_number: row[:phone_number],
                                     website: row[:website])

    if (membership = MembershipApplication.find_by(user: user.id))
      puts_already_exists('Membership application', " org number: #{row[:company_number]}, status: #{row[:status]}")
    else
      membership = MembershipApplication.create!(company_number: row[:company_number],
                                                 first_name: row[:first_name],
                                                 last_name: row[:last_name],
                                                 contact_email: user.email,
                                                 status: ACCEPTED_STATUS,
                                                 membership_number: row[:membership_number],
                                                 user: user,
                                                 company: company
      )

      puts_created('Membership application', " org number: #{row[:company_number]}, status: #{row[:status]}")

    end


    membership = find_or_create_category( row[:category1], membership) unless row[:category1].nil?
    membership = find_or_create_category( row[:category2], membership) unless row[:category2].nil?
    membership.save!

    if membership.status == ACCEPTED_STATUS
      membership.company = company
      user.is_member = true
      user.save!
    end

  end


  def find_or_create_category(category_name, membership)
    category = BusinessCategory.find_by_name(category_name)
    if category
      puts_already_exists 'Category', "#{category_name}"
    else
      category = BusinessCategory.create!(name: category_name)
      puts_created 'Category', "#{category_name}"
    end
    membership.business_categories << category
    membership
  end


  def find_or_create_company(company_num, email,
                             name:,
                             street:,
                             post_code:,
                             city:,
                             region:,
                             phone_number:,
                             website:)

    company = Company.find_by_company_number(company_num)
    if company
      puts_already_exists 'Company', "#{company_num}"
    else
      Company.create!(company_number: company_num,
                      email: email,
                      name: name,
                      street: street,
                      post_code: post_code,
                      city: city,
                      region: region,
                      phone_number: phone_number,
                      website: website)

      company = Company.find_by_company_number(company_num)
      puts_created 'Company', company.company_number
    end
    company
  end


  def start_logging(start_time = Time.now,
                    log_fn = 'log/import.log',
                    action = "Import")
    log = ActiveSupport::Logger.new(log_fn)
    log_and_show log, Logger::INFO, "#{action} started at #{start_time}"
    log
  end


# Severity label for logging (max 5 chars).
  LOG_LEVEL_LABEL = %w(DEBUG INFO WARN ERROR FATAL ANY).each(&:freeze).freeze


  def log_level_text(log_level)
    LOG_LEVEL_LABEL[log_level] || 'ANY'
  end


  def log_and_show(log, log_level, message)
    log.add log_level, message
    puts "#{log_level_text(log_level)}: #{message}"
  end


  def log_file_doesnt_exist_and_close(log, filename, start_time, end_time=Time.now)
    log_and_show log, Logger::ERROR, "#{filename} does not exist. Nothing imported"
    finish_and_close_log(log, start_time, end_time)
  end


  def log_must_provide_filename_and_close(log, usage_example, start_time, end_time=Time.now)
    log_and_show(log, Logger::ERROR, "You must specify a .csv filename to import.\n  Ex: #{usage_example}")
    finish_and_close_log(log, start_time, end_time)
  end


  def finish_and_close_log(log, start_time, end_time, action = "Import")
    duration = (start_time - end_time) / 1.minute
    log_and_show log, Logger::INFO, "#{action} finished at #{start_time}."
    log.close
    log
  end


  def puts_created(item_type, item_name)
    puts " #{item_type} created and saved: #{item_name}"
  end


  def puts_already_exists(item_type, item_name)
    puts " #{item_type} already exists: #{item_name}"
  end


  def puts_error_creating(item_type, item_name)
    puts " ERROR: Could not create #{item_type} #{item_name}.  Skipped"
  end


end
