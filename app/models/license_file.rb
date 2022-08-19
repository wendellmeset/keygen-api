# frozen_string_literal: true

class LicenseFile
  include ActiveModel::Model
  include ActiveModel::Attributes

  attribute :account_id,  :uuid
  attribute :license_id,  :uuid
  attribute :certificate, :string
  attribute :issued_at,   :datetime
  attribute :expires_at,  :datetime
  attribute :ttl,         :integer
  attribute :includes,    :array

  validates :account_id,  presence: true
  validates :license_id,  presence: true
  validates :certificate, presence: true
  validates :issued_at,   presence: true

  validates_format_of :certificate,
    with: /\A-----BEGIN LICENSE FILE-----\n/,
    message: 'invalid prefix'
  validates_format_of :certificate,
    with: /-----END LICENSE FILE-----\n\z/,
    message: 'invalid suffix'

  validates_numericality_of :ttl,
    greater_than_or_equal_to: 1.hour,
    less_than_or_equal_to: 1.year,
    allow_nil: true

  def persisted? = false
  def id         = @id      ||= SecureRandom.uuid
  def account    = @account ||= Account.find_by(id: account_id)
  def license    = @license ||= License.find_by(account_id: account_id, id: license_id)
  def product    = @product ||= license&.product
  def user       = @user    ||= license&.user
end
