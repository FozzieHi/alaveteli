class UniqueUserUrls < ActiveRecord::Migration[4.2] # 2.0
  def self.up
    # do last registered ones first, so the last ones get rubbish URLs
    User.order(id: :desc).each do |user|
      user.update_url_name
      user.save!
    end
    # MySQL cannot index text blobs like this
    if ActiveRecord::Base.connection.adapter_name != "MySQL"
      remove_index :users, :url_name
      add_index :users, :url_name, unique: true
    end
  end

  def self.down
    # MySQL cannot index text blobs like this
    if ActiveRecord::Base.connection.adapter_name != "MySQL"
      remove_index :users, :url_name
      add_index :users, :url_name, unique: false
    end
  end

end
