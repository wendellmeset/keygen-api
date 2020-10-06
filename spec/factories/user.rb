# frozen_string_literal: true

FactoryBot.define do
  factory :user do
    first_name { Faker::Name.name }
    last_name { Faker::Name.name }
    email { [SecureRandom.hex, Faker::Internet.safe_email].join }
    password { "password" }

    association :account

    after :build do |user, evaluator|
      account = evaluator.account or create :account

      user.assign_attributes(
        account: account
      )
    end

    after :create do |user|
      user.role = create :role, :user, resource: user
      create :token, bearer: user
    end

    factory :admin do
      after :create do |admin|
        admin.role = create :role, :admin, resource: admin
        create :token, bearer: admin
      end
    end

    factory :developer do
      after :create do |dev|
        dev.role = create :role, :developer, resource: dev
        create :token, bearer: dev
      end
    end

    factory :support_agent do
      after :create do |agent|
        agent.role = create :role, :support_agent, resource: agent
        create :token, bearer: agent
      end
    end

    factory :sales_agent do
      after :create do |agent|
        agent.role = create :role, :sales_agent, resource: agent
        create :token, bearer: agent
      end
    end
  end
end
