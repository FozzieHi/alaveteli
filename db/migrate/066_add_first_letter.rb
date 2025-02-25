class AddFirstLetter < ActiveRecord::Migration[4.2] # 2.1
  def self.up
    add_column :public_bodies, :first_letter, :string
    add_index :public_bodies, :first_letter
    PublicBody.update_all "first_letter = upper(substr(name, 1, 1))"
    change_column :public_bodies, :first_letter, :string, null: false
  end

  def self.down
    remove_column :public_bodies, :first_letter
  end
end
