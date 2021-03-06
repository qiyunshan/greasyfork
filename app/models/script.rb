require 'localizing_model'

class Script < ActiveRecord::Base
  include LocalizingModel

  belongs_to :promoted_script, class_name: 'Script', optional: true

  has_many :authors, -> { order(:id) }, dependent: :destroy, inverse_of: :script
  has_many :users, through: :authors
  has_many :script_versions, dependent: :destroy
  has_many :script_applies_tos, dependent: :destroy, autosave: true
  has_many :site_applications, through: :script_applies_tos
  has_many :discussions, -> { readonly.order(Arel.sql('COALESCE(DateLastComment, DateInserted)')).where('Closed = 0') }, class_name: 'ForumDiscussion', foreign_key: 'ScriptID'
  has_many :script_set_script_inclusions, foreign_key: 'child_id', dependent: :destroy
  has_many :favorited_in_sets, -> { includes(:users).where('favorite = true') }, through: :script_set_script_inclusions, class_name: 'ScriptSet', source: 'parent'
  has_many :favoriters, through: :favorited_in_sets, class_name: 'User', source: 'user'
  has_many :localized_attributes, class_name: 'LocalizedScriptAttribute', autosave: true, dependent: :destroy
  has_many :localized_names, -> { where(attribute_key: 'name') }, class_name: 'LocalizedScriptAttribute'
  has_many :localized_descriptions, -> { where(attribute_key: 'description') }, class_name: 'LocalizedScriptAttribute'
  has_many :localized_additional_infos, -> { where(attribute_key: 'additional_info') }, class_name: 'LocalizedScriptAttribute'
  has_many :compatibilities, autosave: true, dependent: :destroy
  has_many :script_reports, inverse_of: :script
  has_many :script_invitations
  has_many :script_similarities

  belongs_to :script_type
  belongs_to :script_sync_source, optional: true
  belongs_to :script_sync_type, optional: true
  belongs_to :script_delete_type, optional: true
  belongs_to :license, optional: true
  belongs_to :locale
  belongs_to :replaced_by_script, class_name: 'Script', optional: true

  attr_accessor :adult_content_self_report, :not_adult_content_self_report

  delegate :meta, to: :newest_saved_script_version

  scope :not_deleted, -> { where(script_delete_type_id: nil) }
  scope :active, lambda { |script_subset|
    f = not_deleted
    case script_subset
    when :greasyfork
      f.where(sensitive: false)
    when :sleazyfork
      f.where(sensitive: true)
    when :all
      f
    else
      raise ArgumentError, "Invalid argument #{script_subset}"
    end
  }
  scope :listable, ->(script_subset) { active(script_subset).where(script_type_id: 1).where.not(review_state: 'required') }
  scope :libraries, ->(script_subset) { active(script_subset).where(script_type_id: ScriptType::LIBRARY_TYPE_ID) }
  scope :listable_including_libraries, ->(script_subset) { active(script_subset).where(script_type_id: [1, 3]) }
  scope :reported, -> { not_deleted.joins(:script_reports).where(script_reports: { result: nil }).distinct }
  scope :reported_not_adult, -> { not_deleted.includes(:users).where('not_adult_content_self_report_date IS NOT NULL') }
  scope :requested_permanent_deletion, -> { where('permanent_deletion_request_date is not null') }
  scope :for_all_sites, -> { includes(:script_applies_tos).references(:script_applies_tos).where('script_applies_tos.id IS NULL') }

  # Must have a default name and description
  validates_presence_of :default_name, message: :script_missing_name, unless: proc { |s| s.library? }
  validates :name, presence: true, if: ->(s) { s.library? }
  validates_presence_of :description, message: :script_missing_description, unless: proc { |r| r.deleted? || r.library? }
  validates_presence_of :description, unless: proc { |r| r.deleted? || !r.library? }
  validates :language, presence: true, inclusion: %w[js css]

  validate do |script|
    next unless script.library?

    errors.add(:name, :taken) if Script.where.not(id: script.id).where(default_name: script.name).any?
  end

  RATE_LIMITS = {
    1.hour => 5,
    1.day => 10,
  }.freeze

  validate on: :create do |script|
    next if Rails.env.test?

    errors.add(:base, :script_rate_limit) if RATE_LIMITS.any? { |period, count| script.users.map { |u| u.scripts.where(['created_at > ?', period.ago]).count }.sum >= count }
  end

  MAX_LENGTHS = { name: 100, description: 500, additional_info: 50_000 }.freeze
  validates_each(*MAX_LENGTHS.keys) do |script, attr, _|
    len = MAX_LENGTHS[attr]
    script.localized_attributes_for(attr)
          .reject { |la| la.attribute_value.nil? }
          .select { |la| la.attribute_value.length > len }
          .each do |la|
      # use @meta if this came from a meta
      validation_key = if [:name, :description].include?(attr) && !script.library?
                         la.localized_meta_key
                       else
                         attr
                       end
      script.errors[validation_key] << I18n.t('errors.messages.too_long', { count: len })
    end
  end

  # Every locale that provides a name must have a description that's different than the name
  validate do |script|
    localized_names = script.localized_attributes_for('name')
    localized_descriptions = script.localized_attributes_for('description')
    localized_names.each do |ln|
      matching_description = localized_descriptions.select { |ld| ld.locale == ln.locale }.first
      validation_key = script.library? ? :description : LocalizedScriptAttribute.localized_meta_key(:description, ln.locale, false)
      if matching_description.nil?
        script.errors.add(validation_key, I18n.t('errors.messages.blank'))
      elsif matching_description.attribute_value == ln.attribute_value
        script.errors.add(validation_key, I18n.t('errors.messages.script_name_same_as_description'))
      end
    end
  end

  validates_each :localized_attributes do |s, attr, children|
    s.errors[attr].clear
    children.each do |child|
      child.errors.keys.each { |key| s.errors[attr.to_s + '.' + key.to_s].clear }
      next if child.marked_for_destruction? || child.valid?

      child.errors.each do |child_attr, msg|
        s.errors[:base] << I18n.t('activerecord.attributes.script.' + child.attribute_key) + ' - ' + I18n.t('activerecord.attributes.script.' + child_attr.to_s, default: child_attr.to_s) + ' ' + msg
      end
    end
  end

  validates_presence_of :code_updated_at, :script_type

  validates_format_of :sync_identifier, with: URI.regexp(%w[http https]), message: :script_sync_identifier_bad_protocol, if: proc { |r| r.script_sync_source_id == 1 }

  validates_length_of :sync_identifier, maximum: 500

  # Private use area unicode
  validates_each :name, :description, :additional_info do |script, attr, value|
    script.errors.add(attr, :invalid) if /[\u{e000}-\u{f8ff}\u{f0000}-\u{fffff}\u{100000}-\u{10ffff}]/.match?(value)
  end

  strip_attributes only: [:sync_identifier]

  before_validation :set_default_name
  def set_default_name
    self.default_name = default_localized_value_for('name')
    true
  end

  before_validation :set_locale
  def set_locale
    return unless locale.nil?

    # Try to avoid doing this for something that will be invalid anyway.
    # The API is limited.
    return unless description.present?

    self.locale = detect_locale
    localized_attributes.select { |la| la.locale.nil? }.each { |la| la.locale = locale }
    true
  end

  # If the locale has changed, update the default localized attributes' locale
  before_validation :update_localized_attribute_locales
  def update_localized_attribute_locales
    return unless locale_id_changed?

    localized_attributes.select(&:attribute_default).each { |la| la.locale = locale }
  end

  before_validation :set_sensitive_flag
  def set_sensitive_flag
    self.sensitive ||= (adult_content_self_report || for_sensitive_site?)
    true
  end

  def matching_sensitive_sites
    SensitiveSite.where(domain: site_applications.where(domain: true).pluck(:text))
  end

  def for_sensitive_site?
    return matching_sensitive_sites.any?
  end

  before_destroy do |script|
    %w[install_counts daily_install_counts update_check_counts daily_update_check_counts].each do |table|
      script.class.connection.execute "DELETE FROM #{table} WHERE script_id = #{script.id}"
    end
  end

  after_save do |script|
    ScriptDuplicateCheckerJob.perform_later(script.id) if script.saved_change_to_code_updated_at?
  end

  before_save do |script|
    if script.deleted?
      script.deleted_at ||= Time.now
    else
      script.deleted_at = nil
    end
  end

  def apply_from_script_version(script_version)
    # Copy additional_info from script versions. Retain syncing info.
    original_script_las = localized_attributes_for('additional_info').to_a
    # Try to retain the records - search by locale
    script_version.localized_attributes_for('additional_info').each do |la|
      matching_osla = original_script_las.find { |osla| osla.locale_id == la.locale_id }
      if matching_osla.nil?
        # New
        build_localized_attribute(la)
      else
        matching_osla.value_markup = la.value_markup
        matching_osla.attribute_value = la.attribute_value
        # We've found this one, don't search for it any more.
        original_script_las.delete(matching_osla)
      end
    end
    # Delete any that are gone
    original_script_las.each(&:mark_for_destruction)

    meta = script_version.parser_class.parse_meta(script_version.rewritten_code)

    # Don't use meta @name or @description for existing libraries - we are showing text boxes for that.
    %w[name description].each { |key| update_localized_attribute(meta, key) } unless library? && !new_record?

    localized_attributes_for('description').select { |la| la.attribute_value.length > MAX_LENGTHS[:description] }.each { |la| la.attribute_value = la.attribute_value[0, MAX_LENGTHS[:description]] } if script_version.truncate_description

    applies_to_names = script_version.calculate_applies_to_names
    applies_to_delete = script_applies_tos.reject { |sat| applies_to_names.any? { |atn| sat.text == atn[:text] && sat.tld_extra == atn[:tld_extra] } }
    applies_to_delete.each(&:mark_for_destruction)
    applies_to_add = applies_to_names.reject { |atn| script_applies_tos.any? { |sat| sat.text == atn[:text] && sat.tld_extra == atn[:tld_extra] } }
    applies_to_add.each do |atn|
      site_application = SiteApplication.find_by(text: atn[:text]) || SiteApplication.new(text: atn[:text], domain: atn[:domain])
      script_applies_tos.build(site_application: site_application, tld_extra: atn[:tld_extra])
    end

    if new_record? || code_updated_at.nil?
      self.code_updated_at = Time.now
    else
      newest_sv = newest_saved_script_version
      self.code_updated_at = Time.now if newest_sv.nil? || (newest_sv.code != script_version.code)
    end

    update_license(meta['license']&.first)
    self.namespace = meta['namespace']&.first
    self.version = script_version.version
    self.not_js_convertible_override = script_version.not_js_convertible_override

    self.contribution_url = !meta.key?('contributionURL') ? nil : meta['contributionURL'].find { |url| URI.regexp(%w[http https bitcoin]) =~ url }
    self.contribution_amount = (!contribution_url.nil? && meta.key?('contributionAmount')) ? meta['contributionAmount'].first : nil

    self.support_url = if meta.key?('supportURL')
                         meta['supportURL'].find do |url|
                           next false if url.size > 500
                           # mailto is always OK
                           next true if URI.regexp(%w[mailto]) =~ url
                           # http(s) is also OK
                           next false unless URI.regexp(%w[http https]) =~ url

                           # avoid self-linking, there's UI on the same page for discussions
                           begin
                             next URI(url).host != 'greasyfork.org'
                           rescue StandardError
                             next false
                           end
                         end
                       end

    self.css_convertible_to_js = css? && !not_js_convertible_override && CssToJsConverter.convertible?(script_version.rewritten_code)

    new_compatibility_data = []
    %w[compatible incompatible].each do |key|
      next unless meta.key?(key)

      compatible = key == 'compatible'
      meta[key].each do |line|
        browser_match = /\A([a-z]+).*/i.match(line)
        next if browser_match.nil?

        browser = Browser.where(code: browser_match[1].downcase).first
        next if browser.nil?

        comments_split = line.split(' ', 2)
        comments = comments_split.length == 2 ? comments_split[1] : nil
        new_compatibility_data << { compatible: compatible, browser: browser, comments: comments }
      end
    end
    update_children(:compatibilities, new_compatibility_data)
  end

  def newest_saved_script_version
    # get the most recently saved record
    script_versions.reverse.each do |sv|
      return sv unless sv.new_record?
    end
    return nil
  end

  def current_code
    newest_saved_script_version&.code
  end

  def self.record_install(id, ip)
    Script.connection.execute("INSERT IGNORE INTO daily_install_counts (script_id, ip) VALUES (#{Script.connection.quote_string(id)}, '#{Script.connection.quote_string(ip)}');")
  end

  def active?
    !deleted?
  end

  def library?
    script_type_id == ScriptType::LIBRARY_TYPE_ID
  end

  def listable?
    active? && public?
  end

  def public?
    script_type_id == 1
  end

  def unlisted?
    script_type_id == 2
  end

  def can_be_added_to_set?
    public? || unlisted?
  end

  def name(lookup_locale = nil)
    return localized_value_for('name', lookup_locale)
  end

  def description(lookup_locale = nil)
    return localized_value_for('description', lookup_locale)
  end

  def additional_info(lookup_locale = nil)
    return localized_value_for('additional_info', lookup_locale)
  end

  def additional_info_markup(lookup_locale = nil)
    la = localized_attribute_for('additional_info', lookup_locale)
    return nil if la.nil?

    return la.value_markup
  end

  def slugify(name)
    # take out swears
    r = name.downcase.gsub(/motherfucking|motherfucker|fucking|fucker|fucks|fuck|shitty|shits|shit|niggers|nigger|cunts|cunt/, '')
    # multiple non-alphas into one
    r.gsub!(/([^[:alnum:]])[^[:alnum:]]+/) { |_s| Regexp.last_match(1) }
    # leading non-alphas
    r.gsub!(/^[^[:alnum:]]+/, '')
    # trailing non-alphas
    r.gsub!(/[^[:alnum:]]+$/, '')
    # non-alphas into dashes
    r.gsub!(/[^[:alnum:]]/, '-')
    # use "script" if we don't have something suitable
    r = 'script' if r.empty?
    return r
  end

  # Full name minus URL-y characters
  def url_name
    return (name || default_name).gsub(%r{[\?\&/\#\.]+}, '')
  end

  def to_param
    "#{id}-#{slugify(name || default_name)}"
  end

  def deleted?
    !script_delete_type.nil?
  end

  def deleted_and_blanked?
    script_delete_type_id == ScriptDeleteType::BLANKED
  end

  def detect_locale
    ft = full_text
    return if ft.nil?

    if Greasyfork::Application.config.enable_detect_locale
      Logger.new("#{Rails.root}/log/detectlanguage.log").info("Sending DetectLanguage request for #{id ? "script #{id}" : 'a new script'} - #{full_text[0..50]}...")
      begin
        dl_lang_code = DetectLanguage.simple_detect(ft)
      rescue StandardError => e
        Rails.logger.error "Could not detect language - #{e}"
      end
      unless dl_lang_code.nil?
        locales = Locale.where(detect_language_code: dl_lang_code)
        return locales.first unless locales.empty?

        Rails.logger.error "detect_language gave unrecognized code #{dl_lang_code}"
      end
    end
    # assume english
    return Locale.english
  end

  def update_license(text)
    if text.blank?
      self.license = nil
      self.license_text = nil
      return
    end

    text = text.strip
    license_entry = License.find_by(['code = ? OR name = ?', text, text])
    if license_entry
      self.license = license_entry
      self.license_text = nil
      return
    end

    self.license = nil
    self.license_text = text
  end

  def code_url
    return url_helpers.library_js_script_url(self, version: newest_saved_script_version.id, name: url_name) if library?

    return url_helpers.user_js_script_url(self, name: url_name)
  end

  def serializable_hash(options = nil)
    super({ only: [:id, :daily_installs, :total_installs, :fan_score, :good_ratings, :ok_ratings, :bad_ratings, :created_at, :code_updated_at, :namespace, :support_url, :contribution_url, :contribution_amount] }.merge(options || {})).merge({
                                                                                                                                                                                                                                                  name: default_name,
                                                                                                                                                                                                                                                  description: default_localized_value_for('description'),
                                                                                                                                                                                                                                                  url: url_helpers.script_url(nil, self),
                                                                                                                                                                                                                                                  code_url: code_url,
                                                                                                                                                                                                                                                  license: license_text,
                                                                                                                                                                                                                                                  version: version,
                                                                                                                                                                                                                                                  locale: locale.nil? ? nil : locale.code,
                                                                                                                                                                                                                                                  deleted: deleted?,
                                                                                                                                                                                                                                                })
  end

  def immediate_deletion_allowed?
    return true if total_installs <= 50

    # Less than 5 installs per day on average
    return total_installs <= (Date.today - created_at.to_date).to_i * 5
  end

  # all text content of non-localized attributes for this script (for language detection)
  def full_text
    parts = []
    parts << name if name.present?
    parts << default_name if default_name.present?
    parts << description if description.present?
    la = localized_attributes.find { |l| l.attribute_key == 'additional_info' && l.attribute_default }
    unless la.nil?
      additional_text = ApplicationController.helpers.format_user_text_as_plain(la.attribute_value, la.value_markup)
      parts << additional_text if !additional_text.nil? && !additional_text.empty?
    end
    return nil if parts.empty?

    return parts.join("\n")
  end

  def ban_all_authors!(moderator:, reason:, private_reason: nil)
    users.each do |user|
      user.ban!(moderator: moderator, reason: reason, private_reason: private_reason)
    end
  end

  def js?
    language == 'js'
  end

  def css?
    language == 'css'
  end

  def pending_report_by_trusted_reporter?
    script_reports.block_on_pending.any?
  end

  def review_required?
    review_state == 'required'
  end

  def script_versions_with_identical_code
    hashes = script_versions.joins(:script_code, :rewritten_script_code).pluck('script_codes.code_hash', 'rewritten_script_codes_script_versions.code_hash').flatten.uniq
    script_code_ids = ScriptCode.where(code_hash: hashes.uniq).pluck(:id)
    ScriptVersion
      .joins(:script)
      .merge(Script.not_deleted)
      .where.not(script_id: id)
      .where(['script_code_id IN (?) OR rewritten_script_code_id IN (?)', script_code_ids, script_code_ids])
  end

  def self.subsets
    [:greasyfork, :sleazyfork, :all]
  end

  private

  def url_helpers
    Rails.application.routes.url_helpers
  end

  def update_localized_attribute(meta_keys, attr_name)
    default_value = meta_keys.key?(attr_name) ? meta_keys[attr_name].first : nil
    # for libraries, if there's no default, just leave as is
    return if library? && default_value.nil?

    existing_localized_attributes = localized_attributes_for(attr_name)

    unless default_value.nil?
      default_la = existing_localized_attributes.find { |la| la.locale == locale && la.attribute_key == attr_name && la.attribute_default }
      if default_la.nil?
        default_la = localized_attributes.build({ attribute_key: attr_name, attribute_default: true, locale: locale })
      else
        existing_localized_attributes.delete(default_la)
      end
      default_la.assign_attributes({ attribute_value: default_value, value_markup: 'text' })
    end

    meta_keys.select { |n, _v| n.starts_with?(attr_name + ':') }.each do |n, v|
      locale_code = n.split(':', 2).last
      meta_locale = Locale.where(code: locale_code).first
      if meta_locale.nil?
        Rails.logger.error "Unknown locale code - #{locale_code}"
        next
      end
      matching_la = existing_localized_attributes.find { |la| la.locale == meta_locale && la.attribute_key == attr_name }
      if matching_la.nil?
        matching_la = localized_attributes.build({ attribute_key: attr_name, locale: meta_locale })
      else
        existing_localized_attributes.delete(matching_la)
      end
      matching_la.assign_attributes({ attribute_value: v.first, attribute_default: false, value_markup: 'text' })
    end

    existing_localized_attributes.each(&:mark_for_destruction)
  end

  def update_children(child_name, new_data)
    existing_children = send(child_name).to_a
    new_data.each do |new_hash|
      # See if a record like that already exists.
      matching_existing = existing_children.find do |child|
        new_hash.keys.all? { |k| new_hash[k] == child.send(k) }
      end
      # Leave it alone, remove it from the search array, and move on
      unless matching_existing.nil?
        existing_children.delete(matching_existing)
        next
      end
      # Make a new one
      # Specify script again - https://github.com/rails/rails/issues/26817
      send(child_name).build(new_hash.merge(script: self))
    end
    # Anything left in the search array, mark for destruction
    existing_children.each(&:mark_for_destruction)
  end
end
